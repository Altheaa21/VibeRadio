import SwiftUI

// MARK: - 歌词

struct LyricsPanel: View {
    @ObservedObject var radio: RadioModel
    let palette: StudioPalette
    var compact = false
    var body: some View {
        let index = LyricParser.index(at: radio.elapsed, in: radio.lyrics)
        Group {
            if radio.lyrics.isEmpty {
                Text(radio.current == nil ? "还没有在放的歌。" : (radio.lyricsStatus.isEmpty ? "暂无歌词" : radio.lyricsStatus))
                    .font(.system(.callout).weight(.light)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { box in
                    ScrollViewReader { reader in
                        ScrollView {
                            // 歌词通常不到一百行，用普通 VStack，保证一打开就能精确定位到当前句（LazyVStack 未布局的行定位不准）。
                            VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                                ForEach(Array(radio.lyrics.enumerated()), id: \.offset) { offset, line in
                                    Button { radio.seek(line.time) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            RadioTypography.text(line.text,size:offset == index ? 20 : 17,relativeTo:offset == index ? .title3 : .body)
                                            if !line.translation.isEmpty { Text(line.translation).font(.caption).foregroundStyle(palette.muted) }
                                        }
                                        .foregroundStyle(offset == index ? palette.ink : palette.muted.opacity(0.75))
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain).id(offset).accessibilityLabel(line.text).accessibilityHint("跳到这一句")
                                }
                            }
                            // 上下各留半屏，第一句和最后一句也能停在正中。
                            .padding(.vertical, compact ? 30 : max(box.size.height / 2 - 24, 40)).padding(.horizontal, 4)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: index) { _, new in if let new { withAnimation(.easeInOut(duration: 0.45)) { reader.scrollTo(new, anchor: .center) } } }
                        .onAppear { centerCurrent(reader) }
                        // 弹层还在升起时第一次定位可能被系统布局覆盖，下一帧再定一次。
                        .task { await Task.yield(); try? await Task.sleep(for: .milliseconds(60)); centerCurrent(reader) }
                    }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
        }
    }
    /// 打开歌词时不带动画地把正在唱的那句放到正中；前奏还没到第一句时停在开头。
    private func centerCurrent(_ reader: ScrollViewProxy) {
        let index = LyricParser.index(at: radio.elapsed, in: radio.lyrics) ?? 0
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { reader.scrollTo(index, anchor: .center) }
    }
}
struct LyricsSheet: View {
    @ObservedObject var radio: RadioModel
    let palette: StudioPalette
    /// 给了 close 就是嵌在电台页里的面板（Mac），不再是弹窗。
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let close {
            VStack(alignment: .leading, spacing: 8) {
                EmbeddedPanelHeader(title: "歌词", palette: palette, close: close)
                content
            }.padding(24).background(palette.background)
        } else {
            NavigationStack {
                content.padding(24).background(palette.background)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            RadioTypography.text(radio.current?.name ?? "歌词",size:30,relativeTo:.title)
            RadioTypography.text(radio.current?.artist ?? "",size:13,relativeTo:.footnote).foregroundStyle(palette.muted)
            LyricsPanel(radio: radio, palette: palette)
        }
    }
}
/// 嵌入式面板的顶栏：标题 + 收起按钮（Mac 上歌词、队列只盖住电台页时用）。
struct EmbeddedPanelHeader: View {
    let title: String
    let palette: StudioPalette
    let close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(palette.muted)
            Spacer()
            Button("完成", action: close).keyboardShortcut(.cancelAction)
        }.padding(.bottom, 6)
    }
}

// MARK: - 音乐库与队列：搜索、接下来、收藏、歌单

