import Foundation
import AVFoundation
import CryptoKit

enum VoiceProvider: String, Codable, CaseIterable, Identifiable {
    case elevenLabs, minimaxCN, minimaxGlobal
    var id: String { rawValue }
    var title: String { switch self { case .elevenLabs: "ElevenLabs"; case .minimaxCN: "MiniMax 国内版"; case .minimaxGlobal: "MiniMax 国际版" } }
    var keyAccount: String { self == .elevenLabs ? "elevenLabsKey" : rawValue + "Key" }
    var voicePreference: String { self == .elevenLabs ? "djVoiceID" : rawValue + "VoiceID" }
    var modelPreference: String { rawValue + "VoiceModel" }
    /// 不内置任何音色：开源后每个人在自己的 ElevenLabs / MiniMax 账号里挑一个，把 ID 填进设置。
    var defaultVoice: String { "" }
    var voiceHint: String { self == .elevenLabs ? "在 ElevenLabs 的 Voices / Voice Library 里选一个声音，复制它的 Voice ID。" : "在 MiniMax 平台的音色列表里复制音色 ID（voice_id）。" }
    var defaultModel: String { self == .elevenLabs ? VoiceConfiguration.defaultModel : "speech-2.8-turbo" }
    var host: String { self == .minimaxCN ? "api.minimax.cn" : "api.minimax.io" }
}

