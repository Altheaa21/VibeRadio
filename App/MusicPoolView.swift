import SwiftUI

struct MusicPoolView: View {
    @ObservedObject var library:MusicLibraryModel
    @ObservedObject var radio:RadioModel
    @State private var selected=Set<Int64>()
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text("先选几个常听的歌单。歌曲在本机整理，每次只将少量候选交给 DJ，不修改网易云歌单。")
                    Text("已启用 \(library.count) 首 · \(library.snapshot.playlists.filter(\.enabled).count) 个歌单").foregroundStyle(.secondary)
                }
                if radio.nickname.isEmpty {
                    Section { Text("请先在设置中连接网易云音乐。").foregroundStyle(.secondary) }
                } else {
                    Section("从网易云导入") {
                        // 导入按钮放在歌单列表之前，不必滚过几十个歌单才找到。
                        HStack {
                            Button(library.busy ? "正在导入…" : "导入 / 更新所选 \(selected.count) 个歌单") {
                                library.importPlaylists(radio.playlists.filter {selected.contains($0.id)},radio:radio)
                            }.disabled(library.busy || selected.isEmpty)
                            if library.busy { ProgressView().controlSize(.small); Button("停止导入") { library.cancel() } }
                        }
                        if !library.status.isEmpty { Text(library.status).font(.caption).foregroundStyle(.secondary) }
                        if !library.error.isEmpty { Text(library.error).font(.callout).foregroundStyle(.secondary) }
                        ForEach(radio.playlists) { playlist in
                            Toggle(isOn:Binding(get:{selected.contains(playlist.id)},set:{on in if on {selected.insert(playlist.id)} else {selected.remove(playlist.id)}})) {
                                HStack { RadioTypography.text(playlist.name,size:17); Spacer(); Text("\(playlist.count) 首").foregroundStyle(.secondary) }
                            }.disabled(library.busy)
                        }
                    }
                }
                ForEach(library.snapshot.playlists) { entry in
                    Section(entry.playlist.name) { MusicPoolEntry(entry:entry,library:library) }
                }
                Section {
                    Text("原有标签来自网易云接口。你的场景标签仅由你填写，不由歌名推测。标签属于整个歌单，不保证每首歌都有相同风格。空标签会保留为空。")
                }.font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).navigationTitle("我的选歌池")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { if selected.isEmpty { selected=Set(library.snapshot.playlists.map(\.id));if selected.isEmpty,let first=radio.playlists.first {selected.insert(first.id)} } }
                #if os(macOS)
                .frame(minWidth:620,minHeight:680)
                #endif
        }.tint(.primary)
    }
}
private struct MusicPoolEntry:View {
    let entry:IndexedPlaylist
    @ObservedObject var library:MusicLibraryModel
    @State private var tags:String
    init(entry:IndexedPlaylist,library:MusicLibraryModel) {self.entry=entry;self.library=library;_tags=State(initialValue:entry.userTags.joined(separator:"，"))}
    var body:some View {
        Toggle("用于 DJ 选歌",isOn:Binding(get:{entry.enabled},set:{library.setEnabled(entry.id,$0)}))
        Text("已索引 \(entry.tracks.count) 首").foregroundStyle(.secondary)
        LabeledContent("网易云原有标签",value:entry.playlist.tags.isEmpty ? "未提供" : entry.playlist.tags.joined(separator:" · "))
        if !entry.playlist.description.isEmpty { RadioTypography.text(entry.playlist.description,size:12,relativeTo:.caption).foregroundStyle(.secondary).lineLimit(3) }
        TextField("我的场景标签，用逗号分隔",text:$tags).accessibilityLabel("我的场景标签").onSubmit {library.setUserTags(entry.id,tags)}
        Button("保存我的场景标签") {library.setUserTags(entry.id,tags)}
        if !entry.userTags.isEmpty { Text("已保存："+entry.userTags.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
    }
}
