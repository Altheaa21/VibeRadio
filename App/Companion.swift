import Foundation
import Combine

// MARK: - 歌词

struct LyricLine: Equatable, Identifiable {
    let time: Double
    let text: String
    var translation: String = ""
    var id: Double { time }
}
enum LyricParser {
    /// 解析 LRC：支持一行多个时间戳、[mm:ss]、[mm:ss.xx]、[mm:ss.xxx]；跳过作词作曲等元数据行和空行。
    static func parse(_ lrc: String, translation: String = "") -> [LyricLine] {
        let main = timed(lrc)
        let extra = Dictionary(timed(translation).map { (key(of:$0.time), $0.text) }, uniquingKeysWith: { a, _ in a })
        return main.map { LyricLine(time:$0.time, text:$0.text, translation:extra[key(of:$0.time)] ?? "") }
    }
    private static func key(of time: Double) -> Int { Int((time * 10).rounded()) }
    private static func timed(_ lrc: String) -> [(time: Double, text: String)] {
        var lines: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                let parts = tag.split(separator: ":")
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { continue }
                stamps.append(minutes * 60 + seconds)
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !stamps.isEmpty, !text.isEmpty, !isCredit(text) else { continue }
            for stamp in stamps { lines.append((stamp, text)) }
        }
        return lines.sorted { $0.0 < $1.0 }
    }
    /// 署名行：冒号前是「作词/编曲/Producer…」之类的角色名。
    private static func isCredit(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let role = text[..<colon].lowercased()
        guard role.count <= 30 else { return false }
        let keys = ["词", "曲", "编", "制作", "混", "母带", "录", "和声", "吉他", "贝斯", "鼓", "监制", "出品", "统筹", "企划", "发行", "弦乐", "键盘", "op", "sp",
                    "lyric", "compos", "arrang", "produc", "mix", "master", "record", "vocal", "guitar", "bass", "drum", "string", "piano", "engineer"]
        return keys.contains { role.contains($0) }
    }
    /// 当前时刻唱到的行；还没到第一行时为 nil。
    static func index(at time: Double, in lines: [LyricLine]) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time + 0.15 { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }
}

// MARK: - 简单指令（不经过 AI）

enum PlayerCommand: Equatable {
    case pause, resume, next, previous, stop
    case favorite(Bool)
    case play(String)
    case nowPlaying
    case lyrics
    case continuous(Bool)      // true 一直播；false 播完这组就停
    case sleep(Int)            // N 分钟后淡出停止
    case stopAfterCurrent
    case cancelSleep
}
enum PlayMode: String, CaseIterable, Identifiable {
    case continuous, set
    var id: String { rawValue }
    var label: String { self == .continuous ? "一直播" : "播完这组就停" }
}
enum CommandRouter {
    /// 只认短而明确的播放指令；模糊或带情绪的话交给 DJ（AI）。
    static func parse(_ raw: String) -> PlayerCommand? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for mark in ["。", "！", "!", ".", "？", "?", "，", ",", "《", "》", "～", "~", "吧", "呀", "啊", "一下", "请", "帮我", "麻烦"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 24 else { return nil }
        let exact: [String: PlayerCommand] = [
            "暂停": .pause, "停一下": .pause, "停": .pause, "pause": .pause, "先暂停": .pause,
            "播放": .resume, "继续": .resume, "继续播放": .resume, "play": .resume, "接着放": .resume,
            "下一首": .next, "切歌": .next, "换一首": .next, "跳过": .next, "next": .next, "下一曲": .next, "换歌": .next,
            "上一首": .previous, "上一曲": .previous, "previous": .previous, "回到上一首": .previous,
            "停止": .stop, "停止播放": .stop, "关掉音乐": .stop, "stop": .stop,
            "收藏": .favorite(true), "收藏这首": .favorite(true), "喜欢这首": .favorite(true), "我喜欢这首": .favorite(true), "加到收藏": .favorite(true),
            "取消收藏": .favorite(false), "不喜欢这首": .favorite(false),
            "这是什么歌": .nowPlaying, "现在放的是什么": .nowPlaying, "正在放什么": .nowPlaying, "这首歌叫什么": .nowPlaying, "现在在放什么": .nowPlaying,
            "歌词": .lyrics, "看歌词": .lyrics, "显示歌词": .lyrics,
            "一直播": .continuous(true), "一直放": .continuous(true), "一直放下去": .continuous(true), "一直播下去": .continuous(true), "连续播放": .continuous(true), "不要停": .continuous(true),
            "播完这组就停": .continuous(false), "放完这几首就停": .continuous(false), "播几首就好": .continuous(false), "放几首就停": .continuous(false),
            "播完这首就停": .stopAfterCurrent, "这首放完就停": .stopAfterCurrent, "放完这首就停": .stopAfterCurrent, "这首完了就停": .stopAfterCurrent,
            "取消定时": .cancelSleep, "取消睡眠定时": .cancelSleep, "不用定时了": .cancelSleep,
        ]
        if let command = exact[text] { return command }
        if let minutes = sleepMinutes(text) { return .sleep(minutes) }
        for prefix in ["播放", "放一首", "我想听", "来一首", "放"] where text.hasPrefix(prefix) {
            let name = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " 《》\"“”的"))
            // 「我想听安静一点的」这类描述交给 DJ；只有像歌名/歌手的短词才直接搜索播放。
            let vague = ["点", "些", "适合", "一点", "歌", "音乐", "安静", "开心", "难过", "放松", "的"]
            if !name.isEmpty, name.count <= 20, !vague.contains(where: { name.hasSuffix($0) || name.contains("适合") }) { return .play(name) }
        }
        return nil
    }
}