/// DJ 声音配置。Key 只存系统钥匙串；音色 ID 不是秘密，存在本机偏好里。
struct VoiceConfiguration: Equatable {
    static let defaultVoiceID = ""
    /// v4 支持语气标签（[sighs] 等）且返回逐字时间。
    static let defaultModel = "eleven_v4"
    var apiKey = ""
    var voiceID = defaultVoiceID
    var model = defaultModel
    var provider: VoiceProvider = .elevenLabs
    var supportsToneTags: Bool { provider == .elevenLabs && (model.hasPrefix("eleven_v3") || model.hasPrefix("eleven_v4")) }
    var ready: Bool { !apiKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !voiceID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
}

struct VoiceConnectionProfile: Codable, Identifiable, Equatable {
    let id:UUID
    var name:String
    var provider:VoiceProvider
    var voiceID:String
    var model:String
    var keyAccount:String { "voiceProfile-" + id.uuidString }
}

/// 一段合成好的口播：音频 + 每个字的开始时间（秒）。系统声音没有音频数据，由合成器回调推进。
struct SpeechClip: Codable, Equatable {
    let audio: Data
    let characterStarts: [Double]
}

enum VoiceError: LocalizedError, Equatable {
    case notConfigured, invalidKey, missingPermission, quota, busy, rejected(String), http(Int), malformed
    var errorDescription: String? {
        switch self {
        case .notConfigured: "还没有填写声音服务的 Key、音色或模型。"
        case .invalidKey: "ElevenLabs Key 无效，请在 AI 设置里重新填写。"
        case .missingPermission: "这个 ElevenLabs Key 没有语音合成权限。"
        case .quota: "ElevenLabs 额度已用完。"
        case .busy: "ElevenLabs 正忙，请稍后再试。"
        case .rejected(let message): "ElevenLabs 拒绝了这段文字：\(message)"
        case .http(let code): "ElevenLabs 暂时不可用（HTTP \(code)）。"
        case .malformed: "ElevenLabs 返回的格式无法识别。"
        }
    }
}

/// ElevenLabs 语音识别（Scribe）：把录好的 16 kHz 单声道 PCM 包成 WAV 上传，取回文字。
enum ElevenLabsSTT {
    static let model = "scribe_v2"
    static let sampleRate = 16_000
    /// 最长约 60 秒，避免误开麦一直录。
    static let maxBytes = sampleRate * 2 * 60
    static func wav(pcm16:Data) -> Data {
        let pcm = pcm16.prefix(maxBytes)
        func le32(_ v:Int) -> Data { withUnsafeBytes(of:UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v:Int) -> Data { withUnsafeBytes(of:UInt16(v).littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8); d += le32(36 + pcm.count); d += Data("WAVEfmt ".utf8)
        d += le32(16); d += le16(1); d += le16(1); d += le32(sampleRate); d += le32(sampleRate * 2); d += le16(2); d += le16(16)
        d += Data("data".utf8); d += le32(pcm.count); d += pcm
        return d
    }
    static func request(pcm16:Data,apiKey:String,boundary:String = "VibeRadio-\(UUID().uuidString)") throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty else { throw VoiceError.notConfigured }
        var request = URLRequest(url:URL(string:"https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue(key,forHTTPHeaderField:"xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        var body = Data()
        func field(_ name:String,_ value:String) { body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8) }
        field("model_id",model); field("tag_audio_events","false")
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body += wav(pcm16:pcm16); body += Data("\r\n--\(boundary)--\r\n".utf8)
        request.httpBody = body
        return request
    }
    static func parse(data:Data,status:Int) throws -> String {
        guard (200..<300).contains(status) else { throw ElevenLabsClient.error(data:data,status:status) }
        struct Response: Decodable { let text:String }
        guard let text = try? JSONDecoder().decode(Response.self,from:data).text else { throw VoiceError.malformed }
        return text.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func transcribe(pcm16:Data,apiKey:String,session:URLSession = .shared) async throws -> String {
        let (data,response) = try await session.data(for:try request(pcm16:pcm16,apiKey:apiKey))
        return try parse(data:data,status:(response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum ElevenLabsClient {
    static let maxCharacters = 1000
    static func request(text:String,configuration:VoiceConfiguration) throws -> URLRequest {
        guard configuration.ready else { throw VoiceError.notConfigured }
        let voice = configuration.voiceID.trimmingCharacters(in:.whitespacesAndNewlines)
        guard voice.range(of:"^[A-Za-z0-9]{8,64}$",options:.regularExpression) != nil,
              let url = URL(string:"https://api.elevenlabs.io/v1/text-to-speech/\(voice)/with-timestamps?output_format=mp3_44100_128") else {
            throw VoiceError.rejected("音色 ID 格式不正确")
        }
        var request = URLRequest(url:url)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue(configuration.apiKey.trimmingCharacters(in:.whitespacesAndNewlines),forHTTPHeaderField:"xi-api-key")
        let body: [String:Any] = [
            "text": String(text.prefix(maxCharacters)),
            "model_id": configuration.model,
            // 电台主持：稳一点、少一点戏剧化。
            "voice_settings": ["stability":0.55,"similarity_boost":0.8,"style":0.15,"use_speaker_boost":true]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject:body)
        return request
    }
    static func parse(data:Data,status:Int) throws -> SpeechClip {
        guard (200..<300).contains(status) else { throw error(data:data,status:status) }
        struct Response: Decodable {
            struct Alignment: Decodable { let characters:[String]; let character_start_times_seconds:[Double] }
            let audio_base64: String
            let alignment: Alignment?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self,from:data),
              let audio = Data(base64Encoded:decoded.audio_base64), !audio.isEmpty else { throw VoiceError.malformed }
        guard let alignment = decoded.alignment else { return SpeechClip(audio:audio,characterStarts:[]) }
        return SpeechClip(audio:audio,characterStarts:ToneMarks.visibleStarts(characters:alignment.characters,starts:alignment.character_start_times_seconds))
    }
    static func error(data:Data,status:Int) -> VoiceError {
        struct Detail: Decodable { let status:String?; let message:String? }
        struct Envelope: Decodable { let detail:Detail? }
        let detail = (try? JSONDecoder().decode(Envelope.self,from:data))?.detail
        switch detail?.status ?? "" {
        case "invalid_api_key": return .invalidKey
        case "missing_permissions": return .missingPermission
        case "quota_exceeded", "payment_required": return .quota
        case "too_many_concurrent_requests", "system_busy": return .busy
        default: break
        }
        switch status {
        case 401: return .invalidKey
        case 402: return .quota
        case 429, 503: return .busy
        case 400, 422: return .rejected(String((detail?.message ?? "参数无效").prefix(120)))
        default: return .http(status)
        }
    }
    static func synthesize(text:String,configuration:VoiceConfiguration,session:URLSession = .shared) async throws -> SpeechClip {
        let (data,response) = try await session.data(for:try request(text:text,configuration:configuration))
        try Task.checkCancellation()
        return try parse(data:data,status:(response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// MiniMax 国内／国际账号独立；仅向所选区域的固定 HTTPS 地址发送凭据。
enum MiniMaxClient {
    enum Failure: LocalizedError {
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .status(1004): "MiniMax Key 无效，请确认 Key 与国内／国际版匹配。"
            case .status(1008): "MiniMax 余额不足，请检查账户额度。"
            case .status(1002), .status(1039): "MiniMax 正忙，请稍后再试。"
            case .status(2013): "MiniMax 不接受当前参数，请检查音色 ID 和模型。"
            case .status(let code): "MiniMax 合成失败（状态码 \(code)）。"
            }
        }
    }
    static func request(text:String, configuration:VoiceConfiguration) throws -> URLRequest {
        guard configuration.provider != .elevenLabs, configuration.ready else { throw Failure.status(1004) }
        var request = URLRequest(url:URL(string:"https://\(configuration.provider.host)/v1/t2a_v2")!)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("Bearer " + configuration.apiKey.trimmingCharacters(in:.whitespacesAndNewlines),forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:[
            "model":configuration.model,"text":String(text.prefix(1000)),"stream":false,"output_format":"hex","language_boost":"auto",
            "voice_setting":["voice_id":configuration.voiceID,"speed":1,"vol":1,"pitch":0],
            "audio_setting":["sample_rate":32000,"bitrate":128000,"format":"mp3","channel":1]
        ])
        return request
    }
    static func parse(data:Data,status:Int) throws -> SpeechClip {
        struct Response: Decodable {
            struct Base: Decodable { let status_code:Int }
            struct Audio: Decodable { let audio:String? }
            let base_resp:Base?; let data:Audio?
        }
        guard let response = try? JSONDecoder().decode(Response.self,from:data) else { throw Failure.status(status == 200 ? -1 : status) }
        guard let code = response.base_resp?.status_code else { throw Failure.status(-1) }
        guard (200..<300).contains(status), code == 0 else { throw Failure.status(code == 0 ? status : code) }
        guard let hex = response.data?.audio, !hex.isEmpty, hex.count % 2 == 0 else { throw Failure.status(-1) }
        var audio = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index,offsetBy:2)
            guard let byte = UInt8(hex[index..<next],radix:16) else { throw Failure.status(-1) }
            audio.append(byte); index = next
        }
        // 此接口未申请逐字时间戳；播放器按实际音频时长近似推进字幕。
        return SpeechClip(audio:audio,characterStarts:[])
    }
    static func synthesize(text:String,configuration:VoiceConfiguration) async throws -> SpeechClip {
        let (data,response) = try await URLSession.shared.data(for:request(text:text,configuration:configuration))
        try Task.checkCancellation()
        return try parse(data:data,status:(response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum VoiceClient {
    static func synthesize(text:String,configuration:VoiceConfiguration) async throws -> SpeechClip {
        if configuration.provider == .elevenLabs { return try await ElevenLabsClient.synthesize(text:text,configuration:configuration) }
        return try await MiniMaxClient.synthesize(text:text,configuration:configuration)
    }
}

/// 同一段话、同一音色只合成一次：回放和重复开场不再计费。
struct SpeechCache {
    let folder: URL
    init(folder:URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("VibeRadio/Speech",isDirectory:true)
    }
    func key(text:String,configuration:VoiceConfiguration) -> String {
        SHA256.hash(data:Data("\(configuration.provider.rawValue)|\(configuration.model)|\(configuration.voiceID)|\(text)".utf8)).map { String(format:"%02x",$0) }.joined()
    }
    func read(_ key:String) -> SpeechClip? {
        guard let data = try? Data(contentsOf:folder.appendingPathComponent(key+".json")) else { return nil }
        return try? JSONDecoder().decode(SpeechClip.self,from:data)
    }
    func contains(_ key:String) -> Bool { FileManager.default.fileExists(atPath:folder.appendingPathComponent(key+".json").path) }
    func write(_ clip:SpeechClip,_ key:String) {
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try? JSONEncoder().encode(clip).write(to:folder.appendingPathComponent(key+".json"),options:.atomic)
    }
}

/// 一次口播由几段组成：比如「开场白」对应聊天消息，「歌曲介绍」对应推荐卡片。
/// lead 是只念不显示的引导语（如「先来听 某某 的《某某》。」），display 是界面上要逐字点亮的文字。
/// 语气声：DJ 写在全角括号里，如「（叹气）今天辛苦了。」。
/// 界面、高亮和字数里去掉；合成时换成 ElevenLabs v4 的语气标签，变成真的声音；系统声音直接去掉。
/// 只认下面这几个，歌名里的「(Live)」之类不受影响。
enum ToneMarks {
    static let tags: [String: String] = ["叹气": "[sighs]", "轻笑": "[chuckles]", "笑": "[laughs]", "吸气": "[inhales]", "呼气": "[exhales]",
                                         "清嗓子": "[clears throat]", "清嗓": "[clears throat]", "嗯": "[hmm]", "低声": "[whispers]"]
    static var enabled: Bool { UserDefaults.standard.object(forKey: "djToneSounds") as? Bool ?? true }
    private static let regex = try! NSRegularExpression(pattern: #"[（(]\s*([^（）()]{1,4})\s*[）)]\s*"#)
    private static func replace(_ text: String, _ map: (String) -> String) -> String {
        let ns = text as NSString
        var out = "", last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard let tag = tags[name] else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + map(tag)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
    static func strip(_ text: String) -> String { replace(text) { _ in "" } }
    static func tagged(_ text: String) -> String { replace(text) { $0 + " " } }
    static func minimax(_ text:String) -> String {
        let mapping = ["[sighs]":"(sighs)","[chuckles]":"(chuckle)","[laughs]":"(laughs)","[inhales]":"(inhale)","[exhales]":"(exhale)","[clears throat]":"(clear-throat)","[hmm]":"(emm)"]
        return replace(text) { mapping[$0].map { $0 + " " } ?? "" }
    }
    /// 对齐信息里去掉语气标签（[…] 及其后一个空格）对应的字，让时间和界面文字一一对应。
    static func visibleStarts(characters: [String], starts: [Double]) -> [Double] {
        var out: [Double] = [], inTag = false, afterTag = false
        for (c, t) in zip(characters, starts) {
            if inTag { if c == "]" { inTag = false; afterTag = true }; continue }
            if c == "[" { inTag = true; continue }
            if afterTag { afterTag = false; if c == " " { continue } }
            out.append(t)
        }
        return out
    }
}

struct SpeechSegment: Equatable {
    let key: String
    var lead = ""
    let display: String
    /// 念出来、显示出来的文字（不含语气声标记）。
    var spoken: String { lead + ToneMarks.strip(display) }
    /// 送去合成的文字：支持时语气声换成标签，否则去掉。
    func synthesis(tags: Bool) -> String { lead + (tags ? ToneMarks.tagged(display) : ToneMarks.strip(display)) }
}
enum SpeechScript {
    /// 已念到第 count 个字时，某段界面文字应点亮的字数；不属于本段返回 nil。
    static func highlighted(segments:[SpeechSegment],spokenCount:Int,key:String) -> Int? {
        var offset = 0
        for segment in segments {
            let length = segment.spoken.count
            if segment.key == key { return min(max(spokenCount - offset - segment.lead.count,0),ToneMarks.strip(segment.display).count) }
            offset += length
        }
        return nil
    }
    /// 播放进度 → 已念字数。对齐字数和脚本不一致时按比例换算，避免高亮跑飞。
    static func spokenCount(at time:Double,starts:[Double],scriptLength:Int) -> Int {
        guard !starts.isEmpty, scriptLength > 0 else { return 0 }
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] <= time { low = mid + 1 } else { high = mid } }
        return starts.count == scriptLength ? low : Int((Double(low) / Double(starts.count) * Double(scriptLength)).rounded())
    }
    /// 固定字幕窗按音频进度翻页；长句无标点也不会把聊天区挤出屏幕。
    static func captionWindow(_ text:String,spokenCount:Int,limit:Int=48) -> (sentence:String,highlighted:Int) {
        let line=currentSentence(text,spokenCount:spokenCount)
        let width=max(1,limit)
        guard line.sentence.count > width else { return line }
        let offset=min(max(line.highlighted,0),line.sentence.count-1) / width * width
        let start=line.sentence.index(line.sentence.startIndex,offsetBy:offset)
        return (String(line.sentence[start...].prefix(width)),min(max(line.highlighted-offset,0),width))
    }
    /// 电台主屏只显示当前这一句。
    static func currentSentence(_ text:String,spokenCount:Int) -> (sentence:String,highlighted:Int) {
        var start = text.startIndex, consumed = 0
        for index in text.indices {
            consumed += 1
            if "。！？!?\n".contains(text[index]) {
                let end = text.index(after:index)
                if spokenCount < consumed || end == text.endIndex {
                    let sentence = String(text[start..<end]).trimmingCharacters(in:.whitespaces)
                    let before = text.distance(from:text.startIndex,to:start)
                    return (sentence,min(max(spokenCount - before,0),sentence.count))
                }
                start = end
            }
        }
        let tail = String(text[start...])
        return (tail,min(max(spokenCount - text.distance(from:text.startIndex,to:start),0),tail.count))
    }
}

@MainActor final class DJVoice: NSObject, ObservableObject {
    enum Source { case elevenLabs, minimax, system }
    @Published private(set) var profiles:[VoiceConnectionProfile] = []
    @Published private(set) var activeProfileID:UUID?
    @Published private(set) var configuration: VoiceConfiguration
    @Published private(set) var preparing = false
    @Published private(set) var speakingID: UUID?
    @Published private(set) var segments: [SpeechSegment] = []
    @Published private(set) var spokenCount = 0
    @Published private(set) var source: Source = .elevenLabs
    @Published private(set) var notice = ""
    @Published private(set) var testStatus = ""
    /// 说话时压低音乐、结束后恢复；由界面接到电台播放器上。
    var duck: (Bool) -> Void = { _ in }
    private let defaults: UserDefaults
    private let cache: SpeechCache
    private var player: AVAudioPlayer?
    private var starts: [Double] = []
    private var ticker: Timer?
    private var task: Task<Void,Never>?
    private let synthesizer = AVSpeechSynthesizer()

    init(defaults:UserDefaults = .standard,cache:SpeechCache = SpeechCache()) {
        self.defaults = defaults; self.cache = cache
        let provider = VoiceProvider(rawValue:defaults.string(forKey:"djVoiceProvider") ?? "") ?? .elevenLabs
        configuration = Self.load(provider,defaults:defaults)
        super.init()
        synthesizer.delegate = self
        if let data=defaults.data(forKey:"voiceProfiles"),let saved=try? JSONDecoder().decode([VoiceConnectionProfile].self,from:data) { profiles=saved }
        activeProfileID=defaults.string(forKey:"activeVoiceProfile").flatMap(UUID.init(uuidString:))
        if profiles.isEmpty, configuration.ready { try? saveProfile(configuration,name:"当前 DJ 声音") }
        #if os(iOS)
        // 来电等打断时系统会停掉口播；这句不再接着念，直接收尾并恢复音乐音量，免得音乐一直被压低。
        interruptionObserver = NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:AVAudioSession.sharedInstance(),queue:.main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue:raw) == .began,
                  !(note.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? Bool ?? false) else { return }
            Task { @MainActor in self?.stop() }
        }
        #endif
    }
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    #endif
    var speaking: Bool { speakingID != nil }
    var script: String { segments.map(\.spoken).joined() }
    /// 口播响度 0…1，给正在播放条用；系统声音拿不到时为 nil。
    var level: Float? {
        guard let player, player.isPlaying else { return nil }
        player.updateMeters()
        return min(max((player.averagePower(forChannel:0) + 48) / 48,0),1)
    }

    private static func load(_ provider:VoiceProvider,defaults:UserDefaults) -> VoiceConfiguration {
        VoiceConfiguration(apiKey:Vault.read(provider.keyAccount),voiceID:defaults.string(forKey:provider.voicePreference) ?? provider.defaultVoice,model:defaults.string(forKey:provider.modelPreference) ?? provider.defaultModel,provider:provider)
    }
    func configuration(for provider:VoiceProvider) -> VoiceConfiguration { Self.load(provider,defaults:defaults) }
    /// 识别始终使用 ElevenLabs 自己的凭据，与当前合成供应商无关。
    var recognitionKey: String { Vault.read("elevenLabsKey") }
    func save(_ draft:VoiceConfiguration) throws {
        var value = draft
        value.apiKey = value.apiKey.trimmingCharacters(in:.whitespacesAndNewlines)
        value.voiceID = value.voiceID.trimmingCharacters(in:.whitespacesAndNewlines)
        value.model = value.model.trimmingCharacters(in:.whitespacesAndNewlines)
        try Vault.write(value.provider.keyAccount,value.apiKey)
        defaults.set(value.voiceID,forKey:value.provider.voicePreference)
        defaults.set(value.model,forKey:value.provider.modelPreference)
        defaults.set(value.provider.rawValue,forKey:"djVoiceProvider")
        configuration = value
    }
    private func persistProfiles() {
        defaults.set(try? JSONEncoder().encode(profiles),forKey:"voiceProfiles")
        defaults.set(activeProfileID?.uuidString,forKey:"activeVoiceProfile")
    }
    func profileConfiguration(_ profile:VoiceConnectionProfile) -> VoiceConfiguration {
        VoiceConfiguration(apiKey:Vault.read(profile.keyAccount),voiceID:profile.voiceID,model:profile.model,provider:profile.provider)
    }
    func saveProfile(_ draft:VoiceConfiguration,name:String,id:UUID? = nil) throws {
        let name=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { throw VoiceError.rejected("请给声音配置起个名字") }
        guard !preparing else { throw VoiceError.rejected("请等试听完成后再保存") }
        let profile=VoiceConnectionProfile(id:id ?? UUID(),name:name,provider:draft.provider,voiceID:draft.voiceID.trimmingCharacters(in:.whitespacesAndNewlines),model:draft.model.trimmingCharacters(in:.whitespacesAndNewlines))
        try Vault.write(profile.keyAccount,draft.apiKey.trimmingCharacters(in:.whitespacesAndNewlines))
        try save(draft)
        if let i=profiles.firstIndex(where:{$0.id==profile.id}) { profiles[i]=profile } else { profiles.append(profile) }
        activeProfileID=profile.id;persistProfiles()
    }
    func activateProfile(_ id:UUID) throws {
        guard !preparing else { throw VoiceError.rejected("请等试听完成后再切换") }
        guard let profile=profiles.first(where:{$0.id==id}) else { return }
        try save(profileConfiguration(profile));stop();activeProfileID=id;persistProfiles();testStatus=""
    }
    func deleteProfile(_ id:UUID) throws {
        guard !preparing else { throw VoiceError.rejected("请等试听完成后再删除") }
        guard let profile=profiles.first(where:{$0.id==id}) else { return }
        if activeProfileID==id {
            if let next=profiles.first(where:{$0.id != id}) { try activateProfile(next.id) }
            else { var empty=configuration;empty.apiKey="";try save(empty);stop();activeProfileID=nil }
        }
        try Vault.write(profile.keyAccount,"")
        profiles.removeAll {$0.id==id};persistProfiles();testStatus=""
    }
    func clearTestStatus() { testStatus = "" }
    /// 试听：用草稿配置合成一句短话，成功才说明 Key 和音色都能用。
    func test(_ draft:VoiceConfiguration) {
        testStatus = "正在试听…"
        speak([SpeechSegment(key:"voice-test",display:"晚上好，我是你的电台 DJ。")],id:UUID(),configuration:draft,allowFallback:false) { [weak self] error in
            self?.testStatus = error.map { "试听失败：\($0.localizedDescription)" } ?? "试听成功，记得保存。"
        }
    }

    func highlighted(_ key:String) -> Int? {
        guard speaking else { return nil }
        return SpeechScript.highlighted(segments:segments,spokenCount:spokenCount,key:key)
    }
    func isSpeaking(_ id:UUID) -> Bool { speakingID == id || (preparing && pendingID == id) }
    private var pendingID: UUID?

    /// 提前合成并放进缓存（例如下一段串词），真正开口时就不必等网络。失败静默：到时会再试或改用系统声音。
    func prefetch(_ segments:[SpeechSegment]) async {
        let configuration = self.configuration
        let text = segments.map { segment in
            if configuration.provider != .elevenLabs && ToneMarks.enabled && configuration.model.hasPrefix("speech-2.8") { return ToneMarks.minimax(segment.lead + segment.display) }
            return segment.synthesis(tags:ToneMarks.enabled && configuration.supportsToneTags)
        }.joined()
        guard configuration.ready, !text.isEmpty else { return }
        let key = cache.key(text:text,configuration:configuration)
        guard !cache.contains(key), let clip = try? await VoiceClient.synthesize(text:text,configuration:configuration) else { return }
        cache.write(clip,key)
    }
    func speak(_ segments:[SpeechSegment],id:UUID,configuration override:VoiceConfiguration? = nil,allowFallback:Bool = true,completion:((Error?) -> Void)? = nil) {
        stop()
        let configuration = override ?? self.configuration
        let text = segments.map { segment in
            if configuration.provider != .elevenLabs && ToneMarks.enabled && configuration.model.hasPrefix("speech-2.8") { return ToneMarks.minimax(segment.lead + segment.display) }
            return segment.synthesis(tags:ToneMarks.enabled && configuration.supportsToneTags)
        }.joined()
        guard !segments.map(\.spoken).joined().trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        self.segments = segments
        pendingID = id; preparing = true; notice = ""
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard configuration.ready else { throw VoiceError.notConfigured }
                let key = cache.key(text:text,configuration:configuration)
                let clip: SpeechClip
                if let cached = cache.read(key) { clip = cached }
                else { clip = try await VoiceClient.synthesize(text:text,configuration:configuration); cache.write(clip,key) }
                try Task.checkCancellation()
                guard pendingID == id else { return }
                try start(clip,segments:segments,id:id,provider:configuration.provider)
                completion?(nil)
            } catch is CancellationError {
            } catch {
                guard pendingID == id else { return }
                if allowFallback {
                    // 拿不到好声音时不沉默：用系统中文声音念出来，并如实说明。
                    if !((error as? VoiceError) == .notConfigured) { notice = "\(error.localizedDescription) 本次改用系统声音。" }
                    startSystem(segments:segments,id:id)
                    completion?(nil)
                } else {
                    preparing = false; pendingID = nil
                    completion?(error)
                }
            }
        }
    }
    private func start(_ clip:SpeechClip,segments:[SpeechSegment],id:UUID,provider:VoiceProvider) throws {
        let player = try AVAudioPlayer(data:clip.audio)
        player.isMeteringEnabled = true
        player.delegate = self
        self.player = player; starts = clip.characterStarts.isEmpty ? (0..<segments.map(\.spoken).joined().count).map { Double($0) * player.duration / Double(max(1,segments.map(\.spoken).joined().count)) } : clip.characterStarts
        self.segments = segments; spokenCount = 0; source = provider == .elevenLabs ? .elevenLabs : .minimax
        speakingID = id; preparing = false; pendingID = nil
        duck(true)
        player.play()
        ticker = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.spokenCount = SpeechScript.spokenCount(at:player.currentTime,starts:self.starts,scriptLength:self.script.count)
            }
        }
    }
    private func startSystem(segments:[SpeechSegment],id:UUID) {
        self.segments = segments; spokenCount = 0; source = .system
        speakingID = id; preparing = false; pendingID = nil
        duck(true)
        let utterance = AVSpeechUtterance(string:segments.map(\.spoken).joined())
        let locales=["en":"en-US","ko":"ko-KR","ja":"ja-JP","fr":"fr-FR"]
        utterance.voice = AVSpeechSynthesisVoice(language:locales[UserDefaults.standard.string(forKey:"djLanguage") ?? ""] ?? "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
    }
    @Published private(set) var paused = false
    /// 暂停/继续当前口播（ElevenLabs 与系统声音都支持）；暂停时音乐恢复音量。
    func togglePause() {
        guard speaking else { return }
        if paused {
            if let player { player.play() } else { synthesizer.continueSpeaking() }
            paused = false; duck(true)
        } else {
            if let player { player.pause() } else { synthesizer.pauseSpeaking(at:.word) }
            paused = true; duck(false)
        }
    }
    func stop() {
        paused = false
        task?.cancel(); task = nil
        ticker?.invalidate(); ticker = nil
        player?.stop(); player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at:.immediate) }
        let wasSpeaking = speakingID != nil
        preparing = false; pendingID = nil; speakingID = nil; segments = []; spokenCount = 0
        if wasSpeaking { duck(false) }
    }
    fileprivate func finished() {
        paused = false
        spokenCount = script.count
        ticker?.invalidate(); ticker = nil; player = nil
        speakingID = nil; segments = []; spokenCount = 0
        duck(false)
    }
}
extension DJVoice: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) {
        Task { @MainActor in if self.player === player { self.finished() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer:AVSpeechSynthesizer,willSpeakRangeOfSpeechString range:NSRange,utterance:AVSpeechUtterance) {
        let count = (utterance.speechString as NSString).substring(to:range.location).count
        Task { @MainActor in if self.source == .system && self.speaking { self.spokenCount = count } }
    }
    nonisolated func speechSynthesizer(_ synthesizer:AVSpeechSynthesizer,didFinish utterance:AVSpeechUtterance) {
        Task { @MainActor in if self.source == .system && self.speaking { self.finished() } }
    }
}