struct MusicLibrarySheet: View {
    @ObservedObject var radio: RadioModel
    @ObservedObject var brain: StudioBrain
    @ObservedObject var library: MusicLibraryModel
    let palette: StudioPalette
    var connect: () -> Void
    var played: () -> Void
    var openPool: () -> Void
    /// 给了 close 就是嵌在电台页里的面板（Mac），不再是弹窗。
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private func closeSheet() { if let close { close() } else { dismiss() } }
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var searchError = ""
    @State private var queueExpanded = true
    @State private var favoritesExpanded = false
    var body: some View {
        if let close {
            VStack(alignment: .leading, spacing: 0) {
                EmbeddedPanelHeader(title: "音乐库与队列", palette: palette, close: close).padding(.horizontal, 24).padding(.top, 20)
                libraryBody
            }.background(palette.background)
        } else {
            NavigationStack {
                libraryBody.navigationTitle("音乐库与队列")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                    #if os(macOS)
                    .frame(minWidth: 620, minHeight: 650)
                    #endif
            }
        }
    }
    private var libraryBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if radio.nickname.isEmpty {
                        Text("把你的音乐带进来。").font(.interfaceHeading(31)).padding(.top, 20)
                        Text("连接网易云后，这里会显示真实歌单与歌曲。").font(.footnote).foregroundStyle(.secondary)
                        Button("连接网易云音乐") { closeSheet(); connect() }.buttonStyle(.borderedProminent)
                    } else {
                        searchSection
                        if let current = radio.current {
                            section("接下来 · \(radio.queueTitle)", expanded: $queueExpanded, count: radio.upNext.count + 1) {
                                row(current, playing: true) { }
                                ForEach(radio.upNext) { t in row(t, playing: false) { play(t, in: queueContext(), title: radio.queueTitle) } }
                            }
                        }
                        section("本地收藏", expanded: $favoritesExpanded, count: brain.data.favorites.count) {
                            if brain.data.favorites.isEmpty { Text("在电台页点心形，或对 DJ 说「收藏这首」。").font(.caption).foregroundStyle(palette.muted) }
                            ForEach(brain.data.favorites) { f in row(f.track, playing: radio.current?.id == f.id) { Task { await brain.playFavorites(startingAt: f.id); done() } } }
                        }
                        // 只列已导入选歌池、且在池里启用的歌单；没导入的不在这里出现，要先去选歌池导入。
                        Text("选歌池里的歌单").font(.interfaceHeading(28))
                        if poolPlaylists.isEmpty {
                            Text("还没有导入歌单。先把常听的歌单导入选歌池，DJ 才能从里面选歌。").font(.caption).foregroundStyle(palette.muted)
                            Button("去导入歌单") { closeSheet(); openPool() }.buttonStyle(.bordered)
                        } else {
                            Text("想自己挑一首时用；平时跟 DJ 说想听什么就好。").font(.caption).foregroundStyle(palette.muted)
                            Button("管理选歌池") { closeSheet(); openPool() }.buttonStyle(.plain).font(.caption).foregroundStyle(palette.ink)
                        }
                        ForEach(poolPlaylists) { p in
                            Button { Task { await radio.loadTracks(p) } } label: { HStack { RadioTypography.text(p.name,size:17); Spacer(); Text("\(p.count)").foregroundStyle(.secondary) }.padding(.vertical, 8).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(radio.busy)
                        }
                        if radio.busy { ProgressView("正在读取歌曲…") }
                        if !radio.tracks.isEmpty { StudioRule(); Text("选择播放").font(.interfaceHeading(24)) }
                        LazyVStack { ForEach(radio.tracks) { t in row(t, playing: radio.current?.id == t.id) { Task { await radio.play(t); if radio.error.isEmpty { done() } } } } }
                        if !radio.error.isEmpty { Text(radio.error).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(24)
            }.background(palette.background)
    }
    private var poolPlaylists: [Playlist] { library.snapshot.playlists.filter(\.enabled).map(\.playlist) }
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                TextField("搜索网易云：歌名、歌手", text: $query).textFieldStyle(.plain).onSubmit(search)
                if searching { ProgressView().controlSize(.small) }
                if !results.isEmpty { Button("清除") { results = []; query = "" }.buttonStyle(.plain).font(.caption) }
            }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 0.5))
            if !searchError.isEmpty { Text(searchError).font(.caption).foregroundStyle(palette.muted) }
            ForEach(results) { t in row(t, playing: radio.current?.id == t.id) { play(t, in: results, title: "搜索：\(query.prefix(12))") } }
        }
    }
    private func search() {
        let q = query; guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true; searchError = ""
        Task { do { results = try await radio.search(q); if results.isEmpty { searchError = "没有结果" } } catch { searchError = error.localizedDescription }; searching = false }
    }
    private func queueContext() -> [Track] { radio.recommendationQueue.isEmpty ? radio.tracks : radio.recommendationQueue }
    private func play(_ t: Track, in list: [Track], title: String) {
        Task { if radio.recommendationQueue.isEmpty && list == radio.tracks { await radio.play(t) } else { await radio.playList(list, startingAt: t.id, title: title) }; if radio.error.isEmpty { done() } }
    }
    private func done() { played(); closeSheet() }
    private func row(_ t: Track, playing: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack { VStack(alignment: .leading, spacing: 4) { RadioTypography.text(t.name,size:17).lineLimit(1); RadioTypography.text(t.artist,size:12,relativeTo:.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Image(systemName: playing ? "speaker.wave.2" : "play") }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(playing ? .isSelected : [])
            StudioRule()
        }
    }
    @ViewBuilder private func section<Content: View>(_ title: String, expanded: Binding<Bool>, count: Int, @ViewBuilder content: () -> Content) -> some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { expanded.wrappedValue.toggle() } } label: {
            HStack { RadioTypography.text(title,size:24,relativeTo:.title2); Spacer(); Text("\(count)").foregroundStyle(palette.muted); Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down").font(.caption) }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint(expanded.wrappedValue ? "收起" : "展开")
        if expanded.wrappedValue { content() }
    }
}

