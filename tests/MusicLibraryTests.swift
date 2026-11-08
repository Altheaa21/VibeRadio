import Foundation

@MainActor final class RadioModel {
    var accountID:Int64? = 777
    var requests:[String]=[]
    var pageSize=101
    func request(_ route:String,_ body:[String:Any]=[:]) async throws -> [String:Any] {
        requests.append(route)
        if route == "playlist/detail" { return ["playlist":["tags":["夜晚"],"description":"来源简介"]] }
        let offset=body["offset"] as? Int ?? 0
        let count=max(0,min(100,pageSize-offset))
        return ["songs":(0..<count).map { n in ["id":NSNumber(value:offset+n+1),"name":"歌曲\(offset+n+1)","ar":[["name":"歌手\(n%10)"]],"al":["name":"专辑"],"dt":NSNumber(value:180000)] as [String:Any] }]
    }
}
@main struct MusicLibraryTests {
    @MainActor static func main() async throws {
        var checks=0
        func expect(_ condition:Bool,_ message:String) {precondition(condition,message);checks += 1}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let library=MusicLibraryModel(storageDirectory:directory)
        let radio=RadioModel()
        await library.activate(radio.accountID)
        let playlist=Playlist(id:1,name:"夜晚的房间",count:101)
        library.importPlaylists([playlist],radio:radio)
        var ticks=0
        while library.busy {try await Task.sleep(nanoseconds:1_000_000);ticks += 1;precondition(ticks<3000)}
        expect(library.count == 101,"pagination indexed all tracks")
        expect(library.snapshot.playlists[0].playlist.tags == ["夜晚"],"upstream tags retained")
        expect(library.snapshot.playlists[0].tracks.first?.album == "专辑","album decoded")
        library.setUserTags(1,"工作，专注，工作")
        expect(library.snapshot.playlists[0].userTags == ["工作","专注"],"user tags separate and deduplicated")
        expect(library.snapshot.playlists[0].playlist.tags == ["夜晚"],"user edits do not mutate upstream tags")
        await library.flush()
        let restored=MusicLibraryModel(storageDirectory:directory);await restored.activate(777)
        expect(restored.count == 101,"disk roundtrip")
        await restored.activate(778)
        expect(restored.count == 0,"account isolation")
        library.setEnabled(1,false);expect(library.count == 0,"disabled pool excluded")
        library.setEnabled(1,true)
        let candidates=CandidateSelector.shortlist(snapshot:library.snapshot,query:"适合夜晚的歌",seed:1)
        expect(candidates.count == 32,"bounded shortlist")
        expect(Set(candidates.map(\.id)).count == 32,"deduplicated candidates")
        expect(candidates.allSatisfy {!$0.discovery && $0.playlistTags == ["夜晚"] && $0.userTags == ["工作","专注"]},"tag provenance preserved")
        let payload=try CandidateSelector.payload(candidates)
        expect(payload.contains("playlistTags") && payload.contains("userTags"),"AI payload distinguishes tag source")
        let first=candidates[0]
        let response="{\"intro\":\"慢慢听。\",\"picks\":[{\"id\":\"\(first.id)\",\"reason\":\"来自你的夜晚歌单。\"}]}"
        let selection=try CandidateSelector.parse(response,candidates:candidates)
        expect(selection.tracks[0].track == first.track,"model ID resolves canonical metadata")
        do {_=try CandidateSelector.parse("{\"intro\":\"x\",\"picks\":[{\"id\":\"999999\",\"reason\":\"fake\"}]}",candidates:candidates);preconditionFailure("reject hallucinated IDs")}
        catch {expect(error.localizedDescription.contains("候选池以外"),"unknown song blocked")}
        do {_=try CandidateSelector.parse("not JSON",candidates:candidates);preconditionFailure("reject malformed")}
        catch {expect(error.localizedDescription.contains("格式"),"malformed selection recoverable")}
        // 80/20 hard cap — mirrors the 2026-11-07 real run: model returned 1 library + 4 new songs.
        let fresh:[MusicCandidate]=(0..<8).map { MusicCandidate(track:Track(id:900_000+Int64($0),name:"新歌\($0)",artist:"A",milliseconds:200_000),source:"网易云搜索",playlistTags:[],userTags:[],discovery:true) }
        let pool=candidates+fresh
        func pickJSON(_ ids:[Int64]) -> String { "{\"intro\":\"夜\",\"picks\":["+ids.map { "{\"id\":\"\($0)\",\"reason\":\"r\"}" }.joined(separator:",")+"]}" }
        let skewed=try CandidateSelector.parse(pickJSON([first.id]+fresh.prefix(4).map(\.id)),candidates:pool)
        expect(skewed.tracks.count == 5,"cap keeps five cards")
        expect(skewed.tracks.filter(\.discovery).count == 1,"at most one new song in five")
        expect(skewed.tracks.last?.track.id == fresh[0].id,"model's first new song kept, placed last")
        expect(skewed.tracks[0].track.id == first.id && skewed.tracks[0].reason == "r","model library pick keeps its reason")
        expect(skewed.tracks.dropFirst().prefix(3).allSatisfy {!$0.discovery && $0.reason.contains("补位")},"backfill comes from library and is labelled")
        expect(Set(skewed.tracks.map(\.id)).count == 5,"backfill has no duplicates")
        expect(skewed.tracks.dropFirst().prefix(3).map(\.track.id) == candidates.dropFirst().prefix(3).map(\.id),"backfill follows shortlist rank")
        let allNew=try CandidateSelector.parse(pickJSON(fresh.prefix(5).map(\.id)),candidates:pool)
        expect(allNew.tracks.filter(\.discovery).count == 1 && allNew.tracks.count == 5,"all-new answer becomes 4 library + 1 new")
        let small=try CandidateSelector.parse(pickJSON([first.id,fresh[0].id]),candidates:pool)
        expect(small.tracks.count == 2 && small.tracks.allSatisfy {!$0.discovery},"under five picks no new song")
        let fair=try CandidateSelector.parse(pickJSON(candidates.prefix(4).map(\.id)+[fresh[0].id]),candidates:pool)
        let fairIDs:[Int64]=candidates.prefix(4).map { $0.id }+[fresh[0].id]
        expect(fair.tracks.map { $0.track.id } == fairIDs && !fair.tracks.contains {$0.reason.contains("补位")},"compliant answer untouched")
        let many=try CandidateSelector.parse(pickJSON(candidates.prefix(7).map(\.id)),candidates:pool)
        expect(many.tracks.count == 5,"never more than five cards")
        do {_=try CandidateSelector.parse(pickJSON(fresh.prefix(2).map { $0.id }),candidates:fresh);preconditionFailure("reject new-only without library")}
        catch {expect(error.localizedDescription.contains("补位"),"new-only without library is reported")}
        let old=AIMessage(role:"assistant",content:"旧消息")
        let data=try JSONEncoder().encode(old)
        expect(try JSONDecoder().decode(AIMessage.self,from:data).recommendations == nil,"old chat remains decodable")
        var message=old;message.recommendations=selection.tracks
        expect(try JSONDecoder().decode(AIMessage.self,from:JSONEncoder().encode(message)).recommendations == selection.tracks,"song cards persist")
        library.recordSelection(first.track);library.recordSkip(first.track)
        expect(library.snapshot.listening[String(first.id)]?.skipped == 1,"local feedback recorded")
        let newCandidates=CandidateSelector.shortlist(snapshot:library.snapshot,query:"适合夜晚的歌",seed:1)
        expect(newCandidates.first?.id != first.id,"recent skip de-prioritized")
        await library.flush()
        print("Library checks passed: \(checks)")
    }
}