extension CommandRouter {
    /// 「30分钟后停」「睡前听半小时」「定时一小时」→ 分钟数（1–180）。
    static func sleepMinutes(_ text: String) -> Int? {
        guard ["停", "睡", "定时", "关"].contains(where: text.contains) else { return nil }
        let words: [(String, Int)] = [("一个半小时", 90), ("一小时", 60), ("一个小时", 60), ("半小时", 30), ("半个小时", 30), ("两小时", 120), ("两个小时", 120),
                                       ("四十五分钟", 45), ("三十分钟", 30), ("二十分钟", 20), ("十五分钟", 15), ("十分钟", 10), ("一刻钟", 15)]
        if let match = words.first(where: { text.contains($0.0) }) { return match.1 }
        guard text.contains("分钟") || text.contains("分"), let range = text.range(of: #"\d{1,3}"#, options: .regularExpression), let n = Int(text[range]) else { return nil }
        return (1...180).contains(n) ? n : nil
    }
}

// MARK: - 本地档案：DJ 身份、作息、心情规则、记忆、收藏、外部来源设置

struct DJProfile: Codable, Equatable {
    var name = "澜"
    var bio = "深夜电台出身，说话慢，记得你喜欢的每一首歌。只放你的音乐，偶尔带一首新的。"
    var style = "温柔、克制、像老朋友"
}
struct Routine: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: String          // "HH:mm"
    var title: String
    var music: String         // 交给选歌的描述
    var enabled = true
    var minutes: Int { let p = time.split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? min(max(p[0], 0), 23) * 60 + min(max(p[1], 0), 59) : 0 }
    static let defaults = [
        Routine(time: "08:00", title: "房间先醒", music: "温柔的华语慢歌，轻声叫醒"),
        Routine(time: "10:00", title: "深度工作", music: "少人声的器乐、氛围电子，适合专注"),
        Routine(time: "12:30", title: "午间留白", music: "轻松慵懒的爵士和律动"),
        Routine(time: "15:00", title: "下午续航", music: "有一点节奏但不吵的独立流行"),
        Routine(time: "18:30", title: "把身体叫醒", music: "节奏明快、适合运动或走路"),
        Routine(time: "21:00", title: "冥想与放松", music: "安静的钢琴、自然声和极简氛围"),
        Routine(time: "22:30", title: "夜晚缓缓降落", music: "适合夜晚的温柔歌曲"),
    ]
}
struct MoodRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var feeling: String
    var music: String
}
struct MusicMemory: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var text: String
    var trackID: Int64?
    var trackName: String?
    var artist: String?
}
struct FavoriteTrack: Codable, Identifiable, Equatable {
    var track: Track
    var added = Date()
    var id: Int64 { track.id }
}
struct CompanionSettings: Codable, Equatable {
    var city = ""
    var latitude: Double?
    var longitude: Double?
    var calendarEnabled = false
    var shareContextWithDJ = true
    var morningGreeting = true
    var hourlyCheckIn = false
    var eventReminders = true
    var autoProgram = false
    var likeSync = false
    var deviceSync = true
}
struct SchedulerMemory: Codable, Equatable {
    var greetedDay = ""
    var checkedHour = ""
    var remindedEvents: [String] = []
    var lastSlot = ""
}
struct CompanionData: Codable, Equatable {
    var profile = DJProfile()
    var routines = Routine.defaults
    var moodRules: [MoodRule] = [MoodRule(feeling: "累了", music: "安静、温暖、慢一点的歌"), MoodRule(feeling: "开心", music: "明亮轻快的歌"), MoodRule(feeling: "焦虑", music: "节奏平稳、少人声的音乐")]
    var memories: [MusicMemory] = []
    var favorites: [FavoriteTrack] = []
    var tasteSummary = ""
    var tasteSummaryDate: Date?
    var settings = CompanionSettings()
    var scheduler = SchedulerMemory()
    init() {}
    // 旧文件缺字段时用默认值，避免升级后读不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompanionData.blank
        profile = try c.decodeIfPresent(DJProfile.self, forKey: .profile) ?? d.profile
        routines = try c.decodeIfPresent([Routine].self, forKey: .routines) ?? d.routines
        moodRules = try c.decodeIfPresent([MoodRule].self, forKey: .moodRules) ?? d.moodRules
        memories = try c.decodeIfPresent([MusicMemory].self, forKey: .memories) ?? []
        favorites = try c.decodeIfPresent([FavoriteTrack].self, forKey: .favorites) ?? []
        tasteSummary = try c.decodeIfPresent(String.self, forKey: .tasteSummary) ?? ""
        tasteSummaryDate = try c.decodeIfPresent(Date.self, forKey: .tasteSummaryDate)
        settings = try c.decodeIfPresent(CompanionSettings.self, forKey: .settings) ?? d.settings
        scheduler = try c.decodeIfPresent(SchedulerMemory.self, forKey: .scheduler) ?? d.scheduler
    }
    private static var blank: CompanionData { CompanionData() }
}

