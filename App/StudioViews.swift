import SwiftUI
import Combine

private enum StudioPage: String, CaseIterable, Identifiable {
    case radio = "电台", chat = "DJ 聊天", day = "今日节目", taste = "我的口味", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self { case .radio: "opticaldisc"; case .chat: "bubble.left"; case .day: "sun.horizon"; case .taste: "waveform.path"; case .settings: "slider.horizontal.3" }
    }
}
struct StudioPalette {
    let dark: Bool
    var background: Color { dark ? Color(red:0.065,green:0.065,blue:0.065) : Color(red:0.96,green:0.955,blue:0.94) }
    var ink: Color { dark ? Color(white:0.93) : Color(white:0.10) }
    var muted: Color { dark ? Color(white:0.63) : Color(white:0.40) }
    var line: Color { dark ? Color(white:0.25) : Color(white:0.79) }
    var surface: Color { dark ? Color(white:0.12) : Color(white:0.99) }
}
extension Font {
    static func editorial(_ size: CGFloat) -> Font { .custom("BodoniSvtyTwoITCTT-Book", size:size, relativeTo:.largeTitle) }
    static func signature(_ size:CGFloat) -> Font { .custom("Zapfino",size:size,relativeTo:.largeTitle) }
    static func interfaceHeading(_ size:CGFloat) -> Font { .custom("PingFangSC-Regular",size:size,relativeTo:.title2) }
}

/// 内容按文字区分字体：拉丁文字用 Bodoni，中文用苹方；保留语音逐字高亮。
enum RadioTypography {
    static func content(_ string:String,size:CGFloat = 17,relativeTo style:Font.TextStyle = .body) -> AttributedString {
        var result=AttributedString(), buffer=""
        var previous:Bool?
        func append(_ value:String,_ latin:Bool) {
            var run=AttributedString(value)
            run.font = .custom(latin ? "BodoniSvtyTwoITCTT-Book" : "PingFangSC-Regular",size:size,relativeTo:style)
            result.append(run)
        }
        for character in string {
            let latin=character.unicodeScalars.allSatisfy { $0.value < 0x02B0 }
            if let previous, previous != latin { append(buffer,previous);buffer="" }
            buffer.append(character);previous=latin
        }
        if let previous { append(buffer,previous) }
        return result
    }
    static func text(_ string:String,size:CGFloat = 17,relativeTo style:Font.TextStyle = .body) -> Text {
        Text(content(string,size:size,relativeTo:style))
    }
}
/// 按下即有轻微反馈，减少动态效果时只改变透明度。
struct StudioPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration:0.16),value:configuration.isPressed)
    }
}
struct StudioIcon: View {
    let name: String; let label: String; var action: () -> Void
    var body: some View { Button(action:action) { Image(systemName:name).font(.system(size:19,weight:.light)).frame(width:44,height:44).contentShape(Rectangle()) }.buttonStyle(StudioPressStyle()).accessibilityLabel(label).help(label) }
}
struct StudioRule: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.17)).frame(height:0.5).accessibilityHidden(true) }
}
private struct PreviewNotice: View {
    var text = "示例节目 · 尚未自动生成"
    var body: some View { Label(text,systemImage:"info.circle").font(.system(.caption2)).foregroundStyle(.secondary).padding(.vertical,6) }
}

struct StudioRootView: View {
    private let previewTheme: String?
    private let phonePreview: Bool
    init(previewPage: String? = nil, previewTheme: String? = nil, phonePreview: Bool = false) {
        #if DEBUG
        let review = ProcessInfo.processInfo.environment["VIBERADIO_UI_REVIEW"]
        self.previewTheme = previewTheme ?? (review == nil ? nil : (review == "light" ? "light" : "dark"))
        _conversationOpen = State(initialValue:review != nil && ProcessInfo.processInfo.environment["VIBERADIO_REVIEW_LYRICS"] != "1")
        #else
        self.previewTheme = previewTheme
        #endif
        self.phonePreview = phonePreview
        #if DEBUG
        let startupPage=ProcessInfo.processInfo.environment["VIBERADIO_START_PAGE"] ?? ""
        _aiSettingsOpen=State(initialValue:ProcessInfo.processInfo.environment["VIBERADIO_SHOW_AI_SETTINGS"] == "1")
        #else
        let startupPage=""
        #endif
        _page = State(initialValue: StudioPage(rawValue: previewPage ?? startupPage) ?? .radio)
        let isolatedPreview = self.previewTheme != nil
        _chat = StateObject(wrappedValue:DJChatModel(preview:isolatedPreview))
        _brain = StateObject(wrappedValue:StudioBrain(preview:isolatedPreview))
    }
    @StateObject private var radio = RadioModel()
    @StateObject private var chat: DJChatModel
    @StateObject private var library=MusicLibraryModel()
    @StateObject private var curator=SongCurator()
    @StateObject private var voice=DJVoice()
    @AppStorage("djAutoIntro") private var autoIntro=true
    @AppStorage("djBridges") private var bridges=true
    @StateObject private var bridgeDirector=BridgeDirector()
    @StateObject private var brain: StudioBrain
    @StateObject private var speech=SpeechInput()
    @State private var poolOpen=false
    @AppStorage("djSelectSongs") private var songMode=true
    @AppStorage("djDiscoverSongs") private var discoverSongs=true
    @State private var aiSettingsOpen = false
    @State private var clearChatOpen = false
    @State private var conversationOpen = false
    @AppStorage("aiShareTaste") private var shareTaste = false
    @State private var page: StudioPage = .radio
    @AppStorage("studioTheme") private var theme = "dark"
    @AppStorage("studioFavorites") private var storedFavorites = ""
    @AppStorage("djLanguage") private var djLanguage = DJLanguage.chinese.rawValue
    @AppStorage("djLength") private var djLength = DJLength.medium.rawValue
    @AppStorage("djToneSounds") private var toneSounds = true
    @AppStorage("studioTaste") private var tasteNotes = ""
    @State private var navigationOpen = false
    /// Mac：侧栏可收起，记住上次的选择。
    @AppStorage("macSidebarHidden") private var sidebarHidden = false
    @State private var queueOpen = false
    @State private var connectionOpen = false
    @State private var chatInput = ""
    @State private var notice: String?
    @State private var scene = "深度工作"
    @Environment(\.scenePhase) private var appPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemScheme
    private var palette: StudioPalette { StudioPalette(dark:systemScheme == .dark) }
    private var isPlaying: Bool { radio.current != nil && radio.playing }
    private var songName: String { radio.current?.name ?? "还没有在放的歌" }
    private var artist: String { radio.current?.artist ?? "" }
    private var favorite: Bool { brain.isFavorite(radio.current) }
    /// 没有歌时引导用户开始：没登录先去连接，登录了就去和 DJ 说想听什么。
    private var emptyHint: String { radio.nickname.isEmpty ? "先连接网易云，再告诉 DJ 你想听什么。" : "跟 DJ 说一句想听什么，或从队列里挑一首。" }
    private func startListening() { if radio.nickname.isEmpty { connectionOpen=true } else { openChat() } }
    /// iPhone 上聊天是上拉弹层（模态）；Mac 上是右侧抽屉，不挡住主窗口，所以提示和设置照常从主窗口弹出。
    private var chatModal: Bool {
        #if os(macOS)
        false
        #else
        conversationOpen
        #endif
    }
    private func openChat() {
        #if os(macOS)
        // 已经在「DJ 聊天」整页时不再开抽屉，免得同一段对话出现两份。
        if page == .chat { return }
        #endif
        conversationOpen = true
    }

