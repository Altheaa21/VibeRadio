import Foundation
import Combine
import SwiftUI
import EventKit
import Speech
import AVFoundation
import AVKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 日程（系统日历：iCloud、Google、Outlook，以及通过 CalDAV 添加到系统日历的飞书日历）

@MainActor final class CalendarService: ObservableObject {
    @Published private(set) var events: [DayEvent] = []
    @Published private(set) var status = "未连接"
    private let store = EKEventStore()
    var authorized: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, macOS 14.0, *) { return s == .fullAccess }
        return false
    }
    func request() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            status = granted ? "已连接系统日历" : "未获得日历权限，可在系统设置 › 隐私与安全性 › 日历中打开"
            if granted { refresh() }
            return granted
        } catch { status = "无法请求日历权限：\(error.localizedDescription)"; return false }
    }
    func refresh(now: Date = Date()) {
        guard authorized else { events = []; return }
        let start = Calendar.current.startOfDay(for: now)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        events = found.prefix(40).map { DayEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "日程", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay) }.sorted { $0.start < $1.start }
        status = events.isEmpty ? "已连接系统日历 · 今天没有日程" : "已连接系统日历 · 今天 \(events.count) 个日程"
    }
}

// MARK: - 语音输入：优先 ElevenLabs 识别，失败或没填 Key 时用系统识别（中文）

/// 录音线程里收集 16 kHz 单声道 PCM，并记录最近一次听到人声的时间。
private final class VoiceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private var lastVoice: Date?
    private let converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(ElevenLabsSTT.sampleRate), channels: 1, interleaved: true)!
    init(input: AVAudioFormat) { converter = AVAudioConverter(from: input, to: target) }
    func append(_ buffer: AVAudioPCMBuffer) {
        var level: Float = 0
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
            level = (sum / Float(buffer.frameLength)).squareRoot()
        }
        var converted: Data?
        if let converter {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
            if let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) {
                var fed = false
                _ = converter.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buffer
                }
                if let p = out.int16ChannelData?[0], out.frameLength > 0 { converted = Data(bytes: p, count: Int(out.frameLength) * 2) }
            }
        }
        lock.lock(); defer { lock.unlock() }
        if let converted, pcm.count < ElevenLabsSTT.maxBytes { pcm += converted }
        if level > 0.02 { lastVoice = Date() }
    }
    func heard() { lock.lock(); lastVoice = Date(); lock.unlock() }
    var snapshot: (pcm: Data, lastVoice: Date?) { lock.lock(); defer { lock.unlock() }; return (pcm, lastVoice) }
}

@MainActor final class SpeechInput: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var transcribing = false
    @Published private(set) var transcript = ""
    @Published private(set) var error = ""
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var watcher: Task<Void, Never>?
    private var capture: VoiceCapture?
    private var useCloud = false
    var onFinish: ((String) -> Void)?
    /// 由界面提供 ElevenLabs Key（只从钥匙串读，不落盘）。
    var elevenLabsKey: () -> String = { "" }

    func toggle() { if listening { finish() } else if !transcribing { Task { await start() } } }
    func start() async {
        error = ""; transcript = ""
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { error = "没有麦克风权限。请在系统设置 › 隐私与安全性 › 麦克风中允许 VibeRadio。"; return }
        useCloud = !elevenLabsKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        let local = speech == .authorized && recognizer?.isAvailable == true
        guard useCloud || local else {
            error = speech == .authorized ? "中文语音识别暂时不可用（可能需要联网）。" : "没有语音识别权限。请在系统设置 › 隐私与安全性 › 语音识别中允许 VibeRadio，或在 AI 设置里填写 ElevenLabs Key。"
            return
        }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let capture = VoiceCapture(input: format); self.capture = capture
            var request: SFSpeechAudioBufferRecognitionRequest?
            if local {
                let r = SFSpeechAudioBufferRecognitionRequest()
                r.shouldReportPartialResults = true
                if recognizer?.supportsOnDeviceRecognition == true { r.requiresOnDeviceRecognition = true }
                request = r
            }
            self.request = request
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request?.append(buffer); capture.append(buffer) }
            engine.prepare(); try engine.start()
            listening = true
            if let request, let recognizer {
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let result { self.transcript = result.bestTranscription.formattedString; self.capture?.heard() }
                        // 只用系统识别时，它说结束就结束；用 ElevenLabs 时以停顿为准。
                        if !self.useCloud, result?.isFinal == true || error != nil, self.listening { self.finish() }
                    }
                }
            }
            watchSilence()
        } catch { self.error = "无法开始录音：\(error.localizedDescription)"; cleanup() }
    }
    /// 说过话后停顿约 1.6 秒就当说完；一直没出声 6 秒后结束；最长 60 秒。
    private func watchSilence() {
        watcher?.cancel()
        let began = Date()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.listening, let capture = self.capture else { return }
                let now = Date()
                if let last = capture.snapshot.lastVoice { if now.timeIntervalSince(last) > 1.6 { self.finish(); return } }
                else if now.timeIntervalSince(began) > 6 { self.finish(); return }
                if now.timeIntervalSince(began) > 60 { self.finish(); return }
            }
        }
    }
    func finish() {
        guard listening else { return }
        let fallback = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let pcm = capture?.snapshot.pcm ?? Data()
        let spoke = capture?.snapshot.lastVoice != nil
        cleanup()
        // 至少录到约 0.4 秒且听到过人声，才送去 ElevenLabs。
        guard useCloud, spoke, pcm.count > ElevenLabsSTT.sampleRate * 2 * 4 / 10 else {
            if !fallback.isEmpty { onFinish?(fallback) }
            return
        }
        transcribing = true
        let key = elevenLabsKey()
        Task {
            var text = fallback
            do {
                let cloud = try await ElevenLabsSTT.transcribe(pcm16: pcm, apiKey: key)
                if !cloud.isEmpty { text = cloud }
            } catch {
                if fallback.isEmpty { self.error = "ElevenLabs 识别失败：\(error.localizedDescription)" }
            }
            self.transcribing = false
            if !text.isEmpty { self.transcript = text; self.onFinish?(text) }
        }
    }
    func cancel() { transcript = ""; cleanup() }
    private func cleanup() {
        watcher?.cancel(); watcher = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        capture = nil
        listening = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #endif
    }
}