@MainActor final class CompanionStore: ObservableObject {
    @Published var data: CompanionData { didSet { if data != oldValue { persist() } } }
    private let url: URL?
    init(directory: URL? = nil, preview: Bool = false) {
        if preview { url = nil; data = CompanionData(); return }
        let folder = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("VibeRadio", isDirectory: true))
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        url = folder?.appendingPathComponent("companion.json")
        if let url, let raw = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(CompanionData.self, from: raw) { data = saved } else { data = CompanionData() }
    }
    private func persist() {
        guard let url, let raw = try? JSONEncoder().encode(data) else { return }
        try? raw.write(to: url, options: .atomic)
    }
    func isFavorite(_ id: Int64?) -> Bool { id.map { id in data.favorites.contains { $0.id == id } } ?? false }
    func setFavorite(_ track: Track, _ on: Bool) {
        data.favorites.removeAll { $0.id == track.id }
        if on { data.favorites.insert(FavoriteTrack(track: track), at: 0) }
    }
    func remember(_ text: String, track: Track?) {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !clean.isEmpty else { return }
        data.memories.insert(MusicMemory(text: clean, trackID: track?.id, trackName: track?.name, artist: track?.artist), at: 0)
        data.memories = Array(data.memories.prefix(300))
    }
    /// 从旧版「仅存 ID」的本地收藏迁移；拿不到歌名的保留为占位，下次播放到时补全。
    func migrateFavoriteIDs(_ ids: String, known: [Track]) {
        let lookup = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in ids.split(separator: ",").compactMap({ Int64($0) }) where !isFavorite(id) {
            if let track = lookup[id] { data.favorites.append(FavoriteTrack(track: track)) }
        }
    }
}

// MARK: - 记忆检索（只挑相关的几条交给 DJ，绝不整库发送）