    var body: some View {
        Group {
            if phonePreview {
                VStack(spacing:0) { pageBody.frame(maxWidth:.infinity,maxHeight:.infinity); tabBar }
            } else {
            #if os(macOS)
            HStack(spacing:0) {
                if !sidebarHidden { sidebar.frame(width:190).transition(.move(edge:.leading)); Divider() }
                pageBody.frame(maxWidth:.infinity,maxHeight:.infinity)
                    // 歌词、播放队列只盖住电台这一栏，不挡侧栏和聊天抽屉。
                    .overlay { radioPanel }
                    .clipped()
                // 聊天抽屉：从右侧滑出，推开主内容；电台和播放器仍在左边可用。
                if conversationOpen { Divider(); chatPanel.frame(width:400).transition(.move(edge:.trailing)) }
            }
            .frame(minWidth:900,minHeight:760)
            .animation(reduceMotion ? nil : .smooth(duration:0.32),value:conversationOpen)
            .animation(reduceMotion ? nil : .smooth(duration:0.28),value:sidebarHidden)
            .onChange(of:page) { _,new in
                if new == .chat { conversationOpen=false }
                if new != .radio { brain.lyricsOpen=false; queueOpen=false }
            }
            // 歌词、队列只属于电台页：从别处（DJ 指令、口味页）打开时先回到电台页。
            .onChange(of:brain.lyricsOpen) { _,open in if open { queueOpen=false; page = .radio } }
            .onChange(of:queueOpen) { _,open in if open { brain.lyricsOpen=false; page = .radio } }
            .animation(reduceMotion ? nil : .smooth(duration:0.28),value:brain.lyricsOpen)
            .animation(reduceMotion ? nil : .smooth(duration:0.28),value:queueOpen)
            .toolbar {
                ToolbarItem(placement:.navigation) {
                    Button { sidebarHidden.toggle() } label: { Image(systemName:"sidebar.left") }
                        .help(sidebarHidden ? "显示侧栏" : "隐藏侧栏").accessibilityLabel(sidebarHidden ? "显示侧栏" : "隐藏侧栏")
                        .keyboardShortcut("s",modifiers:[.command,.control])
                }
                ToolbarItem(placement:.primaryAction) {
                    Button { if conversationOpen { conversationOpen=false } else { openChat() } } label: { Image(systemName:"bubble.left.and.text.bubble.right") }
                        .help(conversationOpen ? "收起聊天" : "和 DJ 聊聊").accessibilityLabel(conversationOpen ? "收起聊天" : "和 DJ 聊聊")
                        .keyboardShortcut("k",modifiers:[.command])
                }
            }
            #else
            TabView(selection:$page) {
                ForEach(StudioPage.allCases) { destination in
                    destinationBody(destination)
                        .tabItem { Label(destination.rawValue,systemImage:destination.icon) }
                        .tag(destination)
                }
            }.tint(palette.ink)
            #endif
            }
        }
        .background(palette.background).foregroundStyle(palette.ink)
        .preferredColorScheme((previewTheme ?? theme) == "system" ? nil : (previewTheme ?? theme) == "dark" ? .dark : .light)
        .sheet(isPresented:Binding(get:{poolOpen && !chatModal},set:{poolOpen=$0})) { MusicPoolView(library:library,radio:radio) }
        #if os(iOS)
        .sheet(isPresented:$conversationOpen) {
            chatPanel
            .presentationDetents([.large]).presentationDragIndicator(.visible)
            .alert("已经没有下一首了",isPresented:$radio.queueExhausted) { queueEndActions } message: { Text("这组音乐已经到最后一首了。可以让 DJ 再选一组，或者选择一直播。") }
            .alert("VibeRadio",isPresented:Binding(get:{notice != nil},set:{if !$0 { notice=nil }})) { Button("知道了") { notice=nil } } message: { Text(notice ?? "") }
            .sheet(isPresented:$aiSettingsOpen) { AISettingsView(chat:chat,voice:voice) }
            .sheet(isPresented:$poolOpen) { MusicPoolView(library:library,radio:radio) }
            .confirmationDialog("清空本机聊天记录？",isPresented:$clearChatOpen,titleVisibility:.visible) {
                Button("清空记录",role:.destructive) { curator.cancel();voice.stop();chat.clear() }
            } message: { Text("这会停止当前请求，并删除此设备保存的对话。") }
        }
        #endif
        .onChange(of:appPhase) { _,phase in
            if phase == .active, !curator.busy, !voice.speaking { chat.resetForNewDayIfNeeded() }
        }
        .onChange(of:radio.accountID) { _,owner in curator.cancel();voice.stop();Task {await library.activate(owner)} }
        .onAppear {
            voice.duck = { [weak radio] on in radio?.duck(on) }
            bridgeDirector.attach(radio:radio,voice:voice,chat:chat)
            if previewTheme == nil { brain.attach(radio:radio,chat:chat,voice:voice,library:library) }
            brain.selectSongs = { text,autoPlay in songMode=true; startSelection(text,autoPlay:autoPlay) }
            brain.continueSongs = { text in continueSelection(text) }
            bridgeDirector.quiet = { [weak brain] in brain?.quiet ?? false }
            speech.onFinish = { text in chatInput=text; sendChat() }
            speech.elevenLabsKey = { [weak voice] in voice?.recognitionKey ?? "" }
        }
        .onChange(of:library.snapshot.playlists.count) {
            // 旧版只存了 ID 的本地收藏：曲库就绪后迁移成完整歌曲信息。
            guard !storedFavorites.isEmpty, !library.snapshot.playlists.isEmpty else { return }
            brain.companion.migrateFavoriteIDs(storedFavorites,known:library.snapshot.playlists.flatMap(\.tracks)); storedFavorites=""
        }
        .onChange(of:speech.error) { if !speech.error.isEmpty { notice=speech.error } }
        .onChange(of:radio.currentURL) { Task { await brain.followTrackChange() } }
        .onChange(of:radio.playing) { Task { await brain.castPlayPause(radio.playing) } }
        #if os(iOS)
        .sheet(isPresented:$brain.lyricsOpen) { LyricsSheet(radio:radio,palette:palette) }
        #endif
        .onChange(of:voice.notice) { if !voice.notice.isEmpty { notice=voice.notice } }
        .onChange(of:radio.current?.id) { if let track=radio.current {library.recordSelection(track)} }
        .sheet(isPresented:Binding(get:{aiSettingsOpen && !chatModal},set:{aiSettingsOpen=$0})) { AISettingsView(chat:chat,voice:voice) }
        .confirmationDialog("清空本机聊天记录？",isPresented:Binding(get:{clearChatOpen && !chatModal},set:{clearChatOpen=$0}),titleVisibility:.visible) { Button("清空记录",role:.destructive) { curator.cancel();voice.stop();chat.clear() } } message: { Text("这会停止当前请求，并删除此设备保存的对话。") }
        .sheet(isPresented:$navigationOpen) { sidebar.presentationDetents([.large]) }
        #if os(iOS)
        .sheet(isPresented:$queueOpen) { MusicLibrarySheet(radio:radio,brain:brain,library:library,palette:palette,connect:{ connectionOpen=true },played:{ page = .radio },openPool:openPoolAfterSheet) }
        #endif
        .sheet(isPresented:$connectionOpen) { NavigationStack { ConnectionLabView(model:radio).toolbar { ToolbarItem(placement:.cancellationAction) { Button("完成") { connectionOpen=false } } } } }
        .alert("VibeRadio",isPresented:Binding(get:{notice != nil && !chatModal},set:{if !$0 { notice=nil }})) { Button("知道了") { notice=nil } } message: { Text(notice ?? "") }
        .alert("已经没有下一首了",isPresented:Binding(get:{radio.queueExhausted && !chatModal},set:{radio.queueExhausted=$0})) { queueEndActions } message: { Text("这组音乐已经到最后一首了。可以和 DJ 聊聊，让它再选一组，或者选择一直播。") }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["VIBERADIO_UI_REVIEW"] != nil {
                radio.current=Track(id:-25,name:"Leave",artist:"CIL · 审核示例",milliseconds:184000)
                radio.duration=184;radio.elapsed=84
                brain.loadReviewWeather()
                if ProcessInfo.processInfo.environment["VIBERADIO_REVIEW_LYRICS"] == "1" {
                    radio.loadReviewLyrics((0..<40).map { LyricLine(time:Double($0)*5,text:"审核示例歌词 第 \($0+1) 句",translation:"") })
                    brain.lyricsOpen=true
                }
                for _ in 0..<8 { chat.recordLocal(user:"想听适合夜晚的歌。",reply:"今晚不急着赶路。先留一点安静给自己，让音乐陪你把今天慢慢放下。") }
                if ProcessInfo.processInfo.environment["VIBERADIO_REVIEW_SPEECH"] == "1" {
                    voice.speak([SpeechSegment(key:"review-caption",display:"今晚不急着赶路。先留一点安静给自己，让音乐陪你把今天慢慢放下。我们不必急着抵达哪里，就在这里，听一首喜欢的歌。")],id:UUID(),configuration:VoiceConfiguration())
                }
                return
            }
            #endif
            if previewTheme == nil { await radio.connect();await library.activate(radio.accountID) }
        }
    }
    @ViewBuilder private var queueEndActions: some View {
        Button("和 DJ 聊聊") { openChat() }
        Button("选择一直播") {
            brain.cancelSleep()
            Task { _ = await brain.handle(.continuous(true)) }
            if !chat.ready { aiSettingsOpen = true }
            else if library.count == 0 { poolOpen = true }
        }
        Button("继续听这首",role:.cancel) {}
    }
    private func animateChatScroll(_ action:() -> Void) {
        withAnimation(reduceMotion ? nil : .easeOut(duration:0.22),action)
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:28) {
            Text("VibeRadio").font(.signature(20)).padding(.top,10)
            Text("音乐，留给此刻。").font(.system(.caption)).foregroundStyle(palette.muted)
            VStack(spacing:5) { ForEach(StudioPage.allCases) { p in
                Button { page=p; navigationOpen=false } label: { HStack(spacing:12) { Image(systemName:p.icon).frame(width:20); Text(p.rawValue); Spacer() }.font(.system(.footnote)).padding(12).background(page == p ? palette.ink.opacity(0.08) : .clear,in:RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain)
            } }
            Spacer()
            Text("私人电台\niPhone & Mac").font(.system(.caption2)).foregroundStyle(palette.muted).lineSpacing(7)
            themePicker
        }.padding(20).background(palette.background)
    }
    private var tabBar: some View {
        HStack(spacing:0) { ForEach(StudioPage.allCases) { p in
            Button { page=p } label: { VStack(spacing:5) { Image(systemName:p.icon).font(.system(size:19,weight:page == p ? .regular : .light)); Text(p.rawValue).font(.system(.caption2)) }.foregroundStyle(page == p ? palette.ink : palette.muted).frame(maxWidth:.infinity).frame(height:54).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityAddTraits(page == p ? .isSelected : [])
        } }.padding(.horizontal,10).padding(.top,7).background(palette.background).overlay(alignment:.top) { StudioRule() }
    }
    @ViewBuilder private var pageBody: some View {
        destinationBody(page)
    }
    @ViewBuilder private func destinationBody(_ destination: StudioPage) -> some View {
        switch destination { case .radio: nowPlaying; case .chat: chatPage; case .day: dayPage; case .taste: tastePage; case .settings: settingsPage }
    }
    private var nowPlaying: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 650
            let contentWidth = min(geo.size.width,900)
            VStack(alignment:.leading,spacing:0) {
                    HStack(alignment:.top) {
                        #if os(iOS)
                        StudioIcon(name:"line.3.horizontal",label:"打开侧栏") { navigationOpen=true }
                        #endif
                        Text("VibeRadio").font(.signature(wide ? 26 : 22))
                        Spacer()
                        StudioIcon(name:"quote.bubble",label:"歌词") { brain.lyricsOpen=true }
                        StudioIcon(name:"list.bullet",label:"播放队列") { queueOpen=true }
                    }
                    // 日期天气单独占一行、用满整宽，不再被右侧图标挤成两行；左边和品牌名对齐。
                    ClockLine(weather:brain.weather.map { "\(brain.settings.city) \($0.line)" },shortWeather:brain.weather.map { "\(brain.settings.city) \($0.summary) \(Int($0.temperature.rounded()))°" },palette:palette)
                        #if os(iOS)
                        .padding(.leading,52)
                        #endif
                        .padding(.top,-6).padding(.bottom,18)
                    if radio.bridgeOnline == false { PreviewNotice(text:"音乐服务暂时断开，正在自动重连…") }
                    if let speaker=brain.upnp.active {
                        Button { Task { await brain.stopCasting() } } label: { Label("正在 \(speaker.name) 上播放 · 切回本机",systemImage:"hifispeaker").font(.caption) }.buttonStyle(.plain).foregroundStyle(palette.muted).padding(.bottom,4)
                    }
                    if let remote=brain.sync.remote, remote.track.id != radio.current?.id {
                        Button { Task { if await radio.playSearchExact(remote.track) { radio.seek(remote.elapsed) } } } label: {
                            Label("\(remote.device) 上\(remote.playing ? "正在" : "刚才")听《\(remote.track.name)》· 在这里接着听",systemImage:"arrow.triangle.2.circlepath").font(.caption)
                        }.buttonStyle(.plain).foregroundStyle(palette.muted).padding(.bottom,4)
                    }
                    recordStage(width:contentWidth - 48, height:max(80,geo.size.height - (radio.error.isEmpty ? 450 : 485) - (brain.upnp.active != nil || brain.sync.remote != nil ? 24 : 0)))
                        .frame(maxHeight:.infinity)
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Group {
                                if voice.speaking || voice.preparing {
                                    DJCaption(voice:voice,palette:palette)
                                } else {
                                    Text(radio.current == nil ? emptyHint : (currentIsFromLibrary ? "此刻正在播放你的音乐。" : "此刻在听一首新发现的歌。"))
                                }
                            }.font(.system(.body).weight(.light)).lineSpacing(6).animation(.easeOut(duration:0.25),value:voice.speaking)
                            Spacer(minLength:8)
                            if radio.current != nil { StudioIcon(name:favorite ? "heart.fill" : "heart",label:favorite ? "取消本地收藏" : "收藏到本地") { toggleFavorite() } }
                        }
                        if radio.current != nil { progressControl }
                        HStack {
                            StudioIcon(name:"backward.end.fill",label:"上一首") { voice.stop(); Task { await radio.previous() } }
                            Spacer()
                            Button { if radio.current != nil { radio.toggle() } else { startListening() } } label: { Image(systemName:isPlaying ? "pause.fill" : "play.fill").font(.system(size:25,weight:.light)).frame(width:64,height:64).overlay(Circle().stroke(palette.ink.opacity(0.75),lineWidth:1)) }.buttonStyle(StudioPressStyle()).accessibilityLabel(radio.current == nil ? "开始放歌" : (isPlaying ? "暂停" : "播放")).help(radio.current == nil ? emptyHint : "")
                            Spacer()
                            StudioIcon(name:"forward.end.fill",label:"下一首") { Task { if radio.current != nil { if radio.upcomingTrack() != nil { voice.stop(); if let current=radio.current {library.recordSkip(current)} };await radio.next() } else { queueOpen=true } } }
                        }.frame(maxWidth:360).frame(maxWidth:.infinity).padding(.vertical,8)
                        HStack(spacing:6) {
                            Image(systemName:"speaker.fill").font(.caption2).foregroundStyle(palette.muted)
                            Slider(value:Binding(get:{Double(radio.volume)},set:{radio.setVolume(Float($0))}),in:0...1).tint(palette.ink).frame(maxWidth:180).accessibilityLabel("音量")
                            Image(systemName:"speaker.wave.3.fill").font(.caption2).foregroundStyle(palette.muted)
                            Spacer()
                            if voice.speaking { StudioIcon(name:voice.paused ? "play.circle" : "pause.circle",label:voice.paused ? "继续口播" : "暂停口播") { voice.togglePause() } }
                            playModeMenu
                            AirPlayButton()
                        }.frame(maxWidth:.infinity)
                        Button { openChat() } label: { HStack { Image(systemName:"bubble.left"); Text("和 DJ 聊聊"); Spacer(); Image(systemName:"chevron.up") }.font(.system(.footnote)).padding(.horizontal,18).padding(.vertical,15).background(palette.surface.opacity(0.7),in:Capsule()).overlay(Capsule().stroke(palette.line,lineWidth:0.5)) }.buttonStyle(StudioPressStyle())
                        if !radio.error.isEmpty { Text(radio.error).font(.caption).foregroundStyle(palette.muted).textSelection(.enabled) }
                    }.padding(.top,8).padding(.bottom,12)
                }.padding(.horizontal,24).padding(.top,14).frame(maxWidth:900)
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        }
    }
    private func recordStage(width:CGFloat,height:CGFloat) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.firstTextBaseline,spacing:16) {
                RadioTypography.text(songName,size:min(58,max(32,width * 0.12)),relativeTo:.largeTitle).lineLimit(1).minimumScaleFactor(0.65).foregroundStyle(radio.current == nil ? palette.muted : palette.ink)
                Spacer(minLength:8)
                RadioTypography.text(artist,size:13,relativeTo:.footnote).tracking(2).lineLimit(1)
            }.frame(height:min(80,height * 0.30),alignment:.top)
            GeometryReader { disc in
                let diameter = max(width * 1.18,disc.size.height * 1.75)
                VinylDisc(playing:isPlaying).frame(width:diameter,height:diameter)
                    .position(x:width * 0.86,y:disc.size.height * 0.50)
                    .accessibilityHidden(true)
            }.clipped()
                .mask(LinearGradient(stops:[.init(color:.clear,location:0),.init(color:.black,location:0.20),.init(color:.black,location:0.88),.init(color:.clear,location:1)],startPoint:.top,endPoint:.bottom))
        }.frame(height:height)
    }
    private var progressControl: some View {
        VStack(spacing:4) {
            Slider(value:Binding(get:{min(radio.elapsed,max(radio.duration,1))},set:{radio.seek($0)}),in:0...max(radio.duration,1)).tint(palette.ink).accessibilityLabel("歌曲进度")
            HStack { Text(clock(radio.elapsed)); Spacer(); Text(clock(radio.duration)) }.font(.system(.caption2).monospacedDigit()).foregroundStyle(palette.muted)
        }
    }
    private func heading(_ title:String,_ subtitle:String) -> some View {
        VStack(alignment:.leading,spacing:12) { Text(title).font(.signature(22)).fixedSize(horizontal:false,vertical:true); Text(subtitle).font(.system(.footnote)).foregroundStyle(palette.muted).lineSpacing(6) }.padding(.top,22).padding(.bottom,28)
    }
    #if os(macOS)
    /// Mac：歌词 / 音乐库与队列作为电台页上的面板，从下方升起，只覆盖电台这一栏。
    @ViewBuilder private var radioPanel: some View {
        if page == .radio, brain.lyricsOpen {
            LyricsSheet(radio:radio,palette:palette,close:{ brain.lyricsOpen=false })
                .frame(maxWidth:.infinity,maxHeight:.infinity).transition(.move(edge:.bottom).combined(with:.opacity))
        } else if page == .radio, queueOpen {
            MusicLibrarySheet(radio:radio,brain:brain,library:library,palette:palette,connect:{ queueOpen=false; connectionOpen=true },played:{ page = .radio },openPool:{ poolOpen=true },close:{ queueOpen=false })
                .frame(maxWidth:.infinity,maxHeight:.infinity).transition(.move(edge:.bottom).combined(with:.opacity))
        }
    }
    #endif
    /// 聊天面板：iPhone 放进上拉弹层，Mac 放进右侧抽屉。
    private var chatPanel: some View {
        VStack(spacing:0) {
            HStack {
                Text("DJ 聊天").font(.headline); Spacer()
                #if os(macOS)
                StudioIcon(name:"chevron.right",label:"收起聊天") { conversationOpen=false }
                #else
                StudioIcon(name:"chevron.down",label:"收起聊天") { conversationOpen=false }
                #endif
            }
            .padding(.horizontal,20).padding(.top,8)
            chatPage
        }
        .background(palette.background).foregroundStyle(palette.ink)
    }
    private var chatPage: some View {
        VStack(spacing:0) {
            // 固定在滚动区外；输入法出现、翻阅旧消息时仍能控制播放和查看口播。
            // 播放器与声纹始终在聊天顶部（iPhone 弹层、Mac 抽屉和整页聊天一致）；没有歌时显示静止轮廓。
            Group {
                VStack(alignment:.leading,spacing:8) {
                    if radio.current != nil {
                        HStack(spacing:8) {
                            NowPlayingStrip(radio:radio,voice:voice,palette:palette) { conversationOpen=false; page = .radio }
                            StudioIcon(name:radio.playing ? "pause.fill" : "play.fill",label:radio.playing ? "暂停音乐" : "继续音乐") { radio.toggle() }
                            StudioIcon(name:"forward.end.fill",label:"下一首") {
                                Task {
                                    if radio.upcomingTrack() != nil { voice.stop(); if let current=radio.current { library.recordSkip(current) } }
                                    await radio.next()
                                }
                            }
                        }
                    }
                    AudioBars(radio:radio,voice:voice,palette:palette)
                    if voice.speaking || voice.preparing {
                        HStack(alignment:.top,spacing:8) {
                            DJCaption(voice:voice,palette:palette).frame(maxWidth:.infinity,alignment:.leading)
                            if voice.speaking { StudioIcon(name:voice.paused ? "play.circle" : "pause.circle",label:voice.paused ? "继续口播" : "暂停口播") { voice.togglePause() } }
                        }
                    }
                }.padding(.horizontal,20).padding(.vertical,8).frame(maxWidth:720)
                StudioRule()
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:23) {
                        HStack(alignment:.top) {
                            heading("A little conversation.","聊音乐，也聊此刻的你。")
                            Spacer(minLength:0)
                            chatMenu.padding(.top,22)
                        }
                        if !chat.ready {
                            Button("先连接一个模型，让 DJ 认识你。") { aiSettingsOpen=true }.buttonStyle(.plain).font(.caption).foregroundStyle(palette.muted)
                        }
                        if radio.bridgeOnline == false { Text("音乐服务暂时断开，正在自动重连；聊天仍可用。").font(.caption).foregroundStyle(palette.muted) }
                        if chat.messages.isEmpty {
                            Text("今晚想听什么？\n告诉我此刻的心情，或者一首一直想再听的歌。").font(.body).lineSpacing(8)
                        }
                        ForEach(chat.messages) { m in
                            VStack(alignment:m.mine ? .trailing : .leading,spacing:9) {
                                HStack { if m.mine { Spacer() }; Text((m.mine ? "你" : "DJ \(brain.data.profile.name)") + (m.date.map { " · " + $0.formatted(date:.omitted,time:.shortened) } ?? "")).font(.system(.caption2)).foregroundStyle(palette.muted).help(m.usage.map { "模型报告用量 · 输入 \($0.prompt_tokens.map(String.init) ?? "—") / 输出 \($0.completion_tokens.map(String.init) ?? "—") tokens" } ?? ""); if !m.mine {Spacer()} }
                                SpokenText(text:ToneMarks.strip(m.content),lit:voice.highlighted(m.id.uuidString),palette:palette).font(.system(.body).weight(.light)).lineSpacing(7).frame(maxWidth:.infinity,alignment:m.mine ? .trailing : .leading)
                                if let t=m.translation, !t.isEmpty, t != ToneMarks.strip(m.content) { RadioTypography.text(t,size:13,relativeTo:.footnote).foregroundStyle(palette.muted).lineSpacing(4).frame(maxWidth:.infinity,alignment:.leading).accessibilityLabel("中文翻译：\(t)") }
                                ForEach(m.actions ?? [],id:\.self) { action in Label(action,systemImage:"checkmark.circle").font(.caption2).foregroundStyle(palette.muted) }
                                if let recommendations=m.recommendations {
                                    ForEach(recommendations) { recommendation in
                                        Button { Task {
                                            await radio.playList(recommendations.map(\.track),startingAt:recommendation.id,title:"DJ 推荐队列")
                                            if radio.error.isEmpty && autoIntro { speakIntro(message:m,recommendation:recommendation) }
                                            if radio.error.isEmpty {page = .radio} else {notice=radio.error}
                                        } } label: {
                                            HStack(alignment:.top,spacing:14) {
                                                Image(systemName:"play.circle").font(.title2)
                                                VStack(alignment:.leading,spacing:6) {
                                                    RadioTypography.text(recommendation.track.name,size:19,relativeTo:.headline)
                                                    RadioTypography.text(recommendation.track.artist,size:15,relativeTo:.subheadline).foregroundStyle(palette.muted)
                                                    SpokenText(text:ToneMarks.strip(recommendation.reason),lit:voice.highlighted("card-\(m.id)-\(recommendation.id)"),palette:palette,rest:palette.muted,pointSize:16,textStyle:.callout).font(.callout).foregroundStyle(palette.muted)
                                                    if let i=recommendations.firstIndex(where:{ $0.id == recommendation.id }), let t=m.reasonTranslations?[safe:i], !t.isEmpty, t != recommendation.reason { Text(t).font(.caption).italic().foregroundStyle(palette.muted.opacity(0.85)) }
                                                    Text((recommendation.discovery ? "新发现 · " : "来自歌单 · ")+recommendation.source).font(.caption).foregroundStyle(palette.muted)
                                                };Spacer(minLength:0)
                                            }.padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                        StudioRule()
                                    }
                                }
                                if !m.mine {
                                    Button { if voice.isSpeaking(m.id) { voice.stop() } else { voice.speak([SpeechSegment(key:m.id.uuidString,display:m.content)],id:m.id) } } label: {
                                        Label(voice.isSpeaking(m.id) ? (voice.preparing ? "正在准备口播…" : "停止口播") : "口播回放",systemImage:voice.isSpeaking(m.id) ? "stop.circle" : "play.circle").font(.system(.caption2)).frame(minHeight:44)
                                    }.buttonStyle(.plain).foregroundStyle(palette.muted)
                                }
                            }.padding(.vertical,8).id(m.id)
                            StudioRule()
                        }
                        if curator.busy {
                            HStack { ProgressView().controlSize(.small); Text(curator.status).font(.caption);Spacer();Button("停止选歌") {curator.cancel()}.frame(minHeight:44) }.id("selection-status")
                        }
                        if !curator.error.isEmpty {
                            VStack(alignment:.leading,spacing:8) { Text(curator.error).font(.callout);Button("重试选歌") {startSelection(curator.lastQuery,recordRequest:false)}.frame(minHeight:44) }.foregroundStyle(palette.muted)
                        } else if !curator.status.isEmpty && !curator.busy {Text(curator.status).font(.caption).foregroundStyle(palette.muted)}
                        if chat.busy {
                            HStack { ProgressView().controlSize(.small); Text("DJ 正在想…").font(.caption); Spacer(); Button("停止") { chat.stop() }.frame(minHeight:44) }.id("reply-status")
                        }
                        if !chat.error.isEmpty {
                            VStack(alignment:.leading,spacing:8) {
                                Text(chat.error).font(.callout).textSelection(.enabled)
                                if chat.canRetry { Button("重试这条消息") { chat.retry(context:currentDJContext) }.frame(minHeight:44) }
                                if !chat.ready { Button("连接 AI 模型") { aiSettingsOpen=true }.frame(minHeight:44) }
                            }.foregroundStyle(palette.muted)
                        }
                        if chat.messages.isEmpty {
                            HStack { suggestion("想听适合夜晚的歌"); suggestion("工作时少一点人声") }
                        }
                    }.padding(.horizontal,26).padding(.bottom,24).frame(maxWidth:680).frame(maxWidth:.infinity)
                }.scrollDismissesKeyboard(.interactively)
                .onChange(of:chat.messages.count) { animateChatScroll { if let id=chat.messages.last?.id {reader.scrollTo(id,anchor:.bottom)} } }
                .onChange(of:curator.busy) { if curator.busy {animateChatScroll {reader.scrollTo("selection-status",anchor:.bottom)}} }
                .onChange(of:chat.busy) { if chat.busy { animateChatScroll {reader.scrollTo("reply-status",anchor:.bottom)} } }
                .onAppear { if let id=chat.messages.last?.id { reader.scrollTo(id,anchor:.bottom) } }
                .onChange(of:voice.speakingID) { if let id=voice.speakingID, chat.messages.contains(where:{$0.id==id}) { animateChatScroll { reader.scrollTo(id,anchor:.center) } } }
            }
            HStack(spacing:8) {
                TextField(songMode ? "想听什么样的歌…" : "说说此刻的心情…",text:$chatInput,axis:.vertical).lineLimit(1...4).textFieldStyle(.plain).font(.system(.subheadline)).onSubmit(sendChat)
                if speech.listening || speech.transcribing { Text(speech.transcribing ? "正在识别…" : (speech.transcript.isEmpty ? "在听…" : speech.transcript)).font(.caption).foregroundStyle(palette.muted).lineLimit(1) }
                StudioIcon(name:speech.listening ? "mic.fill" : "mic",label:speech.listening ? "说完了" : "语音输入") { voice.stop(); speech.toggle() }
                Button(action:sendChat) { Image(systemName:"arrow.up").font(.system(size:19)).frame(width:44,height:44).background(palette.ink,in:Circle()).foregroundStyle(palette.background) }.buttonStyle(StudioPressStyle()).disabled(curator.busy || chat.busy || chat.testing || chatInput.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityLabel("发送消息")
            }.padding(12).background(palette.surface,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(palette.line,lineWidth:0.5)).padding(20)
        }.background(palette.background)
    }
    /// 点推荐卡片开播时的开场：同一条消息里的第一张卡先念开场白，再介绍这首；其余卡片只介绍这首。
    private func speakIntro(message m:AIMessage,recommendation:RecommendedTrack) {
        var segments:[SpeechSegment]=[]
        if m.recommendations?.first?.id == recommendation.id { segments.append(SpeechSegment(key:m.id.uuidString,display:m.content)) }
        segments.append(SpeechSegment(key:"card-\(m.id)-\(recommendation.id)",lead:djSays("先来听，\(recommendation.track.artist)的《\(recommendation.track.name)》。","First up, \"\(recommendation.track.name)\" by \(recommendation.track.artist). ", ko: "먼저 \(recommendation.track.artist)의 \"\(recommendation.track.name)\" 들어볼게요. ", ja: "まずは\(recommendation.track.artist)の「\(recommendation.track.name)」から。", fr: "Pour commencer, « \(recommendation.track.name) » de \(recommendation.track.artist). "),display:recommendation.reason))
        voice.speak(segments,id:m.id)
    }
    /// 播放方式：一直播 / 播完这组 / 睡前定时。
    private var playModeMenu: some View {
        Menu {
            Picker("播放方式",selection:$brain.playMode) { ForEach(PlayMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline)
            Section("睡前") {
                ForEach([15,30,45,60],id:\.self) { m in Button("\(m) 分钟后停") { brain.setSleep(minutes:m) } }
                Button("播完这首就停") { brain.stopAfterCurrent() }
                if brain.sleepEnd != nil || radio.stopAtEnd { Button("取消定时") { brain.cancelSleep() } }
            }
        } label: {
            HStack(spacing:5) {
                Image(systemName:brain.quiet ? "moon.fill" : (brain.playMode == .continuous ? "infinity" : "moon"))
                Text(brain.playModeStatus).font(.caption2)
            }.font(.system(size:15,weight:.light)).frame(minHeight:44).contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        #endif
        .foregroundStyle(palette.ink).fixedSize().accessibilityLabel("播放方式：\(brain.playModeStatus)").help("一直播、播完这组，或睡前定时")
    }
    /// 对话方式、选歌池、发现新歌、模型与清空都收进一个菜单，主界面只留对话本身。
    private var chatMenu: some View {
        Menu {
            Picker("对话方式",selection:$songMode) { Text("让 DJ 选歌").tag(true);Text("聊聊天").tag(false) }.pickerStyle(.inline)
            Picker("DJ 说的语言",selection:$djLanguage) { ForEach(DJLanguage.allCases) { Text($0.label).tag($0.rawValue) } }
            Picker("DJ 台词长短",selection:$djLength) { ForEach(DJLength.allCases) { Text($0.label).tag($0.rawValue) } }
            if songMode {
                Toggle("少量发现新歌",isOn:$discoverSongs)
                Toggle("选歌后 DJ 开场",isOn:$autoIntro)
                Toggle("歌与歌之间串词",isOn:$bridges)
                Picker("播放方式",selection:$brain.playMode) { ForEach(PlayMode.allCases) { Text($0.label).tag($0) } }
                Button("管理选歌池 · \(library.count) 首") { poolOpen=true }
            }
            Divider()
            Button("AI 模型设置") { aiSettingsOpen=true }
            Button("清空聊天",role:.destructive) { clearChatOpen=true }
        } label: {
            Image(systemName:"ellipsis").font(.system(size:19,weight:.light)).frame(width:44,height:44).contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        #endif
        .foregroundStyle(palette.ink).accessibilityLabel("聊天选项").help("聊天选项")
    }
    private func suggestion(_ text:String) -> some View { Button {
        guard !chat.busy && !chat.testing else { return }
        guard chat.ready else { aiSettingsOpen=true; return }
        songMode=true;startSelection(text)
    } label: { Text(text).font(.system(.caption2)).padding(.vertical,10).padding(.horizontal,12).frame(minHeight:44).overlay(Capsule().stroke(palette.line,lineWidth:0.5)) }.buttonStyle(StudioPressStyle()).disabled(curator.busy || chat.busy || chat.testing) }
    private var dayPage: some View {
        DayProgramPage(brain:brain,palette:palette,play:{ slot in page = .chat; startSelection(slot.query,autoPlay:true) },adjust:{ text in page = .chat; chatInput=text })
    }
    private var tastePage: some View {
        TastePage(brain:brain,library:library,radio:radio,palette:palette,tasteNotes:$tasteNotes,shareTaste:shareTaste,openPool:{ poolOpen=true },openLibrary:{ queueOpen=true },tell:{ text in page = .chat; songMode=false; chatInput=text })
    }
    /// 从另一个弹层跳到选歌池：等上一个弹层收起再打开，避免两个弹层同时切换被系统忽略。
    private func openPoolAfterSheet() { Task { try? await Task.sleep(for:.milliseconds(450)); poolOpen=true } }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                heading("Make yourself at home.","声音、连接，以及你喜欢的明暗。")
                Text("音乐连接").font(.interfaceHeading(26))
                Button { connectionOpen=true } label: { HStack { Image(systemName:"music.note"); Text("网易云音乐"); Spacer(); Text(radio.nickname.isEmpty ? "连接账号" : "已登录").foregroundStyle(palette.muted); Image(systemName:"chevron.right") }.font(.system(.footnote)).padding(.vertical,8) }.buttonStyle(.plain)
                if !radio.nickname.isEmpty {
                    Button { poolOpen=true } label: { HStack { Image(systemName:"square.stack"); Text("选歌池"); Spacer(); Text(library.count == 0 ? "尚未导入" : "\(library.snapshot.playlists.filter(\.enabled).count) 个歌单 · \(library.count) 首").foregroundStyle(palette.muted); Image(systemName:"chevron.right") }.font(.system(.footnote)).padding(.vertical,8) }.buttonStyle(.plain)
                }
                Text("先把常听的歌单导入选歌池，DJ 只从池里和新歌里为你选。").font(.system(.caption2)).foregroundStyle(palette.muted)
                StudioRule()
                Button { aiSettingsOpen=true } label: {
                    HStack { Text("AI 模型"); Spacer(); Text(chat.ready ? chat.configuration.model : "尚未配置").foregroundStyle(palette.muted).lineLimit(1); Image(systemName:"chevron.right") }.font(.body).frame(minHeight:44)
                }.buttonStyle(.plain)
                Text("连接兼容 Chat Completions 的模型，开始真实的 DJ 文字对话。").font(.caption).foregroundStyle(palette.muted)
                Button { aiSettingsOpen=true } label: {
                    HStack { Text("DJ 声音"); Spacer(); Text(voice.configuration.ready ? voice.configuration.provider.title : "系统声音").foregroundStyle(palette.muted).lineLimit(1); Image(systemName:"chevron.right") }.font(.body).frame(minHeight:44)
                }.buttonStyle(.plain)
                HStack { Text("DJ 说的语言"); Spacer(); Picker("DJ 说的语言",selection:$djLanguage) { ForEach(DJLanguage.allCases) { Text($0.label).tag($0.rawValue) } }.labelsHidden().fixedSize() }.font(.body).frame(minHeight:44)
                Text("只改 DJ 回复、口播和串词的语言，界面不变；你用什么语言说话都可以。").font(.caption).foregroundStyle(palette.muted)
                Toggle("DJ 语气声（叹气、轻笑、低声…）",isOn:$toneSounds).font(.body).frame(minHeight:44)
                Text("DJ 偶尔在句首带一个语气声，用 ElevenLabs v4 演出来，不显示也不念；系统声音会忽略。").font(.caption).foregroundStyle(palette.muted)
                HStack { Text("DJ 台词长短"); Spacer(); Picker("DJ 台词长短",selection:$djLength) { ForEach(DJLength.allCases) { Text($0.label).tag($0.rawValue) } }.pickerStyle(.segmented).labelsHidden().frame(width:150) }.font(.body).frame(minHeight:44)
                Text("短：一两句带过；中：现在的长度；长：像深夜电台那样多聊几句。影响聊天回复、选歌开场与理由、串词。").font(.caption).foregroundStyle(palette.muted)
                Text("选歌开播时 DJ 先说开场，音乐自动压低；聊天里可回放口播。未填 ElevenLabs Key 时用系统声音。").font(.caption).foregroundStyle(palette.muted)
                Button { connectionOpen=true } label: { HStack { Text("账号"); Spacer(); Text(radio.nickname.isEmpty ? "未登录" : radio.nickname).foregroundStyle(palette.muted); Image(systemName:"chevron.right") }.font(.body).frame(minHeight:44) }.buttonStyle(.plain)
                if !radio.nickname.isEmpty { Button("退出网易云登录",role:.destructive) { voice.stop(); radio.logout() }.buttonStyle(.plain).font(.footnote) }
                Text(radio.bridgeOnline == false ? "音乐服务未连接（\(radio.endpoint)）" : "音乐服务：\(radio.endpoint)").font(.caption2).foregroundStyle(palette.muted)
                StudioRule()
                CompanionSettingsSection(brain:brain,radio:radio,palette:palette)
                StudioRule()
                Text("数据").font(.interfaceHeading(26))
                Button("清空聊天记录",role:.destructive) { clearChatOpen=true }.buttonStyle(.plain).font(.footnote)
                Button("清空 DJ 记忆（\(brain.data.memories.count) 段）",role:.destructive) { brain.companion.data.memories=[] }.buttonStyle(.plain).font(.footnote)
                Text("曲库、收藏、记忆、作息与聊天都只保存在这台设备；API Key 在系统钥匙串。").font(.caption2).foregroundStyle(palette.muted)
                StudioRule()
                Text("留一点空间，给音乐。").font(.interfaceHeading(23)).padding(.vertical,12)
                Text("VibeRadio · 作者 TipsyLand").font(.system(.footnote)).foregroundStyle(palette.ink)
                Text("VibeRadio · 原生设计原型\n聊天时仅向你配置的模型发送有限上下文；API Key 保存在系统钥匙串。").font(.system(.caption2)).foregroundStyle(palette.muted).lineSpacing(6).padding(.bottom,25)
            }.padding(.horizontal,26).frame(maxWidth:680).frame(maxWidth:.infinity)
        }
    }
    /// 黑白主题切换：不用系统分段控件，避免窗口激活时出现系统蓝色高亮。
    private var themePicker: some View {
        HStack(spacing:2) {
            ForEach([("system","跟随系统"),("light","浅色"),("dark","深色")],id:\.0) { option in
                Button { theme=option.0 } label: {
                    Text(option.1).font(.system(.caption2)).padding(.horizontal,9).frame(minHeight:28)
                        .background(theme == option.0 ? palette.ink : .clear,in:Capsule())
                        .foregroundStyle(theme == option.0 ? palette.background : palette.muted)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(theme == option.0 ? .isSelected : [])
            }
        }.padding(2).overlay(Capsule().stroke(palette.line,lineWidth:0.5)).accessibilityElement(children:.contain).accessibilityLabel("外观主题")
    }
    private var currentIsFromLibrary: Bool {
        guard let id=radio.current?.id else { return true }
        return library.snapshot.playlists.contains { $0.tracks.contains { $0.id == id } } || radio.tracks.contains { $0.id == id }
    }
    private func settingsPlaceholder(_ title:String,_ value:String,_ detail:String) -> some View {
        Button { notice=detail } label: { VStack(alignment:.leading,spacing:9) { HStack { Text(title); Spacer(); Text(value).foregroundStyle(palette.muted); Image(systemName:"chevron.right").font(.system(.caption2)) }; Text(detail).font(.system(.caption2)).foregroundStyle(palette.muted).lineSpacing(5) }.font(.system(.footnote)).padding(.vertical,6).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
    private var currentDJContext: DJContext { djContext(query:chatInput) }
    private func djContext(query:String) -> DJContext {
        var context=DJContext(taste:tasteNotes,track:radio.current.map { "\($0.name) · \($0.artist)" } ?? "",shareTaste:shareTaste)
        context.companion=brain.companionDigest(query:query,shareTaste:shareTaste)
        context.agent=true
        return context
    }
    private func sendChat() {
        let text=chatInput.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty && !curator.busy && !chat.busy && !chat.testing else { return }
        // 明确的播放指令直接执行，不必等模型。
        if let command=CommandRouter.parse(text) {
            chatInput=""
            Task { let reply=await brain.handle(command); chat.recordLocal(user:text,reply:reply) }
            return
        }
        if !chat.ready { aiSettingsOpen=true; return }
        // 「记住…」直接存进本机记忆。
        if text.hasPrefix("记住") && text.count > 3 {
            brain.companion.remember(String(text.dropFirst(2)).trimmingCharacters(in:CharacterSet(charactersIn:"：: ")),track:radio.current)
        }
        if songMode {startSelection(text)} else {chat.send(text,context:djContext(query:text))}
        if text.count <= 2000 { chatInput="" }
    }
    private func startSelection(_ text:String,recordRequest:Bool=true,autoPlay:Bool=false) {
        guard !curator.busy && !chat.busy && !chat.testing else {return}
        guard chat.ready else {aiSettingsOpen=true;return}
        guard !text.isEmpty,text.count <= 2000 else {notice="请将选歌描述控制在2,000字以内。";return}
        guard library.count > 0 else {chatInput=text;poolOpen=true;return}
        if recordRequest {chat.recordSongRequest(text)}
        UserDefaults.standard.set(String(text.prefix(300)),forKey:"lastSelectionQuery")
        var context=djContext(query:text); context.agent=false
        curator.start(query:text,library:library,radio:radio,configuration:chat.configuration,context:context,discover:discoverSongs) {selection in
            chat.recordSongSelection(selection)
            guard autoPlay, let first=selection.tracks.first, let message=chat.messages.last else { return }
            Task {
                await radio.playList(selection.tracks.map(\.track),startingAt:first.id,title:"DJ 推荐队列")
                if radio.error.isEmpty && autoIntro { speakIntro(message:message,recommendation:first) }
            }
        }
    }
    /// 「一直播」：这组快放完时按原来的描述再选一组，接到队列后面（聊天里留一条记录）。
    private func continueSelection(_ text:String) {
        guard chat.ready, library.count > 0, !curator.busy, !chat.busy else { return }
        var context=djContext(query:text); context.agent=false
        curator.start(query:text,library:library,radio:radio,configuration:chat.configuration,context:context,discover:discoverSongs) { selection in
            chat.recordSongSelection(selection)
            Task { await radio.appendToQueue(selection.tracks.map(\.track)) }
        }
    }
    private func toggleFavorite() {
        if let current=radio.current { brain.setFavorite(current,!favorite) }
    }
    private func clock(_ seconds:Double)->String { let value=seconds.isFinite ? max(Int(seconds),0) : 0; return String(format:"%d:%02d",value/60,value%60) }
}

private struct VinylDisc: View {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var angle=0.0
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0/30.0,paused:!playing || reduceMotion || phase != .active)) { context in
            Image("VinylRecord").resizable().scaledToFit().rotationEffect(.degrees(angle))
                .onChange(of:context.date) { old,new in if playing && !reduceMotion { angle=(angle + min(new.timeIntervalSince(old),0.1)*6).truncatingRemainder(dividingBy:360) } }
        }
    }
}
private struct DayScene: Identifiable {
    let time:String;let title:String;let description:String;let song:String
    var id:String {time}
    static let samples=[
        DayScene(time:"09:00",title:"房间先醒",description:"从熟悉的声音开始，不急着进入世界。",song:"华语 · 慢节奏 · 轻声问候"),
        DayScene(time:"10:00",title:"深度工作",description:"少一点人声，给思绪留出完整的空间。",song:"器乐 · 氛围电子 · 专注"),
        DayScene(time:"12:30",title:"午间留白",description:"吃顿饭，走一小段路，让节奏松下来。",song:"轻爵士 · 慵懒律动"),
        DayScene(time:"18:00",title:"把身体叫醒",description:"让鼓点接住你的步伐。",song:"电子 · 节奏 · 运动"),
        DayScene(time:"22:00",title:"夜晚缓缓降落",description:"今天到这里就好。",song:"Ambient · 钢琴 · 夜晚")]
}