// MARK: - 今日节目

struct DayProgramPage: View {
    @ObservedObject var brain: StudioBrain
    let palette: StudioPalette
    var play: (ProgramSlot) -> Void
    var adjust: (String) -> Void
    @State private var editing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeading("The shape of a day.", "让音乐顺着生活的节奏，慢慢发生。", palette: palette)
                HStack(spacing: 14) {
                    Label(brain.weather.map { "\(brain.settings.city) \($0.line)" } ?? "未设置城市", systemImage: "cloud.sun")
                    Label(brain.settings.calendarEnabled ? "\(brain.events.count) 个日程" : "日历未连接", systemImage: "calendar")
                    Spacer()
                    Button("编辑作息") { editing = true }.buttonStyle(.plain).font(.caption)
                }.font(.system(.caption)).foregroundStyle(palette.muted).padding(.bottom, 8)
                let slots = brain.program, current = brain.currentSlotIndex
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, s in
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) { Text(s.time).font(.system(.caption2).monospacedDigit()); Rectangle().fill(palette.line).frame(width: 1, height: 62) }.frame(width: 42)
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { RadioTypography.text(s.title,size:25,relativeTo:.title2); Spacer(); if index == current { Text("此刻").font(.system(.caption2)).padding(.horizontal, 8).padding(.vertical, 3).overlay(Capsule().stroke(palette.ink, lineWidth: 0.5)) } }
                            RadioTypography.text(s.description,size:12,relativeTo:.caption).foregroundStyle(palette.muted).lineSpacing(5)
                            ForEach(s.events, id: \.self) { e in Label(e, systemImage: "calendar").font(.caption2).foregroundStyle(palette.muted) }
                            Button { play(s) } label: { Label("播放这段", systemImage: "play.circle").font(.caption) }.buttonStyle(.plain).frame(minHeight: 44)
                        }
                    }.padding(.vertical, 15).accessibilityElement(children: .contain).accessibilityAddTraits(index == current ? .isSelected : [])
                    StudioRule()
                }
                Toggle("按时段自动换歌", isOn: Binding(get: { brain.settings.autoProgram }, set: { brain.companion.data.settings.autoProgram = $0 })).padding(.top, 18).font(.footnote).tint(palette.ink)
                Text("开启后，进入新时段时 DJ 会说一句并从你的曲库选一组歌开播（App 打开期间）。").font(.caption2).foregroundStyle(palette.muted)
                Button { adjust("想调整今天的节目，") } label: { HStack { Text("和 DJ 调整节目"); Spacer(); Image(systemName: "arrow.up.right") }.font(.footnote).padding(.vertical, 23) }.buttonStyle(.plain)
            }.padding(.horizontal, 26).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.sheet(isPresented: $editing) { RoutineEditor(store: brain.companion, palette: palette) }
    }
}
struct RoutineEditor: View {
    @ObservedObject var store: CompanionStore
    let palette: StudioPalette
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("作息与场景（按时间排序）") {
                    ForEach($store.data.routines) { $r in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { TextField("08:00", text: $r.time).frame(width: 64).font(.body.monospacedDigit()); TextField("场景名", text: $r.title); Toggle("", isOn: $r.enabled).labelsHidden() }
                            TextField("想听什么样的音乐", text: $r.music, axis: .vertical).font(.caption)
                        }
                    }.onDelete { store.data.routines.remove(atOffsets: $0) }
                    Button("添加时段") { store.data.routines.append(Routine(time: "20:00", title: "新的时段", music: "描述想听的感觉")) }
                    Button("恢复默认作息") { store.data.routines = Routine.defaults }
                }
                Section("心情规则") {
                    ForEach($store.data.moodRules) { $m in HStack { TextField("心情", text: $m.feeling).frame(width: 90); Text("→").foregroundStyle(.secondary); TextField("想听的音乐", text: $m.music) } }
                        .onDelete { store.data.moodRules.remove(atOffsets: $0) }
                    Button("添加心情规则") { store.data.moodRules.append(MoodRule(feeling: "新的心情", music: "想听的音乐")) }
                    Text("聊天和选歌时，DJ 会参考这些规则。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).navigationTitle("作息与心情")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { store.data.routines.sort { $0.minutes < $1.minutes }; dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }
}

// MARK: - 我的口味：DJ 身份、口味档案、收藏、记忆

struct TastePage: View {
    @ObservedObject var brain: StudioBrain
    @ObservedObject var library: MusicLibraryModel
    @ObservedObject var radio: RadioModel
    let palette: StudioPalette
    @Binding var tasteNotes: String
    let shareTaste: Bool
    var openPool: () -> Void
    var openLibrary: () -> Void
    var tell: (String) -> Void
    @State private var profileOpen = false
    @State private var message = ""
    var body: some View {
        let profile = TasteProfile.compute(library.snapshot, favorites: brain.data.favorites)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading("Mostly, your music.", "慢慢认识你，也记住那些与音乐有关的时刻。", palette: palette)
                Button { profileOpen = true } label: {
                    HStack(alignment: .center, spacing: 18) {
                        ZStack { Circle().fill(palette.ink).frame(width: 58, height: 58); RadioTypography.text(String(brain.data.profile.name.prefix(1)),size:28,relativeTo:.title).foregroundStyle(palette.background) }
                        VStack(alignment: .leading, spacing: 6) { RadioTypography.text("DJ \(brain.data.profile.name)",size:25,relativeTo:.title2); RadioTypography.text(brain.data.profile.bio,size:12,relativeTo:.caption).foregroundStyle(palette.muted).lineLimit(2) }
                        Spacer(); Image(systemName: "pencil").foregroundStyle(palette.muted)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("编辑 DJ 的名字与简介")
                StudioRule()
                Text("口味档案").font(.interfaceHeading(26))
                HStack(spacing: 22) { stat("\(profile.totalTracks)", "首歌"); stat("\(profile.playlists)", "个歌单"); stat("\(brain.data.favorites.count)", "首收藏"); stat("\(brain.data.memories.count)", "段记忆") }
                if !profile.topArtists.isEmpty {
                    Text("常听的歌手").font(.caption).foregroundStyle(palette.muted)
                    FlowTags(tags: profile.topArtists.prefix(12).map(\.name), palette: palette)
                }
                if !profile.mostPlayed.isEmpty {
                    Text("最近常听").font(.caption).foregroundStyle(palette.muted)
                    ForEach(Array(profile.mostPlayed.prefix(5).enumerated()), id: \.offset) { _, p in Text("《\(p.name)》· \(p.artist) · \(p.count) 次").font(.footnote.weight(.light)) }
                }
                if !profile.playlistNames.isEmpty { Text("歌单：" + profile.playlistNames.prefix(8).joined(separator: "、")).font(.caption).foregroundStyle(palette.muted) }
                VStack(alignment: .leading, spacing: 8) {
                    if brain.data.tasteSummary.isEmpty { Text("还没有 DJ 写的口味总结。").font(.footnote).foregroundStyle(palette.muted) }
                    else { RadioTypography.text(brain.data.tasteSummary,size:17).lineSpacing(6) }
                    HStack {
                        Button(brain.summarizing ? "正在整理…" : (brain.data.tasteSummary.isEmpty ? "让 DJ 总结我的口味" : "更新口味总结")) { Task { message = await brain.summarizeTaste() ?? "已更新口味总结。" } }.disabled(brain.summarizing || profile.totalTracks == 0)
                        if let date = brain.data.tasteSummaryDate { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(palette.muted) }
                    }
                    Text("只把上面的统计摘要（歌手、歌单名、次数）交给你配置的模型，不发送整份曲库。").font(.caption2).foregroundStyle(palette.muted)
                }
                StudioRule()
                VStack(alignment: .leading, spacing: 12) {
                    Text("音乐偏好").font(.subheadline)
                    Text("写下喜欢的风格、歌手，或不想听到的音乐。").font(.caption).foregroundStyle(palette.muted)
                    TextEditor(text: $tasteNotes).accessibilityLabel("音乐偏好").font(.subheadline).scrollContentBackground(.hidden).frame(minHeight: 110).padding(10).background(palette.surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 0.5))
                    Text(shareTaste ? "自动保存在本机 · 聊天时附带偏好与口味摘要" : "自动保存在本机 · 在 AI 设置里打开「附带偏好」后才交给 DJ").font(.caption2).foregroundStyle(palette.muted)
                }
                StudioRule()
                Button(action: openPool) { HStack { Text("DJ 选歌池"); Spacer(); Text("\(library.count) 首").foregroundStyle(palette.muted); Image(systemName: "arrow.up.right") }.font(.body).frame(minHeight: 44) }.buttonStyle(.plain)
                Button(action: openLibrary) { HStack { Text("收藏与歌单"); Spacer(); Text("\(brain.data.favorites.count) 首收藏").foregroundStyle(palette.muted); Image(systemName: "arrow.up.right") }.font(.body).frame(minHeight: 44) }.buttonStyle(.plain)
                if !radio.nickname.isEmpty {
                    Button("从网易云「喜欢的音乐」导入收藏") { Task { message = await brain.importNetEaseLikes() } }.buttonStyle(.plain).font(.footnote).frame(minHeight: 44)
                }
                StudioRule()
                Text("音乐记忆").font(.interfaceHeading(26))
                Text("有些歌，记着某段日子。对 DJ 说「记住…」，或者在这里写下。").font(.footnote.weight(.light)).foregroundStyle(palette.muted).lineSpacing(6)
                ForEach(brain.data.memories.prefix(30)) { m in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            RadioTypography.text(m.text,size:16,relativeTo:.callout)
                            Text(([m.trackName.map { "《\($0)》" }, m.artist].compactMap { $0 } + [m.date.formatted(date: .abbreviated, time: .omitted)]).joined(separator: " · ")).font(.caption2).foregroundStyle(palette.muted)
                        }
                        Spacer()
                        Button { brain.companion.data.memories.removeAll { $0.id == m.id } } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain).frame(width: 44, height: 44).accessibilityLabel("删除这段记忆")
                    }
                    StudioRule()
                }
                Button("告诉 DJ 一段回忆") { tell("记住：这首歌让我想起…") }.buttonStyle(.bordered).padding(.bottom, 30)
            }.padding(.horizontal, 26).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $profileOpen) { DJProfileEditor(store: brain.companion) }
        .alert("VibeRadio", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) { Button("好") { message = "" } } message: { Text(message) }
    }
    private func stat(_ value: String, _ label: String) -> some View { VStack(alignment: .leading, spacing: 2) { Text(value).font(.title2.monospacedDigit()); Text(label).font(.caption2).foregroundStyle(palette.muted) } }
}
struct FlowTags: View {
    let tags: [String]
    let palette: StudioPalette
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(tags, id: \.self) { tag($0) } }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ForEach(tags.prefix(5), id: \.self) { tag($0) } }
                HStack(spacing: 8) { ForEach(tags.dropFirst(5).prefix(5), id: \.self) { tag($0) } }
            }
        }
    }
    private func tag(_ t: String) -> some View { Text(t).font(.caption).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5).overlay(Capsule().stroke(palette.line, lineWidth: 0.5)) }
}
struct DJProfileEditor: View {
    @ObservedObject var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("DJ 身份") {
                    TextField("名字", text: $store.data.profile.name)
                    TextField("简介", text: $store.data.profile.bio, axis: .vertical).lineLimit(2...5)
                    TextField("说话风格", text: $store.data.profile.style)
                }
                Section { Text("名字、简介和风格会作为 DJ 的人设交给你配置的模型；声音在「AI 模型设置」里选。").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("DJ 主页")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { if store.data.profile.name.trimmingCharacters(in: .whitespaces).isEmpty { store.data.profile.name = "澜" }; dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
    }
}

// MARK: - 设置补充：日历与天气、定时、设备、同步

struct CompanionSettingsSection: View {
    @ObservedObject var brain: StudioBrain
    @ObservedObject var radio: RadioModel
    let palette: StudioPalette
    @State private var city = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("日历与天气").font(.interfaceHeading(26))
            HStack {
                TextField("城市（如 上海）", text: $city).textFieldStyle(.plain).onSubmit { Task { await brain.setCity(city) } }
                Button("保存") { Task { await brain.setCity(city) } }.buttonStyle(.plain)
            }.padding(10).background(palette.surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 0.5))
            Text(brain.weatherStatus + " · 天气来自 Open-Meteo，只发送城市名/坐标。").font(.caption2).foregroundStyle(palette.muted)
            Toggle("读取系统日历", isOn: Binding(get: { brain.settings.calendarEnabled }, set: { on in Task { await brain.setCalendar(on) } })).font(.footnote)
            Text(brain.settings.calendarEnabled ? brain.calendar.status : "读取「日历」App 里的今日日程（iCloud、Google、Outlook；飞书日历可在飞书设置中通过 CalDAV 添加到系统日历）。").font(.caption2).foregroundStyle(palette.muted)
            Toggle("把天气和日程告诉 DJ", isOn: binding(\.shareContextWithDJ)).font(.footnote)
            StudioRule()
            Text("陪伴").font(.interfaceHeading(26))
            Toggle("早间问候（5–12 点第一次打开时）", isOn: binding(\.morningGreeting)).font(.footnote)
            Toggle("整点问问心情（9–22 点）", isOn: binding(\.hourlyCheckIn)).font(.footnote)
            Toggle("日程开始前 10 分钟提醒", isOn: binding(\.eventReminders)).font(.footnote)
            Toggle("按时段自动换歌", isOn: binding(\.autoProgram)).font(.footnote)
            Text("定时只在 App 打开期间运行。").font(.caption2).foregroundStyle(palette.muted)
            StudioRule()
            Text("设备").font(.interfaceHeading(26))
            HStack { Text("播放设备").font(.footnote); Spacer(); AirPlayButton() }
            Text("AirPlay、蓝牙耳机或外接音箱，用系统输出切换。").font(.caption2).foregroundStyle(palette.muted)
            HStack {
                Text("DLNA / UPnP 音箱").font(.footnote); Spacer()
                if brain.upnp.searching { ProgressView().controlSize(.small) }
                Button("搜索") { Task { await brain.upnp.discover() } }.buttonStyle(.plain).font(.footnote).disabled(brain.upnp.searching)
            }
            ForEach(brain.upnp.renderers) { r in
                Button { Task { if brain.upnp.active == r { await brain.stopCasting() } else { await brain.cast(to: r) } } } label: {
                    HStack { Image(systemName: "hifispeaker"); Text(r.name); Spacer(); Text(brain.upnp.active == r ? "正在播放 · 点按切回本机" : "投放当前歌曲").foregroundStyle(palette.muted) }.font(.footnote).frame(minHeight: 36).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if !brain.upnp.status.isEmpty { Text(brain.upnp.status).font(.caption2).foregroundStyle(palette.muted) }
            Toggle("在 iPhone 与 Mac 之间接力", isOn: binding(\.deviceSync)).font(.footnote)
            Text(brain.settings.deviceSync ? (brain.sync.status.isEmpty ? "通过本机桥接同步正在播放的歌；只在内存中保存最新一条。" : brain.sync.status) : "已关闭").font(.caption2).foregroundStyle(palette.muted)
            Toggle("收藏时同步到网易云「喜欢」", isOn: binding(\.likeSync)).font(.footnote)
            Text("开启后，点心形会写入你网易云账号的「喜欢的音乐」。").font(.caption2).foregroundStyle(palette.muted)
            if !brain.lastAction.isEmpty { Text(brain.lastAction).font(.caption2).foregroundStyle(palette.muted) }
        }.tint(palette.ink).onAppear { city = brain.settings.city }
    }
    private func binding(_ key: WritableKeyPath<CompanionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { brain.settings[keyPath: key] }, set: { brain.companion.data.settings[keyPath: key] = $0 })
    }
}

// MARK: - 共用

func pageHeading(_ title: String, _ subtitle: String, palette: StudioPalette) -> some View {
    VStack(alignment: .leading, spacing: 12) { Text(title).font(.signature(22)).fixedSize(horizontal:false,vertical:true); Text(subtitle).font(.footnote).foregroundStyle(palette.muted).lineSpacing(6) }.padding(.top, 22).padding(.bottom, 28)
}
/// 电台页顶部的日期时间与天气，一分钟刷新一次。
struct ClockLine: View {
    let weather: String?
    /// 放不下一行时的简短天气（去掉最低/最高温）。
    var shortWeather: String? = nil
    let palette: StudioPalette
    var body: some View {
        TimelineView(.everyMinute) { context in
            let time = CompanionContext.timeLine(context.date)
            // 始终一行：先放完整天气，放不下改简短版，再不行只留时间。
            ViewThatFits(in: .horizontal) {
                line(time + (weather.map { " · \($0)" } ?? ""))
                line(time + ((shortWeather ?? weather).map { " · \($0)" } ?? ""))
                line(time)
            }
        }
    }
    private func line(_ text: String) -> some View {
        Text(text).font(.caption2.monospacedDigit()).foregroundStyle(palette.muted).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}