enum MemoryIndex {
    static func grams(_ text: String) -> Set<String> {
        let chars = Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        guard chars.count > 1 else { return Set(chars.map(String.init)) }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
    }
    static func relevant(_ memories: [MusicMemory], query: String, track: Track?, limit: Int = 3) -> [MusicMemory] {
        let q = grams(query + " " + (track.map { "\($0.name) \($0.artist)" } ?? ""))
        let scored = memories.map { memory -> (MusicMemory, Double) in
            var score = Double(grams(memory.text + " " + (memory.trackName ?? "") + " " + (memory.artist ?? "")).intersection(q).count)
            if let track, memory.trackID == track.id { score += 10 }
            else if let track, let artist = memory.artist, artist == track.artist { score += 3 }
            return (memory, score)
        }
        return scored.filter { $0.1 >= 2 }.sorted { $0.1 == $1.1 ? $0.0.date > $1.0.date : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

// MARK: - 口味档案（从本机曲库与收听记录统计）

struct TasteProfile: Equatable {
    var totalTracks = 0
    var playlists = 0
    var topArtists: [(name: String, count: Int)] = []
    var mostPlayed: [(name: String, artist: String, count: Int)] = []
    var oftenSkipped: [String] = []
    var playlistNames: [String] = []
    static func == (a: TasteProfile, b: TasteProfile) -> Bool { a.totalTracks == b.totalTracks && a.topArtists.map(\.name) == b.topArtists.map(\.name) }
    static func compute(_ snapshot: LibrarySnapshot, favorites: [FavoriteTrack] = []) -> TasteProfile {
        var profile = TasteProfile()
        var unique: [Int64: Track] = [:]
        for entry in snapshot.playlists where entry.enabled { for track in entry.tracks { unique[track.id] = track } }
        for favorite in favorites { unique[favorite.id] = favorite.track }
        profile.totalTracks = unique.count
        profile.playlists = snapshot.playlists.filter(\.enabled).count
        profile.playlistNames = snapshot.playlists.filter(\.enabled).map(\.playlist.name)
        var artists: [String: Int] = [:]
        for track in unique.values {
            for name in track.artist.components(separatedBy: " / ") where !name.isEmpty { artists[name, default: 0] += 1 }
        }
        for favorite in favorites { for name in favorite.track.artist.components(separatedBy: " / ") where !name.isEmpty { artists[name, default: 0] += 2 } }
        profile.topArtists = artists.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }
        let played = snapshot.listening.compactMap { key, record -> (Track, Int)? in
            guard let id = Int64(key), let track = unique[id], record.selected > 0 else { return nil }
            return (track, record.selected)
        }
        profile.mostPlayed = played.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }.prefix(8).map { ($0.0.name, $0.0.artist, $0.1) }
        var skipped: [String: Int] = [:]
        for (key, record) in snapshot.listening where record.skipped >= 2 { if let id = Int64(key), let track = unique[id] { skipped[track.artist, default: 0] += record.skipped } }
        profile.oftenSkipped = skipped.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        return profile
    }
    /// 交给 AI 总结或作上下文的精简文字，限长。
    var digest: String {
        var parts: [String] = ["曲库 \(totalTracks) 首，\(playlists) 个歌单"]
        if !playlistNames.isEmpty { parts.append("歌单：" + playlistNames.prefix(8).joined(separator: "、")) }
        if !topArtists.isEmpty { parts.append("常见歌手：" + topArtists.prefix(10).map { "\($0.name)(\($0.count))" }.joined(separator: "、")) }
        if !mostPlayed.isEmpty { parts.append("最近常听：" + mostPlayed.prefix(5).map { "\($0.name)-\($0.artist)" }.joined(separator: "、")) }
        if !oftenSkipped.isEmpty { parts.append("常跳过：" + oftenSkipped.joined(separator: "、")) }
        return String(parts.joined(separator: "；").prefix(900))
    }
}

// MARK: - 天气与日程（数据结构；获取在 ContextServices）

struct WeatherSnapshot: Codable, Equatable {
    var temperature: Double
    var code: Int
    var high: Double?
    var low: Double?
    var fetched = Date()
    var summary: String { WeatherCode.describe(code) }
    var line: String {
        var text = "\(summary) \(Int(temperature.rounded()))°"
        if let high, let low { text += "（\(Int(low.rounded()))°–\(Int(high.rounded()))°）" }
        return text
    }
    var musicHint: String {
        switch code {
        case 51...67, 80...82: return "下雨天，适合安静、带一点潮湿感的歌"
        case 71...77, 85, 86: return "下雪了，适合温暖、慢的歌"
        case 95...99: return "雷雨天，适合待在室内的、包裹感强的音乐"
        case 45, 48: return "有雾，适合朦胧的氛围音乐"
        default: return temperature >= 30 ? "很热，适合清爽轻快的歌" : temperature <= 5 ? "很冷，适合温暖的歌" : ""
        }
    }
}
enum WeatherCode {
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "晴"; case 1: "大致晴朗"; case 2: "多云"; case 3: "阴"
        case 45, 48: "雾"; case 51, 53, 55: "毛毛雨"; case 56, 57: "冻毛毛雨"
        case 61: "小雨"; case 63: "中雨"; case 65: "大雨"; case 66, 67: "冻雨"
        case 71: "小雪"; case 73: "中雪"; case 75: "大雪"; case 77: "雪粒"
        case 80, 81, 82: "阵雨"; case 85, 86: "阵雪"; case 95: "雷雨"; case 96, 99: "雷雨伴冰雹"
        default: "天气未知"
        }
    }
}
struct DayEvent: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay = false
}

