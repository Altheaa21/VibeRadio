import Foundation

enum Vault {
    static var items: [String:String] = [:]
    static func read(_ key:String)->String { items[key] ?? "" }
    static func write(_ key:String,_ value:String) throws { items[key]=value }
}
@main struct VoiceTests {
    @MainActor static func main() async throws {
        var checks=0
        func expect(_ value:Bool,_ message:String) { precondition(value,message);checks += 1 }
        var config=VoiceConfiguration(apiKey:" test-key ",voiceID:"testVoice123")
        let request=try ElevenLabsClient.request(text:String(repeating:"夜",count:1500),configuration:config)
        expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/testVoice123/with-timestamps?output_format=mp3_44100_128","timestamped endpoint")
        expect(request.value(forHTTPHeaderField:"xi-api-key") == "test-key","trimmed key header")
        expect(request.value(forHTTPHeaderField:"Authorization") == nil,"no bearer header")
        let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        expect((body["text"] as! String).count == ElevenLabsClient.maxCharacters,"text capped")
        expect(body["model_id"] as? String == "eleven_v4" && config.supportsToneTags,"v4 model with tone tags")
        config.voiceID="../evil"
        do {_=try ElevenLabsClient.request(text:"x",configuration:config);preconditionFailure("bad voice")} catch {expect(error as? VoiceError == .rejected("音色 ID 格式不正确"),"voice id validated")}
        do {_=try ElevenLabsClient.request(text:"x",configuration:VoiceConfiguration());preconditionFailure("no key")} catch {expect(error as? VoiceError == .notConfigured,"missing key")}

        let ok=try JSONSerialization.data(withJSONObject:["audio_base64":Data([1,2,3]).base64EncodedString(),"alignment":["characters":["晚","上"],"character_start_times_seconds":[0.0,0.24],"character_end_times_seconds":[0.24,0.45]]])
        let clip=try ElevenLabsClient.parse(data:ok,status:200)
        expect(clip.audio == Data([1,2,3]) && clip.characterStarts == [0.0,0.24],"audio and timing decoded")
        do {_=try ElevenLabsClient.parse(data:Data("{}".utf8),status:200);preconditionFailure("malformed")} catch {expect(error as? VoiceError == .malformed,"malformed body")}
        func detail(_ status:String) -> Data { try! JSONSerialization.data(withJSONObject:["detail":["status":status,"message":"m"]]) }
        expect(ElevenLabsClient.error(data:detail("invalid_api_key"),status:401) == .invalidKey,"invalid key")
        expect(ElevenLabsClient.error(data:detail("missing_permissions"),status:401) == .missingPermission,"missing permission")
        expect(ElevenLabsClient.error(data:detail("quota_exceeded"),status:401) == .quota,"quota via 401 detail")
        expect(ElevenLabsClient.error(data:detail("too_many_concurrent_requests"),status:429) == .busy,"busy")
        expect(ElevenLabsClient.error(data:Data(),status:500) == .http(500),"generic http")
        expect(ElevenLabsClient.error(data:Data(),status:402) == .quota,"402 quota")

        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vr-voice-\(UUID())")
        defer { try? FileManager.default.removeItem(at:folder) }
        let cache=SpeechCache(folder:folder)
        let a=VoiceConfiguration(apiKey:"k",voiceID:"voiceAAAA"), b=VoiceConfiguration(apiKey:"other",voiceID:"voiceBBBB")
        expect(cache.key(text:"晚上好",configuration:a) != cache.key(text:"晚上好",configuration:b),"cache keyed by voice")
        expect(cache.key(text:"晚上好",configuration:a) == cache.key(text:"晚上好",configuration:VoiceConfiguration(apiKey:"rotated",voiceID:"voiceAAAA")),"key rotation keeps cache")
        let key=cache.key(text:"晚上好",configuration:a)
        expect(cache.read(key) == nil,"cache miss")
        cache.write(clip,key)
        expect(cache.read(key) == clip,"cache roundtrip")
        expect(!(try String(contentsOf:folder.appendingPathComponent(key+".json"))).contains("k\""),"cache never stores key")

        let starts=[0.0,0.24,0.45,0.64]
        expect(SpeechScript.spokenCount(at:0.3,starts:starts,scriptLength:4) == 2,"exact alignment")
        expect(SpeechScript.spokenCount(at:10,starts:starts,scriptLength:4) == 4,"end of speech")
        expect(SpeechScript.spokenCount(at:0.3,starts:starts,scriptLength:8) == 4,"proportional when lengths differ")
        expect(SpeechScript.spokenCount(at:1,starts:[],scriptLength:4) == 0,"no timing")
        let segments=[SpeechSegment(key:"msg",display:"晚上好。"),SpeechSegment(key:"card",lead:"先来听。",display:"很安静")]
        expect(SpeechScript.highlighted(segments:segments,spokenCount:2,key:"msg") == 2,"first segment partial")
        expect(SpeechScript.highlighted(segments:segments,spokenCount:2,key:"card") == 0,"later segment dark")
        expect(SpeechScript.highlighted(segments:segments,spokenCount:6,key:"card") == 0,"lead is not highlighted")
        expect(SpeechScript.highlighted(segments:segments,spokenCount:10,key:"card") == 2,"card after lead")
        expect(SpeechScript.highlighted(segments:segments,spokenCount:99,key:"msg") == 4,"clamped")
        expect(SpeechScript.highlighted(segments:segments,spokenCount:3,key:"other") == nil,"unrelated key")
        let longCaption=String(repeating:"夜",count:120)
        expect(SpeechScript.captionWindow(longCaption,spokenCount:50).sentence.count == 48,"long unpunctuated caption stays bounded")
        expect(SpeechScript.captionWindow(longCaption,spokenCount:50).highlighted == 2,"caption advances with audio")
        expect(SpeechScript.captionWindow(longCaption,spokenCount:120).highlighted == 24,"end stays on final caption")
        expect(SpeechScript.captionWindow("🎵你好",spokenCount:2,limit:1).sentence == "好","caption uses grapheme boundaries")
        expect(SpeechScript.captionWindow("",spokenCount:0).sentence.isEmpty,"empty caption")
        let line=SpeechScript.currentSentence("晚上好。先来听这首。很安静",spokenCount:6)
        expect(line.sentence == "先来听这首。" && line.highlighted == 2,"current sentence")
        expect(SpeechScript.currentSentence("晚上好。先来听这首。很安静",spokenCount:12).sentence == "很安静","trailing sentence")
        expect(SpeechScript.currentSentence("只有一句",spokenCount:2) == ("只有一句",2) ,"single sentence")

        let defaults=UserDefaults(suiteName:"vr-voice-tests-\(UUID())")!
        let voice=DJVoice(defaults:defaults,cache:cache)
        expect(voice.configuration.voiceID.isEmpty && !voice.configuration.ready,"no built-in voice; user must pick one")
        try voice.save(VoiceConfiguration(apiKey:" saved-key ",voiceID:" voiceCCCC "))
        expect(Vault.items["elevenLabsKey"] == "saved-key" && defaults.string(forKey:"djVoiceID") == "voiceCCCC","key to vault, voice to defaults")
        expect(DJVoice(defaults:defaults,cache:cache).configuration.ready,"settings restore")
        var ducks:[Bool]=[]
        voice.duck={ducks.append($0)}
        voice.stop()
        expect(ducks.isEmpty,"stop while idle does not unduck")
        // 语气声
        expect(ToneMarks.strip("（叹气）今天辛苦了。") == "今天辛苦了。" && ToneMarks.tagged("（叹气）今天辛苦了。") == "[sighs] 今天辛苦了。","tone mark stripped / tagged")
        expect(ToneMarks.strip("《出现又离开 (Live)》（低声）晚安") == "《出现又离开 (Live)》晚安","only known tone marks removed")
        expect(ToneMarks.tagged("好(轻笑) 那就这首") == "好[chuckles] 那就这首","half-width parens accepted")
        expect(ToneMarks.visibleStarts(characters:["[","s","]"," ","今","天"],starts:[0,0.1,0.2,0.3,0.5,0.7]) == [0.5,0.7],"tag timings dropped")
        let toned=SpeechSegment(key:"k",lead:"先来听。",display:"（嗯）这首很安静")
        expect(toned.spoken == "先来听。这首很安静" && toned.synthesis(tags:true) == "先来听。[hmm] 这首很安静" && toned.synthesis(tags:false) == toned.spoken,"segment spoken vs synthesis")
        expect(SpeechScript.highlighted(segments:[toned],spokenCount:7,key:"k") == 3,"highlight ignores tone mark")
        expect(!VoiceConfiguration(apiKey:"k",voiceID:"v",model:"eleven_multilingual_v2").supportsToneTags,"old model has no tags")
        // 语音识别
        let pcm=Data(repeating:1,count:3200)
        let wav=ElevenLabsSTT.wav(pcm16:pcm)
        expect(wav.count == 44 + 3200 && wav.prefix(4) == Data("RIFF".utf8) && wav[8..<16] == Data("WAVEfmt ".utf8),"wav header")
        expect(wav[24..<28] == Data([0x80,0x3E,0,0]),"16 kHz sample rate")
        expect(ElevenLabsSTT.wav(pcm16:Data(count:ElevenLabsSTT.maxBytes + 10)).count == 44 + ElevenLabsSTT.maxBytes,"recording capped")
        let stt=try ElevenLabsSTT.request(pcm16:pcm,apiKey:" k ",boundary:"B")
        let sttBody=String(decoding:stt.httpBody!,as:UTF8.self)
        expect(stt.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text" && stt.value(forHTTPHeaderField:"xi-api-key") == "k","stt endpoint and key")
        expect(stt.value(forHTTPHeaderField:"Content-Type") == "multipart/form-data; boundary=B","multipart boundary")
        expect(sttBody.contains("name=\"model_id\"\r\n\r\nscribe_v2") && !sttBody.contains("language_code") && sttBody.contains("filename=\"voice.wav\"") && sttBody.hasSuffix("--B--\r\n"),"multipart fields")
        do {_=try ElevenLabsSTT.request(pcm16:pcm,apiKey:" ");preconditionFailure("no key")} catch {expect(error as? VoiceError == .notConfigured,"stt needs key")}
        expect(try ElevenLabsSTT.parse(data:Data(#"{"text":" 放一首晴天 ","language_code":"zho"}"#.utf8),status:200) == "放一首晴天","transcript parsed")
        do {_=try ElevenLabsSTT.parse(data:Data(#"{"detail":{"status":"invalid_api_key"}}"#.utf8),status:401);preconditionFailure("401")} catch {expect(error as? VoiceError == .invalidKey,"stt bad key")}
        do {_=try ElevenLabsSTT.parse(data:Data("{}".utf8),status:200);preconditionFailure("bad")} catch {expect(error as? VoiceError == .malformed,"stt malformed")}
        expect(ToneMarks.minimax("（轻笑）好（低声）晚安") == "(chuckle) 好晚安","MiniMax native tone tags and unsupported mark removal")
        // MiniMax 区域隔离、请求与错误包（全部使用虚构凭据，无真实计费）。
        var mini = VoiceConfiguration(apiKey:" cn-test ",voiceID:"male-qn-qingse",model:"speech-2.8-turbo",provider:.minimaxCN)
        let cn = try MiniMaxClient.request(text:String(repeating:"晚",count:1200),configuration:mini)
        expect(cn.url?.host == "api.minimax.cn" && cn.value(forHTTPHeaderField:"Authorization") == "Bearer cn-test","China host and bearer")
        let miniBody = try JSONSerialization.jsonObject(with:cn.httpBody!) as! [String:Any]
        expect((miniBody["text"] as? String)?.count == 1000 && miniBody["output_format"] as? String == "hex","MiniMax bounded hex request")
        expect(!mini.supportsToneTags,"MiniMax does not receive ElevenLabs tone tags")
        let cnCache = cache.key(text:"hi",configuration:mini)
        try voice.save(mini)
        mini.provider = .minimaxGlobal; mini.apiKey = "global-test"; mini.model = "speech-2.8-hd"
        let global = try MiniMaxClient.request(text:"hi",configuration:mini)
        expect(global.url?.host == "api.minimax.io","international host")
        expect(cnCache != cache.key(text:"hi",configuration:mini),"region cache separated")
        try voice.save(mini)
        expect(voice.configuration(for:.minimaxCN).apiKey == "cn-test" && voice.configuration(for:.minimaxGlobal).apiKey == "global-test","region credentials isolated")
        expect(voice.recognitionKey == "saved-key","STT never uses MiniMax credentials")
        expect(DJVoice(defaults:defaults,cache:cache).configuration == mini,"provider model and voice restore")
        let miniClip = try MiniMaxClient.parse(data:Data(#"{"base_resp":{"status_code":0},"data":{"audio":"0102ff"}}"#.utf8),status:200)
        expect(miniClip.audio == Data([1,2,255]) && miniClip.characterStarts.isEmpty,"hex audio without invented exact timestamps")
        for payload in [#"{"base_resp":{"status_code":1004}}"#, #"{"base_resp":{"status_code":0},"data":{"audio":"xyz"}}"#, #"{"data":{"audio":"01"}}"#, #"{"base_resp":{"status_code":0},"data":{"audio":"gg"}}"#] {
            do { _ = try MiniMaxClient.parse(data:Data(payload.utf8),status:200); preconditionFailure("must reject invalid envelope") }
            catch { expect(error is MiniMaxClient.Failure,"invalid envelope rejected") }
        }
        let profileDefaults=UserDefaults(suiteName:"vr-profile-tests-\(UUID())")!
        let profileVoice=DJVoice(defaults:profileDefaults,cache:cache)
        // Vault may contain an existing ElevenLabs key: migration is expected and preserved.
        let initialCount=profileVoice.profiles.count
        let cnProfile=VoiceConfiguration(apiKey:"cn-profile-key",voiceID:"cn-voice",model:"speech-2.8-turbo",provider:.minimaxCN)
        let globalProfile=VoiceConfiguration(apiKey:"global-profile-key",voiceID:"global-voice",model:"speech-2.8-hd",provider:.minimaxGlobal)
        try profileVoice.saveProfile(cnProfile,name:"中文 DJ")
        let cnID=profileVoice.activeProfileID!
        try profileVoice.saveProfile(globalProfile,name:"夜晚 DJ")
        let globalID=profileVoice.activeProfileID!
        expect(profileVoice.profiles.count == initialCount+2 && cnID != globalID,"multiple named voices")
        try profileVoice.activateProfile(cnID)
        expect(profileVoice.configuration == cnProfile,"voice profile restores region key voice and model")
        try profileVoice.saveProfile(cnProfile,name:"改名 DJ",id:cnID)
        expect(profileVoice.profiles.count == initialCount+2,"voice edit does not duplicate")
        let voiceMetadata=String(decoding:profileDefaults.data(forKey:"voiceProfiles")!,as:UTF8.self)
        expect(!voiceMetadata.contains("cn-profile-key") && !voiceMetadata.contains("global-profile-key"),"voice metadata excludes keys")
        expect(DJVoice(defaults:profileDefaults,cache:cache).activeProfileID == cnID,"voice active profile restores")
        try profileVoice.deleteProfile(cnID)
        expect(profileVoice.activeProfileID != cnID && Vault.read("voiceProfile-"+cnID.uuidString).isEmpty,"voice deletion clears credential and falls back")
        for profile in profileVoice.profiles { try profileVoice.deleteProfile(profile.id) }
        expect(profileVoice.profiles.isEmpty && !profileVoice.configuration.ready,"last voice deletion uses system fallback")
        print("Voice checks passed: \(checks)")
    }
}