/// 聊天页顶部的「正在播放」：歌名 + 随真实响度起伏的细线；拿不到音频数据时轻轻呼吸，暂停时归于平静。
private struct DJCaption: View {
    @ObservedObject var voice:DJVoice
    let palette:StudioPalette
    @Environment(\.dynamicTypeSize) private var textSize
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            Text(voice.preparing ? "正在准备口播…" : (voice.paused ? "DJ · 口播已暂停" : "DJ · 正在说"))
                .font(.caption2).foregroundStyle(palette.muted)
            if !voice.script.isEmpty {
                let line=SpeechScript.captionWindow(voice.script,spokenCount:voice.spokenCount,limit:textSize.isAccessibilitySize ? 24 : 48)
                SpokenText(text:line.sentence,lit:voice.preparing ? 0 : line.highlighted,palette:palette,pointSize:16,textStyle:.callout)
                    .lineSpacing(4).fixedSize(horizontal:false,vertical:true)
            }
        }.accessibilityElement(children:.combine)
    }
}

private struct NowPlayingStrip: View {
    @ObservedObject var radio: RadioModel
    @ObservedObject var voice: DJVoice
    let palette: StudioPalette
    var open: () -> Void
    var body: some View {
        Button(action:open) {
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:3) {
                    RadioTypography.text(radio.current?.name ?? "",size:16,relativeTo:.subheadline).lineLimit(1)
                    Text(voice.speaking ? "DJ 正在说" : (radio.current?.artist ?? "")).font(.system(.caption2)).foregroundStyle(palette.muted).lineLimit(1)
                }.frame(maxWidth:220,alignment:.leading)
            }.padding(.vertical,10).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityElement(children:.combine)
            .accessibilityLabel("正在播放：\(radio.current?.name ?? "")，\(radio.current?.artist ?? "")")
            .accessibilityHint("回到电台")
    }
 }