// MARK: - 天气（Open-Meteo，免 Key；只发送用户填写的城市名或其坐标）

enum WeatherService {
    struct Place: Equatable { let name: String; let latitude: Double; let longitude: Double }
    static func geocodeURL(_ city: String) -> URL? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        c?.queryItems = [URLQueryItem(name: "name", value: String(city.prefix(60))), URLQueryItem(name: "count", value: "1"), URLQueryItem(name: "language", value: "zh")]
        return c?.url
    }
    static func forecastURL(latitude: Double, longitude: Double) -> URL? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        c?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)), URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"), URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "1"),
        ]
        return c?.url
    }
    static func parsePlace(_ data: Data) -> Place? {
        struct R: Decodable { struct P: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String? }; let results: [P]? }
        guard let p = (try? JSONDecoder().decode(R.self, from: data))?.results?.first else { return nil }
        return Place(name: p.name, latitude: p.latitude, longitude: p.longitude)
    }
    static func parseForecast(_ data: Data) -> WeatherSnapshot? {
        struct R: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]?; let temperature_2m_min: [Double]? }
            let current: Current?; let daily: Daily?
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data), let c = r.current else { return nil }
        return WeatherSnapshot(temperature: c.temperature_2m, code: c.weather_code, high: r.daily?.temperature_2m_max?.first, low: r.daily?.temperature_2m_min?.first)
    }
    static func place(_ city: String) async throws -> Place {
        guard let url = geocodeURL(city) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let place = parsePlace(data) else { throw NSError(domain: "VibeRadio", code: 2, userInfo: [NSLocalizedDescriptionKey: "没找到这个城市，换个写法试试（例如「上海」或「Shanghai」）。"]) }
        return place
    }
    static func forecast(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        guard let url = forecastURL(latitude: latitude, longitude: longitude) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let weather = parseForecast(data) else { throw NSError(domain: "VibeRadio", code: 3, userInfo: [NSLocalizedDescriptionKey: "天气服务返回格式异常。"]) }
        return weather
    }
}

// MARK: - 今日节目单

struct ProgramSlot: Equatable, Identifiable {
    var id: String { "\(minutes)-\(title)" }
    var minutes: Int
    var title: String
    var description: String
    var query: String
    var events: [String] = []
    var time: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}
enum DayPlanner {
    static func minutes(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date); return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    /// 按作息排出今天的节目；把日程放进所在时段，天气调整选歌描述。没有作息时给一个最小的全天安排。
    static func plan(routines: [Routine], weather: WeatherSnapshot?, events: [DayEvent], calendar: Calendar = .current) -> [ProgramSlot] {
        var base = routines.filter(\.enabled).sorted { $0.minutes < $1.minutes }
        if base.isEmpty { base = Routine.defaults }
        let hint = weather?.musicHint ?? ""
        var slots = base.map { routine in
            ProgramSlot(minutes: routine.minutes, title: routine.title, description: routine.music, query: hint.isEmpty ? routine.music : "\(routine.music)；\(hint)")
        }
        for event in events where !event.allDay {
            let start = minutes(event.start, calendar: calendar)
            guard let index = slots.lastIndex(where: { $0.minutes <= start }) ?? slots.indices.first else { continue }
            slots[index].events.append("\(String(format: "%02d:%02d", start / 60, start % 60)) \(event.title)")
            // 有会议/事件的时段，选歌偏向不打扰。
            if !slots[index].query.contains("不打扰") { slots[index].query += "；中间有日程（\(event.title)），音乐要不抢注意力" }
        }
        return slots
    }
    static func current(_ slots: [ProgramSlot], at date: Date, calendar: Calendar = .current) -> Int? {
        let now = minutes(date, calendar: calendar)
        return slots.lastIndex { $0.minutes <= now } ?? (slots.isEmpty ? nil : slots.count - 1)
    }
}

