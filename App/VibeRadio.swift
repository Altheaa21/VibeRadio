import SwiftUI
import AVFoundation
import Combine
import Security
import MediaPlayer
import MediaToolbox
#if os(macOS)
import AppKit
#else
import UIKit
#endif


enum Vault {
    static let service = "dev.viberadio.prototype"
    static func read(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ key: String, _ value: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = q
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(attrs as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: "Keychain", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "无法保存登录凭据（Keychain \(result)）"]) }
    }
}

@MainActor final class RadioModel: ObservableObject {
    @Published var endpoint = UserDefaults.standard.string(forKey: "bridgeURL") ?? "http://127.0.0.1:3300"
    @Published var bridgeToken = Vault.read("bridgeToken")
    @Published var status = "连接本地服务，开始验证。"
    @Published var error = ""
    @Published var nickname = ""
    @Published var accountID:Int64?
    @Published var recommendationQueue:[Track] = []
    @Published var queueExhausted = false
    @Published var qrData: Data?
    @Published var qrURL: URL?
    @Published var playlists: [Playlist] = []
    @Published var tracks: [Track] = []
    @Published var selected: Int64?
    @Published var current: Track?
    @Published var playing = false
    @Published var elapsed = 0.0
    @Published var duration = 0.0
    @Published var busy = false
    /// 用户音量 0…1（与 DJ 说话时的压低相乘）。
    @Published private(set) var volume: Float = UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 1
    /// 推荐/收藏/搜索等临时队列的名字。
    @Published var queueTitle = "DJ 推荐队列"
    @Published private(set) var lyrics: [LyricLine] = []
    /// 当前歌曲的音源地址（投放到 DLNA 音箱时用）。
    @Published private(set) var currentURL: URL?
    /// 投放到外部音箱时本机静音继续走时间线，切歌、歌词和串词照常。
    var localMuted: Bool { get { player.isMuted } set { player.isMuted = newValue; objectWillChange.send() } }
    @Published private(set) var lyricsStatus = ""
    /// 桥接服务是否在线：nil 尚未检查。
    @Published private(set) var bridgeOnline: Bool?
    private var duckLevel: Float = 1
    private var lyricsTask: Task<Void, Never>?
    private var healthLoop: Task<Void, Never>?
    private var cookie = Vault.read("cookie")
    private var poll: Task<Void, Never>?
    private var playbackObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    /// 队列播放器：剩约 30 秒时把下一首排进去预先缓冲，播完直接接上，不再有取地址和缓冲的静音。
    private let player = AVQueuePlayer()
    /// 当前这首对应的播放条目（队列自动前进后 player.currentItem 会先变，用它判断「哪首播完了」）。
    private var currentItem: AVPlayerItem?
    /// 已排进队列、等着接上的下一首。
    private var prepared: (track: Track, item: AVPlayerItem, generation: Int)?
    private var preparing: Task<Void, Never>?
    /// 当前歌曲的实时响度；界面按帧读取，不经 @Published，避免每秒几十次刷新整棵视图。
    let meter = AudioLevelMeter()
    private var timeObserver: Any?
    private var remoteTargets: [Any] = []
    #if os(iOS)
    /// 来电、Siri、闹钟或其他 App 抢走声音时记下「原本在播」，结束后系统允许就接着放。
    private var resumeAfterInterruption = false
    private var sessionObservers: [NSObjectProtocol] = []
    #endif

