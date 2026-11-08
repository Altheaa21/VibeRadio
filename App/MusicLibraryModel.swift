import Foundation
import Combine

private actor CatalogDisk {
    private var revisions:[Int64:Int]=[:]
    private let directory:URL?
    init(directory:URL?=nil) { self.directory=directory }
    private func url(_ owner:Int64) throws -> URL {
        let folder=try directory ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("VibeRadio/Library",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return folder.appendingPathComponent("\(owner).json")
    }
    func load(_ owner:Int64) throws -> LibrarySnapshot {
        let path=try url(owner)
        guard FileManager.default.fileExists(atPath:path.path) else { return LibrarySnapshot() }
        return try JSONDecoder().decode(LibrarySnapshot.self,from:Data(contentsOf:path))
    }
    func save(_ snapshot:LibrarySnapshot,owner:Int64,revision:Int) throws {
        guard revision >= revisions[owner,default:0] else { return }
        try JSONEncoder().encode(snapshot).write(to:try url(owner),options:.atomic)
        revisions[owner]=revision
    }
}

@MainActor final class MusicLibraryModel: ObservableObject {
    @Published private(set) var snapshot=LibrarySnapshot()
    @Published private(set) var owner:Int64?
    @Published private(set) var busy=false
    @Published private(set) var status="请选择常听歌单，建立你的选歌池。"
    @Published private(set) var error=""
    private let disk:CatalogDisk
    private var saveTask:Task<Void,Never>?
    init(storageDirectory:URL?=nil) { disk=CatalogDisk(directory:storageDirectory) }
    private var revision=0
    private var generation=UUID()
    private var importTask:Task<Void,Never>?
    var count:Int { Set(snapshot.playlists.filter(\.enabled).flatMap { $0.tracks.map(\.id) }).count }
    func activate(_ account:Int64?) async {
        guard account != owner else { return }
        cancel(); owner=account; snapshot=LibrarySnapshot(); error=""
        generation=UUID();let id=generation
        await saveTask?.value
        guard generation == id,let account else { return }
        do { let loaded=try await disk.load(account);guard generation == id else {return};snapshot=loaded;status="本机选歌池已就绪" }
        catch { guard generation == id else {return};self.error="本地曲库暂时无法读取，请重新导入歌单。" }
    }
    func setEnabled(_ id:Int64,_ enabled:Bool) {
        guard let index=snapshot.playlists.firstIndex(where:{$0.id==id}) else {return}
        snapshot.playlists[index].enabled=enabled;persist()
    }
    func setUserTags(_ id:Int64,_ value:String) {
        guard let index=snapshot.playlists.firstIndex(where:{$0.id==id}) else {return}
        let tags=value.components(separatedBy:CharacterSet(charactersIn:",，、\n")).map { String($0.trimmingCharacters(in:.whitespacesAndNewlines).prefix(30)) }.filter { !$0.isEmpty }
        snapshot.playlists[index].userTags=Array(NSOrderedSet(array:tags).array as? [String] ?? []).prefix(12).map { $0 };persist()
    }
    func recordSelection(_ track:Track) {
        guard owner != nil else { return }
        var record=snapshot.listening[String(track.id)] ?? ListeningRecord();record.selected += 1;record.lastSelected=Date();snapshot.listening[String(track.id)]=record;persist()
    }
    func recordSkip(_ track:Track) {
        guard owner != nil else { return }
        var record=snapshot.listening[String(track.id)] ?? ListeningRecord();record.skipped += 1;snapshot.listening[String(track.id)]=record;persist()
    }
    func importPlaylists(_ playlists:[Playlist],radio:RadioModel) {
        guard !busy, let account=owner,account == radio.accountID else { return }
        busy=true;error="";let id=UUID();generation=id
        importTask=Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.busy=false } }
            do {
                for (position,original) in playlists.enumerated() {
                    try Task.checkCancellation()
                    guard self.owner == account,radio.accountID == account,self.generation == id else {return}
                    var metadata=original
                    do {
                        let detail=try await radio.request("playlist/detail",["id":original.id])
                        if let playlist=detail["playlist"] as? [String:Any] {
                            metadata.tags=playlist["tags"] as? [String] ?? original.tags
                            metadata.description=playlist["description"] as? String ?? original.description
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* Missing metadata never becomes inferred labels. */ }
                    var tracks:[Track]=[];var offset=0
                    while true {
                        try Task.checkCancellation()
                        guard self.owner == account,radio.accountID == account,self.generation == id else {return}
                        self.status="正在导入 \(position+1)/\(playlists.count) · \(original.name) · 已读取 \(tracks.count) 首"
                        let response=try await radio.request("tracks",["id":original.id,"offset":offset])
                        try Task.checkCancellation()
                        let page=response["songs"] as? [[String:Any]] ?? []
                        tracks += page.compactMap(Track.fromNetEase)
                        if page.count < 100 {break};offset += page.count
                    }
                    guard self.generation == id,self.owner == account else {return}
                    let existing=self.snapshot.playlists.first(where:{$0.id==original.id})
                    var seen=Set<Int64>();tracks=tracks.filter { seen.insert($0.id).inserted }
                    let entry=IndexedPlaylist(playlist:metadata,tracks:tracks,userTags:existing?.userTags ?? [],enabled:existing?.enabled ?? true)
                    self.snapshot.playlists.removeAll {$0.id==original.id};self.snapshot.playlists.append(entry);self.persist()
                }
                if self.generation == id { self.status="已整理 \(self.count) 首候选歌曲 · 标签保留各自来源" }
            } catch {
                guard self.generation == id else { return }
                self.error=error is CancellationError ? "导入已停止，已完成的歌单仍保留。" : error.localizedDescription
            }
        }
    }
    func flush() async { await saveTask?.value }
    func cancel() { generation=UUID();importTask?.cancel();busy=false }
    private func persist() {
        guard let owner else { return };revision += 1
        let value=snapshot,revision=revision
        saveTask=Task { [weak self] in
            do { try await self?.disk.save(value,owner:owner,revision:revision) }
            catch { if self?.owner == owner { self?.error="本地曲库保存失败，请检查磁盘空间后重新导入。" } }
        }
    }
}