/// 密集竖条声纹：整体高度跟随真实响度，每根条的起伏是视觉律动，并非 FFT 频率分析。
/// 暂停时不会一下变平：约 1.5 秒内缓缓落到一个静止的低轮廓，然后停止刷新。
private struct AudioBars: View {
    @ObservedObject var radio:RadioModel
    @ObservedObject var voice:DJVoice
    let palette:StudioPalette
    var height:CGFloat = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var wave=WaveState()
    @State private var settling=false
    private var active:Bool { radio.playing || (voice.speaking && !voice.paused) }
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/30.0,paused:reduceMotion || phase != .active || (!active && !settling))) { context in
            Canvas { canvas,size in
                let level=wave.advance(to:context.date,playing:active,level:[radio.meter.level,voice.level].compactMap{$0}.max(),reduceMotion:reduceMotion)
                let time=wave.clock(context.date,running:active && !reduceMotion)
                let pitch:CGFloat=3.2
                let count=max(40,Int(size.width / pitch))
                let step=size.width / CGFloat(count)
                let barWidth=max(1,step*0.58)
                var bars=Path()
                for i in 0..<count {
                    let x=Double(i)/Double(count)
                    let seed=Double((i &* 2654435761) % 997)/997.0
                    // 几团起伏的包络 + 每根条自己的抖动，形成参差的密集竖条。
                    let envelope=0.35 + 0.65*pow(abs(sin(x*7.3 - time*0.42 + 0.8)),1.6)*(0.6+0.4*abs(sin(x*2.1 + time*0.17)))
                    let jitter=0.55 + 0.45*abs(sin(seed*40 + time*(1.4 + seed*2.6)))
                    let shape=envelope*jitter
                    // 静止时保留约 45% 的轮廓（像参考图暂停时那样仍是一片竖条），播放时随响度升到满幅。
                    let amplitude=0.45 + 0.55*min(1,level*1.6)
                    let h=max(2,CGFloat(shape*amplitude)*size.height)
                    bars.addRoundedRect(in:CGRect(x:CGFloat(i)*step,y:size.height-h,width:barWidth,height:h),cornerSize:CGSize(width:0.6,height:0.6))
                }
                canvas.fill(bars,with:.linearGradient(Gradient(colors:[palette.ink.opacity(0.28),palette.ink.opacity(0.88)]),startPoint:.zero,endPoint:CGPoint(x:0,y:size.height)))
            }
        }
        .frame(height:height).accessibilityHidden(true)
        .onChange(of:active) { _,now in
            guard !now else { settling=false; return }
            settling=true
            Task { try? await Task.sleep(for:.seconds(1.6)); if !active { settling=false } }
        }
    }
}
/// 逐帧平滑响度：起势快、回落慢，避免抖动；暂停后约 1.5 秒缓缓落下。动画时钟在暂停时也放慢后停住，不会突然冻结。
private final class WaveState {
    private var value = 0.0
    private var last: Date?
    private var elapsed = 0.0
    private var speed = 0.0
    private var step = 0.0
    func advance(to date:Date,playing:Bool,level:Float?,reduceMotion:Bool) -> Double {
        let dt = min(date.timeIntervalSince(last ?? date),0.1); last = date; step = dt
        let target: Double
        if !playing { target = 0 }
        else if reduceMotion { target = 0.25 }
        else if let level { target = Double(level) }
        else { target = 0.32 + 0.12 * sin(date.timeIntervalSinceReferenceDate * 1.3) } // 拿不到音频时的呼吸
        let rate = target > value ? 18.0 : 2.4
        value += (target - value) * min(dt * rate,1)
        return value
    }
    /// 播放时以正常速度走；暂停后速度逐渐降到 0，条形起伏慢慢停下而不是瞬间定格。
    func clock(_ date:Date,running:Bool) -> Double {
        speed += ((running ? 1 : 0) - speed) * min(step * 2.2,1)
        elapsed += step * speed
        return elapsed
    }
}