// MARK: - 定时触发（早间问候、整点心情、日程提醒、节目切换）

enum ScheduleTrigger: Equatable {
    case morningGreeting
    case hourlyCheckIn(hour: Int)
    case eventSoon(id: String, title: String, minutes: Int)
    case slotStarted(ProgramSlot)
}
enum ProgramScheduler {
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date); return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    /// 纯函数：根据现在的时间、设置和已经做过的事，返回该触发的事件，以及更新后的记忆。
    static func due(now: Date, settings: CompanionSettings, memory: SchedulerMemory, slots: [ProgramSlot], events: [DayEvent], calendar: Calendar = .current) -> ([ScheduleTrigger], SchedulerMemory) {
        var memory = memory, triggers: [ScheduleTrigger] = []
        let day = dayKey(now, calendar: calendar)
        let hour = calendar.component(.hour, from: now), minute = calendar.component(.minute, from: now)
        if settings.morningGreeting, memory.greetedDay != day, (5..<12).contains(hour) {
            triggers.append(.morningGreeting); memory.greetedDay = day
        }
        let hourKey = "\(day)-\(hour)"
        if settings.hourlyCheckIn, (9...22).contains(hour), minute < 5, memory.checkedHour != hourKey, !triggers.contains(.morningGreeting) {
            triggers.append(.hourlyCheckIn(hour: hour)); memory.checkedHour = hourKey
        }
        if settings.eventReminders {
            for event in events where !event.allDay {
                let lead = event.start.timeIntervalSince(now) / 60
                let key = "\(event.id)@\(Int(event.start.timeIntervalSince1970))"
                if lead > 0, lead <= 10, !memory.remindedEvents.contains(key) {
                    triggers.append(.eventSoon(id: event.id, title: event.title, minutes: max(Int(lead.rounded()), 1)))
                    memory.remindedEvents.append(key)
                }
            }
            memory.remindedEvents = Array(memory.remindedEvents.suffix(50))
        }
        if let index = DayPlanner.current(slots, at: now, calendar: calendar), slots[index].minutes <= DayPlanner.minutes(now, calendar: calendar) {
            let key = "\(day)-\(slots[index].id)"
            if memory.lastSlot != key {
                // 第一次启动只记住当前时段，不立刻切歌；之后进入新时段才触发。
                if settings.autoProgram && !memory.lastSlot.isEmpty && memory.lastSlot.hasPrefix(day) { triggers.append(.slotStarted(slots[index])) }
                memory.lastSlot = key
            }
        }
        return (triggers, memory)
    }
}

// MARK: - 交给 DJ 的有限上下文

enum CompanionContext {
    static func timeLine(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE HH:mm"
        return f.string(from: date)
    }
    /// 拼成一段限长资料：DJ 身份、时间、天气、下一个日程、心情规则、相关记忆、口味摘要。
    static func digest(data: CompanionData, weather: WeatherSnapshot?, events: [DayEvent], memories: [MusicMemory], taste: String, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("你的名字：\(data.profile.name)；人设：\(String(data.profile.bio.prefix(120)))；说话风格：\(String(data.profile.style.prefix(40)))")
        lines.append("现在：\(timeLine(now))")
        if data.settings.shareContextWithDJ {
            if let weather { lines.append("天气（\(data.settings.city)）：\(weather.line)") }
            let upcoming = events.filter { $0.end > now && !$0.allDay }.sorted { $0.start < $1.start }.prefix(2)
            if !upcoming.isEmpty {
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                lines.append("接下来的日程：" + upcoming.map { "\(f.string(from: $0.start)) \(String($0.title.prefix(30)))" }.joined(separator: "；"))
            }
        }
        if !data.moodRules.isEmpty { lines.append("用户定下的心情规则：" + data.moodRules.prefix(8).map { "\($0.feeling)→\($0.music)" }.joined(separator: "；")) }
        if !memories.isEmpty { lines.append("相关的音乐记忆：" + memories.map { m in (m.trackName.map { "《\($0)》：" } ?? "") + String(m.text.prefix(120)) }.joined(separator: "；")) }
        if !taste.isEmpty { lines.append("口味摘要：" + String(taste.prefix(400))) }
        return String(lines.joined(separator: "\n").prefix(1800))
    }
}