// MARK: - 设备间接力（通过本机桥接，内存中只保留每个账号最新的一条）

@MainActor final class DeviceSync: ObservableObject {
    struct Remote: Equatable { let device: String; let track: Track; let elapsed: Double; let playing: Bool; let at: Date }
    @Published private(set) var remote: Remote?
    @Published private(set) var status = ""
    static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
    private var loop: Task<Void, Never>?
    private var lastPublished = ""
    func start(radio: RadioModel, enabled: @escaping () -> Bool) {
        loop?.cancel()
        loop = Task { [weak self, weak radio] in
            while !Task.isCancelled {
                if let self, let radio, enabled(), let account = radio.accountID { await self.tick(radio: radio, account: account) }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }
    private func tick(radio: RadioModel, account: Int64) async {
        do {
            if let track = radio.current {
                let signature = "\(track.id)-\(radio.playing)-\(Int(radio.elapsed / 30))"
                if signature != lastPublished {
                    _ = try await radio.request("sync/publish", ["account": account, "device": Self.deviceName, "playing": radio.playing, "elapsed": radio.elapsed,
                                                                  "track": ["id": track.id, "name": track.name, "artist": track.artist, "milliseconds": track.milliseconds]])
                    lastPublished = signature
                }
            }
            let latest = try await radio.request("sync/latest", ["account": account])
            guard let state = latest["state"] as? [String: Any], let device = state["device"] as? String, device != Self.deviceName,
                  let t = state["track"] as? [String: Any], let id = (t["id"] as? NSNumber)?.int64Value, id != 0 else { remote = nil; return }
            let at = Date(timeIntervalSince1970: ((state["at"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            guard Date().timeIntervalSince(at) < 15 * 60 else { remote = nil; return }
            remote = Remote(device: device, track: Track(id: id, name: t["name"] as? String ?? "", artist: t["artist"] as? String ?? "", milliseconds: (t["milliseconds"] as? NSNumber)?.doubleValue ?? 0),
                            elapsed: (state["elapsed"] as? NSNumber)?.doubleValue ?? 0, playing: state["playing"] as? Bool ?? false, at: at)
            status = "已与其他设备同步"
        } catch { status = "设备同步暂不可用（桥接服务可能是旧版本）" }
    }
}

// MARK: - 系统输出设备（AirPlay / 蓝牙 / 外接音箱）

struct AirPlayButton: View {
    var body: some View {
        RoutePicker().frame(width: 44, height: 44).accessibilityLabel("选择播放设备").help("选择播放设备（AirPlay / 蓝牙）")
    }
}
#if os(macOS)
private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView { let v = AVRoutePickerView(); v.isRoutePickerButtonBordered = false; return v }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#else
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let v = AVRoutePickerView(); v.prioritizesVideoDevices = false; return v }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