/// 随口播逐字点亮：已念的字用正文色，未念的更淡。
private struct SpokenText: View {
    let text: String
    let lit: Int?
    let palette: StudioPalette
    var rest: Color? = nil
    var pointSize:CGFloat = 17
    var textStyle:Font.TextStyle = .body
    var body: some View {
        if let lit {
            var attributed = RadioTypography.content(text,size:pointSize,relativeTo:textStyle)
            let split = attributed.index(attributed.startIndex,offsetByCharacters:min(lit,text.count))
            attributed[attributed.startIndex..<split].foregroundColor = palette.ink
            attributed[split..<attributed.endIndex].foregroundColor = rest ?? palette.muted
            return Text(attributed)
        }
        return RadioTypography.text(text,size:pointSize,relativeTo:textStyle)
    }
}

/// 串词调度：剩约 30 秒时写好串词并提前合成；自然切到下一首时在新歌前奏上开口（音乐自动压低）。
/// 推荐队列里每首之间都说；普通歌单每 3 首说一次。手动下一首不触发。
@MainActor final class BridgeDirector: ObservableObject {
    private weak var radio: RadioModel?
    private weak var voice: DJVoice?
    private weak var chat: DJChatModel?
    private var pending: [Int64:Task<String,Never>] = [:]
    private var playlistTransitions = 0
    /// 睡前定时或「播完这首就停」时安静，不串词。
    var quiet: () -> Bool = { false }
    private var enabled: Bool { (UserDefaults.standard.object(forKey:"djBridges") as? Bool ?? true) && !quiet() }
    func attach(radio:RadioModel,voice:DJVoice,chat:DJChatModel) {
        self.radio=radio; self.voice=voice; self.chat=chat
        radio.onApproachingEnd = { [weak self] from,to in self?.prepare(from:from,to:to) }
        radio.onNaturalTransition = { [weak self] from,to in self?.transition(from:from,to:to) }
    }
    private func inQueue(_ track:Track) -> Bool { radio?.recommendationQueue.contains { $0.id == track.id } ?? false }
    private func shouldSpeak(_ to:Track,counting:Bool) -> Bool {
        guard enabled else { return false }
        if inQueue(to) { return true }
        let count = playlistTransitions + (counting ? 0 : 1)
        return count % 3 == 0
    }
    /// 最近一次推荐里这首歌的理由，以及用户当时想听什么。
    private func reason(_ id:Int64) -> String? {
        chat?.messages.reversed().lazy.compactMap { $0.recommendations?.first { $0.id == id }?.reason }.first
    }
    private var lastRequest: String? { chat?.messages.last { $0.mine }?.content }
    private func prepare(from:Track,to:Track) {
        guard shouldSpeak(to,counting:false), pending[to.id] == nil, let chat, let voice else { return }
        let configuration = chat.configuration, ready = chat.ready
        let context = BridgeWriter.context(from:from,to:to,fromReason:reason(from.id),toReason:reason(to.id),request:lastRequest)
        let fallback = BridgeWriter.template(from:from,to:to,reason:reason(to.id))
        pending[to.id] = Task { [weak voice] in
            var text = fallback
            if ready, let reply = try? await AIClient().reply(configuration:configuration,history:[AIMessage(role:"user",content:"请说这段串词。")],context:context),
               let cleaned = BridgeWriter.clean(reply,to:to) { text = cleaned }
            await voice?.prefetch([SpeechSegment(key:"bridge-\(to.id)",display:text)])
            return text
        }
        _ = voice
    }
    private func transition(from:Track,to:Track) {
        if !inQueue(to) { playlistTransitions += 1 }
        guard shouldSpeak(to,counting:true), let voice, !voice.speaking else { pending[to.id]?.cancel(); pending[to.id]=nil; return }
        let task = pending.removeValue(forKey:to.id)
        let fallback = BridgeWriter.template(from:from,to:to,reason:reason(to.id))
        Task { [weak self, weak voice] in
            let text = await task?.value ?? fallback
            // 等待期间若已切走或 DJ 正在说别的，就不说了。
            guard let voice, self?.radio?.current?.id == to.id, !voice.speaking else { return }
            voice.speak([SpeechSegment(key:"bridge-\(to.id)",display:text)],id:UUID())
        }
    }
}

extension Array { subscript(safe index:Int) -> Element? { indices.contains(index) ? self[index] : nil } }