    init() {
        #if DEBUG && os(iOS)
        // 真机调试启动时一次性设置私有桥接；凭据不编进应用，连接成功后存钥匙串。
        let launchEnvironment=ProcessInfo.processInfo.environment
        if let address=launchEnvironment["VIBERADIO_DEVICE_BRIDGE_URL"],
           let secret=launchEnvironment["VIBERADIO_DEVICE_BRIDGE_TOKEN"], !secret.isEmpty,
           let url=URL(string:address), url.scheme == "http", url.port == 3301 {
            endpoint=address;bridgeToken=secret
        }
        #endif
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                let d = self.player.currentItem?.duration.seconds ?? 0
                self.duration = d.isFinite ? d : 0
                self.playing = self.player.timeControlStatus == .playing
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.elapsed; info[MPNowPlayingInfoPropertyPlaybackRate] = self.playing ? 1.0 : 0.0
                    if self.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = self.duration }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
                self.checkApproachingEnd()
            }
        }
        #if DEBUG && os(macOS)
        // 仅调试构建：本机测试工具可让当前歌跳到结尾前 N 秒，用来验收串词等切歌行为。
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.viberadio.debug.seekNearEnd"), object: nil, queue: .main) { [weak self] note in
            let lead = Double(note.object as? String ?? "") ?? 28
            Task { @MainActor in guard let self, self.duration > lead else { return }; self.seek(self.duration - lead) }
        }
        #endif
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.currentItem else { return }
                let from = self.current
                if self.stopAtEnd { self.stopAtEnd = false; self.player.pause(); self.playing = false; self.onStoppedAtEnd?(); return }
                if !self.adoptPrepared() { await self.next(userInitiated:false) }
                // 只有自然播完才算「切歌」，给 DJ 串词；手动下一首不触发。
                if let from, let to = self.current, to.id != from.id { self.onNaturalTransition?(from, to) }
            }
        }
        let center = MPRemoteCommandCenter.shared()
        remoteTargets.append(center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.play() }; return .success })
        remoteTargets.append(center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause() }; return .success })
        remoteTargets.append(center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.next() }; return .success })
        remoteTargets.append(center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.previous() }; return .success })
        remoteTargets.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success })
        remoteTargets.append(center.stopCommand.addTarget { [weak self] _ in Task { @MainActor in self?.stop() }; return .success })
        remoteTargets.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        })
        player.volume = volume
        #if os(iOS)
        observeAudioSession()
        #endif
    }
    #if os(iOS)
    private func observeAudioSession() {
        let center = NotificationCenter.default, session = AVAudioSession.sharedInstance()
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            // 应用被系统挂起后补发的「开始」不是真打断，不能据此改状态。
            let suspended = info[AVAudioSessionInterruptionWasSuspendedKey] as? Bool ?? false
            Task { @MainActor in self?.handleInterruption(type, options: options, suspended: suspended) }
        })
        // 拔耳机或蓝牙断开时系统会暂停播放器，这里只同步界面状态，不自动外放。
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in guard let self else { return }; self.resumeAfterInterruption = false; self.playing = self.player.timeControlStatus == .playing }
        })
        // 系统媒体服务重启后音频会话失效，重新设置才能继续出声。
        sessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                if self.playing { try? AVAudioSession.sharedInstance().setActive(true); self.player.play() }
            }
        })
    }
    private func handleInterruption(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions, suspended: Bool) {
        switch type {
        case .began:
            guard !suspended else { return }
            resumeAfterInterruption = playing || player.rate > 0
            playing = false
        case .ended:
            defer { resumeAfterInterruption = false }
            guard resumeAfterInterruption, options.contains(.shouldResume), currentItem != nil else { return }
            do { try AVAudioSession.sharedInstance().setActive(true) } catch { return }
            player.play(); playing = true
        @unknown default: break
        }
    }
    #endif
    /// 每 20 秒探一次桥接服务；断开时界面提示，恢复后自动重新读取账号。
    func startHealthMonitor() {
        healthLoop?.cancel()
        healthLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                let wasOnline = self.bridgeOnline
                do { _ = try await self.request("health"); self.bridgeOnline = true
                    if wasOnline == false, !self.cookie.isEmpty, self.accountID == nil { try? await self.loadAccount() }
                } catch { self.bridgeOnline = false }
            }
        }
    }

    func request(_ route: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        guard let base = URL(string: endpoint), ["http", "https"].contains(base.scheme ?? ""), let host = base.host, !host.isEmpty else { throw failure("服务地址无效") }
        if base.scheme == "http" && !["127.0.0.1", "localhost"].contains(host) && !host.hasPrefix("192.168.") && !host.hasPrefix("10.") && !host.hasPrefix("172.") {
            throw failure("公网服务必须使用 HTTPS")
        }
        var req = URLRequest(url: base.appendingPathComponent(route))
        req.httpMethod = "POST"; req.timeoutInterval = 60 // 免费云端服务休眠后唤醒要几十秒
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "X-NCM-Cookie") }
        if !bridgeToken.isEmpty { req.setValue("Bearer \(bridgeToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("服务返回格式异常") }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure(result["error"] as? String ?? "服务请求失败") }
        if let code = result["code"] as? Int, code != 200 && !(800...803).contains(code) { throw failure(result["message"] as? String ?? "网易云返回错误 \(code)") }
        return result
    }
    func failure(_ message: String) -> NSError { NSError(domain: "VibeRadio", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func connect() async {
        busy = true; error = ""
        defer { busy = false }
        do {
            _ = try await request("health")
            bridgeOnline = true
            UserDefaults.standard.set(endpoint, forKey: "bridgeURL")
            try Vault.write("bridgeToken", bridgeToken)
            status = "桥接服务已连接"
            if !cookie.isEmpty { try await loadAccount() }
        } catch {
            if (error as? URLError) != nil { bridgeOnline = false; self.error = "连不上本机音乐服务（\(endpoint)）。请确认桥接服务已启动；恢复后会自动重连。" }
            else { self.error = error.localizedDescription }
        }
    }
    func login() async {
        poll?.cancel(); busy = true; error = ""; qrData = nil
        defer { busy = false }
        do {
            let keyResult = try await request("qr/key")
            guard let data = keyResult["data"] as? [String: Any], let key = data["unikey"] as? String else { throw failure("未获取到登录二维码 key") }
            let result = try await request("qr/create", ["key": key])
            guard let qr = result["data"] as? [String: Any], let image = qr["qrimg"] as? String,
                  let bytes = Data(base64Encoded: String(image.split(separator: ",").last ?? "")) else { throw failure("二维码生成失败") }
            qrData = bytes; qrURL = URL(string: qr["qrurl"] as? String ?? "")
            status = "用网易云音乐 App 扫码，并在手机上确认登录"
            poll = Task {
                for _ in 0..<90 {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        let check = try await request("qr/check", ["key": key])
                        try Task.checkCancellation()
                        switch check["code"] as? Int {
                        case 800: status = "二维码已过期，请重新生成"; qrData = nil; return
                        case 802: status = "已扫码，请在网易云音乐中确认"
                        case 803:
                            guard let c = check["cookie"] as? String, !c.isEmpty else { throw failure("登录确认成功，但没有返回凭据") }
                            try Vault.write("cookie", c); cookie = c; qrData = nil
                            try await loadAccount(); return
                        default: break
                        }
                    } catch is CancellationError { return }
                    catch { self.error = error.localizedDescription; return }
                }
                status = "扫码等待超时，请重新生成"; qrData = nil
            }
        } catch { self.error = error.localizedDescription }
    }
    func loadAccount() async throws {
        let account = try await request("account")
        guard let profile = account["profile"] as? [String: Any], let uid = profile["userId"] as? NSNumber else { throw failure("登录已失效，请重新扫码") }
        accountID=uid.int64Value
        nickname = profile["nickname"] as? String ?? "已登录"
        var all: [Playlist] = []; var offset = 0
        while true {
            let result = try await request("playlists", ["uid": uid.int64Value, "offset": offset])
            let page = result["playlist"] as? [[String: Any]] ?? []
            all += page.compactMap { p in guard let id = p["id"] as? NSNumber else { return nil }; return Playlist(id: id.int64Value, name: p["name"] as? String ?? "歌单", count: p["trackCount"] as? Int ?? 0,tags:p["tags"] as? [String] ?? [],description:p["description"] as? String ?? "") }
            if page.isEmpty || result["more"] as? Bool != true { break }; offset += page.count
        }
        playlists = all; status = "登录成功 · 已读取 \(all.count) 个歌单"
    }
    func loadTracks(_ playlist: Playlist) async {
        busy = true; error = ""; selected = playlist.id; tracks = []
        defer { busy = false }
        do {
            var all: [Track] = []; var offset = 0
            while offset < playlist.count || offset == 0 {
                let result = try await request("tracks", ["id": playlist.id, "offset": offset])
                let page = result["songs"] as? [[String: Any]] ?? []
                all += page.compactMap(Track.fromNetEase)
                if page.count < 100 { break }; offset += page.count
            }
            tracks = all; status = "已读取 \(all.count) 首歌曲"
        } catch { self.error = error.localizedDescription }
    }
    enum PlayOutcome { case started, failed, superseded }
    /// 每次发起播放或退出登录都递增；网络等待结束后若代次或账号已变，旧请求不得再改动播放状态。
    private var playGeneration = 0
    @discardableResult
    func play(_ track: Track, fromRecommendation:Bool=false) async -> PlayOutcome {
        if !fromRecommendation { recommendationQueue=[] }
        waitingForMore = false
        playGeneration += 1
        let generation = playGeneration, account = accountID
        error = ""; player.pause(); playing = false
        dropPrepared()
        do {
            let url: URL
            do { url = try await streamURL(track) }
            catch let network as URLError where network.code != .cancelled {
                // 网络抖动时等一下再试一次，仍失败再报错。
                try await Task.sleep(for: .seconds(1.5))
                guard generation == playGeneration else { return .superseded }
                url = try await streamURL(track)
            }
            guard generation == playGeneration, account == accountID else { return .superseded }
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let item = AVPlayerItem(url: url)
            player.removeAllItems(); player.insert(item, after: nil)
            begin(track, item: item, generation: generation)
            Task { [weak self] in
                let tapped = await AudioLevelMeter.attach(to: item)
                #if DEBUG
                meterDebug("VibeRadio meter attach: %@", tapped == nil ? "nil" : "ok")
                #endif
                guard let self, generation == self.playGeneration, item === self.currentItem, let tapped else { return }
                tapped.meter = self.meter
                item.audioMix = tapped.mix
            }
            player.play(); status = "已获取非试听音源，正在加载；请核对实际时长并试听"
            return .started
        } catch {
            guard generation == playGeneration, account == accountID else { return .superseded }
            self.error = error.localizedDescription
            return .failed
        }
    }
    /// 取完整音源地址；会员/版权/试听片段都当作不可播放。
    private func streamURL(_ track: Track) async throws -> URL {
        let result = try await request("stream", ["id": track.id])
        guard let entry = (result["data"] as? [[String: Any]])?.first,
              let address = entry["url"] as? String, let url = URL(string: address) else { throw failure("这首歌暂时不可播放：可能受会员、版权或地区限制") }
        if let trial = entry["freeTrialInfo"], !(trial is NSNull), !(trial is String && trial as? String == "null") { throw failure("接口只返回了试听片段，未计为完整播放；请选择其他歌曲验证") }
        return url
    }
    /// 把某个条目记为「正在播的这首」：状态、失败监听、锁屏信息。
    private func begin(_ track: Track, item: AVPlayerItem, generation: Int) {
        currentItem = item; current = track; elapsed = 0; duration = 0
        currentURL = (item.asset as? AVURLAsset)?.url
        meter.reset()
        playbackObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in await self?.handleAsyncLoadFailure(item, generation: generation) }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track.name, MPMediaItemPropertyArtist: track.artist, MPMediaItemPropertyPlaybackDuration: track.milliseconds / 1000]
        loadLyrics(track)
    }
    private func loadLyrics(_ track: Track) {
        lyricsTask?.cancel(); lyrics = []; lyricsStatus = "正在读取歌词…"
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.request("lyric", ["id": track.id])
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                let lines = LyricParser.parse(result["lrc"] as? String ?? "", translation: result["translation"] as? String ?? "")
                self.lyrics = lines
                self.lyricsStatus = lines.isEmpty ? ((result["pure"] as? Bool) == true ? "纯音乐，请欣赏" : "暂无歌词") : ""
            } catch {
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                self.lyricsStatus = "歌词暂时读取不到"
            }
        }
    }
    // MARK: 音量、停止、上一首、搜索、喜欢
    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        UserDefaults.standard.set(volume, forKey: "playerVolume")
        duckTask?.cancel(); player.volume = volume * duckLevel
    }
    func stop() {
        player.pause(); seek(0); playing = false
    }
    func previous() async {
        if elapsed > 5 { seek(0); return }
        if let current, let index = recommendationQueue.firstIndex(where: { $0.id == current.id }) {
            if index > 0 { await playRecommendations(recommendationQueue, startingAt: recommendationQueue[index - 1].id) } else { seek(0) }
            return
        }
        guard let current, let i = tracks.firstIndex(where: { $0.id == current.id }), i > 0 else { seek(0); return }
        await play(tracks[i - 1])
    }
    /// 接下来要播的歌（推荐/临时队列优先，其次当前歌单），最多 30 首。
    var upNext: [Track] {
        guard let current else { return [] }
        if let index = recommendationQueue.firstIndex(where: { $0.id == current.id }) { return Array(recommendationQueue.dropFirst(index + 1).prefix(30)) }
        if let i = tracks.firstIndex(where: { $0.id == current.id }) { return Array(tracks.dropFirst(i + 1).prefix(30)) }
        return []
    }
    func playList(_ list: [Track], startingAt id: Int64, title: String) async {
        queueTitle = title
        await playRecommendations(list, startingAt: id)
    }
    func search(_ keywords: String, limit: Int = 20) async throws -> [Track] {
        let text = keywords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let result = try await request("search", ["keywords": String(text.prefix(80)), "limit": limit])
        let songs = (result["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        return songs.compactMap(Track.fromNetEase)
    }
    /// 搜索并播放第一首能完整播放的；返回实际播放的歌，失败返回 nil（error 里有原因）。
    func playSearch(_ keywords: String) async -> Track? {
        do {
            let results = try await search(keywords, limit: 8)
            guard !results.isEmpty else { error = "没有搜到「\(keywords)」"; return nil }
            for track in results.prefix(4) {
                queueTitle = "搜索：\(String(keywords.prefix(12)))"
                switch await play(track, fromRecommendation: true) {
                case .started: recommendationQueue = [track]; return track
                case .superseded: return nil
                case .failed: continue
                }
            }
            return nil
        } catch { self.error = error.localizedDescription; return nil }
    }
    /// 接力：直接按歌曲 ID 播放另一台设备上的那首。
    func playSearchExact(_ track: Track) async -> Bool { await play(track) == .started }
    func like(_ track: Track, _ on: Bool) async throws { _ = try await request("like", ["id": track.id, "like": on]) }
    /// 网易云「喜欢的音乐」：先取 ID，再分批取歌曲信息（最多 200 首）。
    func likedTracks() async throws -> [Track] {
        guard let accountID else { return [] }
        let result = try await request("likelist", ["uid": accountID])
        let ids = (result["ids"] as? [NSNumber] ?? []).map(\.int64Value).prefix(200)
        var tracks: [Track] = []
        for chunk in stride(from: 0, to: ids.count, by: 50) {
            let detail = try await request("song/detail", ["ids": Array(ids.dropFirst(chunk).prefix(50))])
            tracks += (detail["songs"] as? [[String: Any]] ?? []).compactMap(Track.fromNetEase)
        }
        return tracks
    }
    /// 剩约 30 秒时调用：取下一首地址、挂好响度分析，排进队列让播放器提前缓冲。失败就算了，到时照旧现取。
    private func prepareUpcoming(_ track: Track) {
        let generation = playGeneration, account = accountID
        guard prepared?.track.id != track.id, !stopAtEnd else { return }
        dropPrepared()
        preparing = Task { [weak self] in
            guard let self, let url = try? await self.streamURL(track) else { return }
            guard !Task.isCancelled, generation == self.playGeneration, account == self.accountID,
                  self.upcomingTrack()?.id == track.id, let playing = self.currentItem, self.player.items().first === playing else { return }
            let item = AVPlayerItem(url: url)
            if let tapped = await AudioLevelMeter.attach(to: item) { tapped.meter = self.meter; item.audioMix = tapped.mix }
            guard !Task.isCancelled, generation == self.playGeneration, self.player.items().first === playing else { return }
            self.player.insert(item, after: playing)
            self.prepared = (track, item, generation)
            #if DEBUG
            meterDebug("VibeRadio prepared next: %@", track.name)
            #endif
        }
    }
    private func dropPrepared() {
        preparing?.cancel(); preparing = nil
        if let item = prepared?.item, player.items().contains(item) { player.remove(item) }
        prepared = nil
    }
    /// 播完时若下一首已经排好且就是该接的那首，直接接上（播放器已在缓冲），返回 true；否则交给 next() 现取。
    private func adoptPrepared() -> Bool {
        guard let p = prepared, p.generation == playGeneration, upcomingTrack()?.id == p.track.id,
              p.item.status != .failed, player.items().contains(p.item) else { dropPrepared(); return false }
        prepared = nil; preparing = nil
        if player.currentItem !== p.item { player.advanceToNextItem() }
        playGeneration += 1
        begin(p.track, item: p.item, generation: playGeneration)
        player.play()
        #if DEBUG
        meterDebug("VibeRadio gapless handoff: %@", p.track.name)
        #endif
        return true
    }
    /// AVPlayer 在音源地址取得后才异步加载失败：只处理仍是当前代次的条目；推荐队列中则顺延到下一首候选。
    private func handleAsyncLoadFailure(_ item: AVPlayerItem, generation: Int) async {
        guard generation == playGeneration, item === currentItem else { return }
        playing = false
        let failedName = current?.name ?? "这首歌"
        if let current, let index = recommendationQueue.firstIndex(where: { $0.id == current.id }), index + 1 < recommendationQueue.count {
            status = "「\(failedName)」音频加载失败，正在换下一首推荐"
            await playRecommendations(recommendationQueue, startingAt: recommendationQueue[index + 1].id)
            return
        }
        error = "「\(failedName)」音频加载失败，请重试或更换歌曲"
    }
    private var duckTask: Task<Void, Never>?
    /// DJ 说话时把音乐压到约两成音量，说完约一秒内平滑恢复。
    func duck(_ on: Bool) {
        duckTask?.cancel()
        duckLevel = on ? 0.22 : 1.0
        let start = player.volume, target: Float = volume * duckLevel
        duckTask = Task { @MainActor [weak self] in
            for step in 1...12 {
                try? await Task.sleep(for: .milliseconds(on ? 35 : 80))
                guard let self, !Task.isCancelled else { return }
                self.player.volume = start + (target - start) * Float(step) / 12
            }
        }
    }
    func toggle() { if player.rate > 0 { player.pause() } else { player.play() } }
    func playRecommendations(_ queue:[Track],startingAt id:Int64) async {
        recommendationQueue=queue
        guard let index=queue.firstIndex(where:{$0.id==id}) else { return }
        for track in queue.dropFirst(index).prefix(5) {
            switch await play(track,fromRecommendation:true) {
            case .started, .superseded: return
            case .failed: continue
            }
        }
    }
    /// 剩约 30 秒时通知一次（用来提前写好并合成串词）；自然播完切到下一首时再通知一次。
    var onApproachingEnd: ((Track, Track) -> Void)?
    var onNaturalTransition: ((Track, Track) -> Void)?
    private var approachingNotified = -1
    var onStoppedAtEnd: (() -> Void)?
    /// 把续选的歌接到推荐队列后面（去重）；如果队列已经放完在等，就直接开始放。
    func appendToQueue(_ list: [Track]) async {
        let known = Set(recommendationQueue.map(\.id))
        let fresh = list.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { waitingForMore = false; return }
        recommendationQueue += fresh
        if waitingForMore, let first = fresh.first {
            waitingForMore = false
            await playRecommendations(recommendationQueue, startingAt: first.id)
        }
    }
    /// 睡前定时到点：约 20 秒内把音量慢慢降到 0 再暂停，然后恢复音量设置。
    func fadeOutAndPause(seconds: Double = 20) async {
        duckTask?.cancel()
        let start = player.volume, steps = 40
        for step in 1...steps {
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
            player.volume = start * Float(steps - step) / Float(steps)
        }
        player.pause(); playing = false; waitingForMore = false
        player.volume = volume * duckLevel
    }
    /// 推荐队列最后一首剩约 75 秒时通知一次（「一直播」时用来续选下一组）。
    var onQueueEnding: (() -> Void)?
    private var queueEndingNotified = -1
    /// 播完这首就停（睡前用）：不再预取下一首，自然结束时暂停。
    @Published var stopAtEnd = false { didSet { if stopAtEnd { dropPrepared() } } }
    /// 队列已放完、正在等续选结果。
    private var waitingForMore = false
    private func checkApproachingEnd() {
        guard playing, duration > 40, let current else { return }
        if duration - elapsed < 75, queueEndingNotified != playGeneration, !stopAtEnd, recommendationQueue.last?.id == current.id {
            queueEndingNotified = playGeneration; onQueueEnding?()
        }
        guard duration - elapsed < 30, approachingNotified != playGeneration, !stopAtEnd, let upcoming = upcomingTrack() else { return }
        approachingNotified = playGeneration
        prepareUpcoming(upcoming)
        onApproachingEnd?(current, upcoming)
    }
    /// 自然播完后会接着播的歌：推荐队列优先，其次当前歌单。
    func upcomingTrack() -> Track? {
        guard let current else { return nil }
        if let index = recommendationQueue.firstIndex(where: { $0.id == current.id }) {
            return index + 1 < recommendationQueue.count ? recommendationQueue[index + 1] : nil
        }
        guard let i = tracks.firstIndex(where: { $0.id == current.id }), i + 1 < tracks.count else { return nil }
        return tracks[i + 1]
    }
    /// 手动到队尾只提示，不改变播放／暂停状态；自然播完则等待续曲。
    func next(userInitiated:Bool = true) async {
        guard let upcoming = upcomingTrack() else {
            if userInitiated { queueExhausted = true }
            else { waitingForMore = true; playing = false }
            return
        }
        queueExhausted = false
        if let current, recommendationQueue.contains(where: { $0.id == current.id }) {
            await playRecommendations(recommendationQueue,startingAt:upcoming.id)
        } else { await play(upcoming) }
    }
    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    func logout() {
        playGeneration += 1
        poll?.cancel(); player.pause(); dropPrepared(); player.removeAllItems(); currentItem = nil; meter.reset(); cookie = ""
        do { try Vault.write("cookie", "") } catch { self.error = error.localizedDescription }
        accountID=nil; recommendationQueue=[]; nickname = ""; playlists = []; tracks = []; current = nil; qrData = nil; status = "已退出本地登录"
    }
}

struct ConnectionLabView: View {
    @ObservedObject var model: RadioModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("VibeRadio / CONNECTION LAB").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text("先让音乐响起来。").font(.largeTitle.bold())
                    Text("网易云接入验证 · 此页面为临时测试界面").foregroundStyle(.secondary)
                    GroupBox("音乐桥接服务") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("http://127.0.0.1:3300 或 https://你的服务.onrender.com", text: $model.endpoint).textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await model.connect() } }
                            SecureField("连接令牌（本机可留空；局域网和云端必填）", text: $model.bridgeToken).textFieldStyle(.roundedBorder)
                            Button("连接 / 恢复登录") { Task { await model.connect() } }.disabled(model.busy)
                            Text("本机运行填 127.0.0.1；iPhone 连 Mac 填 Mac 的局域网地址；部署到 Render 等云端时填它给的 HTTPS 地址和令牌。").font(.caption).foregroundStyle(.secondary)
                        }.padding(6)
                    }
                    HStack {
                        Text(model.nickname.isEmpty ? "尚未登录" : model.nickname).font(.headline)
                        Spacer()
                        if !model.nickname.isEmpty { Button("退出登录") { model.logout() } }
                    }
                    HStack {
                        Button(model.qrData == nil ? "生成登录二维码" : "刷新二维码") { Task { await model.login() } }.buttonStyle(.borderedProminent).disabled(model.busy)
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                    if let data = model.qrData {
                        VStack(alignment: .leading, spacing: 10) {
                            #if os(macOS)
                            if let image = NSImage(data: data) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220).padding(12).background(.white) }
                            #else
                            if let image = UIImage(data: data) {
                                Image(uiImage: image).interpolation(.none).resizable().frame(width: 220, height: 220).padding(12).background(.white)
                                ShareLink(item: Image(uiImage: image), preview: SharePreview("网易云登录二维码", image: Image(uiImage: image))) { Label("保存 / 分享二维码", systemImage: "square.and.arrow.up") }
                            }
                            #endif
                            Text("请使用官方网易云音乐 App 扫码。手机同机识别流程仍需真机验证，首轮建议扫描 Mac 上的二维码。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(model.status).font(.callout)
                    if !model.error.isEmpty { Label(model.error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                    if let current = model.current {
                        GroupBox("播放验证") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(current.name).font(.headline)
                                Text(current.artist).foregroundStyle(.secondary)
                                Text("已播放 \(clock(model.elapsed)) / 音源 \(clock(model.duration)) · 歌曲标注 \(clock(current.milliseconds / 1000))").font(.caption.monospacedDigit())
                                Slider(value: Binding(get: { model.elapsed }, set: { model.seek($0) }), in: 0...max(model.duration, 1))
                                HStack {
                                    Button(model.playing ? "暂停" : "播放") { model.toggle() }
                                    Button("下一首") { Task { await model.next() } }
                                }
                            }.padding(6)
                        }
                    }
                    if !model.playlists.isEmpty {
                        Text("你的歌单").font(.title2.bold())
                        ForEach(model.playlists) { playlist in
                            Button { Task { await model.loadTracks(playlist) } } label: {
                                HStack { Image(systemName: model.selected == playlist.id ? "music.note.list" : "square.stack"); Text(playlist.name); Spacer(); Text("\(playlist.count) 首").foregroundStyle(.secondary) }.padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.busy)
                        }
                    }
                    if !model.tracks.isEmpty {
                        Divider(); Text("选择歌曲验证播放").font(.title2.bold())
                        LazyVStack(spacing: 0) {
                            ForEach(model.tracks) { track in
                                Button { Task { await model.play(track) } } label: {
                                    HStack { Image(systemName: model.current?.id == track.id ? "speaker.wave.2.fill" : "play.circle"); VStack(alignment: .leading) { Text(track.name); Text(track.artist).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(clock(track.milliseconds / 1000)).font(.caption.monospacedDigit()) }.padding(.vertical, 10).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }.padding(24).frame(maxWidth: 760)
                    .frame(maxWidth: .infinity, alignment: .center)
            }.navigationTitle("VibeRadio")
            .task { await model.connect() }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 700)
        #endif
    }
    func clock(_ value: Double) -> String { let s = value.isFinite ? max(Int(value), 0) : 0; return String(format: "%d:%02d", s / 60, s % 60) }
}
@main struct VibeRadioApp: App { var body: some Scene { WindowGroup { StudioRootView() } } }

/// 播放中的实时响度。音频线程写入，界面线程按帧读取；超过半秒没有新数据即视为不可用，界面退回呼吸动画。
final class AudioLevelMeter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value: Float = 0
    private var stamp: CFAbsoluteTime = 0
    func push(_ level: Float) { os_unfair_lock_lock(&lock); value = level; stamp = CFAbsoluteTimeGetCurrent(); os_unfair_lock_unlock(&lock) }
    func reset() { os_unfair_lock_lock(&lock); value = 0; stamp = 0; os_unfair_lock_unlock(&lock) }
    /// 0…1 的近似响度（RMS 换算到对数刻度）；nil 表示当前拿不到真实音频。
    var level: Float? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard CFAbsoluteTimeGetCurrent() - stamp < 0.5 else { return nil }
        return value
    }

    /// 音频处理回调持有的盒子：先建 tap，再在主线程确认条目仍是当前歌曲后接上 meter。
    final class Box: @unchecked Sendable { var meter: AudioLevelMeter?; var mix: AVAudioMix?; var isFloat = true; var format = "" }

    /// 为条目挂上只读 tap（不改声音）。读取音轨失败（如部分流媒体）时返回 nil，界面自动退回。
    static func attach(to item: AVPlayerItem) async -> Box? {
        let track: AVAssetTrack
        do {
            guard let first = try await item.asset.loadTracks(withMediaType: .audio).first else { meterDebug("VibeRadio meter: no audio track"); return nil }
            track = first
        } catch { meterDebug("VibeRadio meter: loadTracks failed %@", String(describing: error)); return nil }
        let box = Box()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque()),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let box = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = format.pointee
                box.isFloat = asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
                box.format = "flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel) ch=\(asbd.mChannelsPerFrame) rate=\(asbd.mSampleRate)"
            }, unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let box = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard let meter = box.meter, box.isFloat else { return }
                var sum: Float = 0, count = 0
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<n { sum += samples[i] * samples[i] }
                    count += n
                }
                let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
                // -48 dB…0 dB 映射到 0…1，安静段落也有细微起伏。
                let db = 20 * log10(max(rms, 0.000_01))
                meter.push(min(max((db + 48) / 48, 0), 1))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr, let tap else {
            Unmanaged.passUnretained(box).release(); return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
        box.mix = mix
        return box
    }
}

#if DEBUG
extension RadioModel {
    /// 仅 Debug 界面审核：填入示例歌词，不请求网易云。
    func loadReviewLyrics(_ lines: [LyricLine]) { lyrics = lines; lyricsStatus = "" }
}
#endif

/// 仅 Debug：把响度诊断写到临时文件，便于验收时确认 tap 是否真的拿到音频。
func meterDebug(_ format: String, _ args: CVarArg...) {
    #if DEBUG
    let line = String(format: format, arguments: args) + "\n"
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("viberadio-meter.log")
    if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
    else { try? Data(line.utf8).write(to: url) }
    #endif
}