@MainActor final class SongCurator: ObservableObject {
    @Published private(set) var busy=false
    @Published private(set) var status=""
    @Published private(set) var error=""
    @Published private(set) var lastQuery=""
    private var task:Task<Void,Never>?
    private var generation=UUID()
    func start(query:String,library:MusicLibraryModel,radio:RadioModel,configuration:AIConfiguration,context:DJContext,discover:Bool,onResult:@escaping (SongSelection)->Void) {
        guard !busy else {return}
        guard let owner=library.owner,owner == radio.accountID else {error="请先连接网易云并导入歌单。";return}
        busy=true;error="";lastQuery=query
        let id=UUID();generation=id
        let snapshot=library.snapshot
        task=Task { [weak self] in
            guard let self else {return}
            defer {if self.generation == id {self.busy=false}}
            do {
                self.status="正在本地筛选候选歌曲…"
                var candidates=CandidateSelector.shortlist(snapshot:snapshot,query:query)
                guard !candidates.isEmpty else { throw AIError.configuration("选歌池还是空的，请先导入并启用常听歌单。") }
                var searchNote=""
                if discover {
                    self.status="正在寻找少量新歌…"
                    do {
                        let response=try await radio.request("search",["keywords":CandidateSelector.searchTerms(query)])
                        try Task.checkCancellation()
                        let result=response["result"] as? [String:Any] ?? [:]
                        let songs=(result["songs"] as? [[String:Any]] ?? []).compactMap(Track.fromNetEase)
                        let known=Set(snapshot.playlists.flatMap { $0.tracks.map(\.id) })
                        var seen=Set(candidates.map(\.id))
                        candidates += songs.filter { !known.contains($0.id) && seen.insert($0.id).inserted }.prefix(8).map { MusicCandidate(track:$0,source:"网易云搜索",playlistTags:[],userTags:[],discovery:true) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { searchNote=" · 新歌搜索暂不可用，本次使用曲库" }
                }
                try Task.checkCancellation()
                guard self.generation == id,library.owner == owner,radio.accountID == owner else {return}
                self.status="让 DJ 从 \(candidates.count) 首候选里选歌\(searchNote)"
                let selection=try await AIClient().selectSongs(configuration:configuration,query:query,candidates:candidates,context:context)
                try Task.checkCancellation()
                guard self.generation == id,library.owner == owner,radio.accountID == owner else {return}
                self.status="已选出 \(selection.tracks.count) 首 · 本次仅发送 \(candidates.count) 首候选\(searchNote)"
                onResult(selection)
            } catch {
                guard self.generation == id else {return}
                self.error=(error as? AIError)?.localizedDescription ?? ((error as? URLError)?.code == .timedOut ? "选歌请求超时，请重试。" : "暂时无法完成选歌，请检查连接后重试。")
            }
        }
    }
    func cancel() { let wasBusy=busy;generation=UUID();task?.cancel();busy=false;if wasBusy {status="选歌已停止"} }
}
