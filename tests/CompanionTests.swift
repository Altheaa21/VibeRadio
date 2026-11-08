import Foundation

@main struct CompanionTests {
    @MainActor static func main() async throws {
        var checks=0
        func expect(_ value:Bool,_ message:String) { precondition(value,message);checks += 1 }
        // 歌词
        let lrc="[ti:夜晚]\n[00:00.00] 作词 : 某人\n[00:01.00]编曲 Arrangement : 李雨寰\n[00:02.00]Producer：某人\n[00:12.50]第一句\n[00:15.2]第二句\n[01:02.345][01:30.00]副歌\n\n[00:20.00]   \n"
        let lines=LyricParser.parse(lrc,translation:"[00:12.50]First line")
        expect(lines.map(\.text) == ["第一句","第二句","副歌","副歌"],"lrc lines, credits and blanks skipped, repeated stamps expanded")
        expect(abs(lines[2].time-62.345)<0.001,"millisecond stamp")
        expect(lines[0].translation == "First line" && lines[1].translation.isEmpty,"translation aligned by time")
        expect(LyricParser.index(at:5,in:lines) == nil,"before first line")
        expect(LyricParser.index(at:13,in:lines) == 0 && LyricParser.index(at:15.1,in:lines) == 1 && LyricParser.index(at:200,in:lines) == 3,"current line by time")
        expect(LyricParser.parse("纯文本没有时间").isEmpty,"untimed text ignored")
        // 指令
        expect(CommandRouter.parse("下一首") == .next && CommandRouter.parse("切歌吧") == .next,"next")
        expect(CommandRouter.parse("暂停一下") == .pause && CommandRouter.parse("继续播放") == .resume,"pause/resume")
        for command in ["音量调到 30", "音量150", "音量 50%", "大声点", "小声点", "把音量调到40然后告诉我在放什么"] {
            expect(CommandRouter.parse(command) == nil,"DJ volume commands removed: \(command)")
        }
        expect(CommandRouter.parse("收藏这首") == .favorite(true),"favorite retained")
        expect(CommandRouter.parse("播放晴天") == .play("晴天") && CommandRouter.parse("来一首《夜晚》") == .play("夜晚"),"play by name")
        expect(CommandRouter.parse("我想听安静一点的歌") == nil && CommandRouter.parse("放点适合下雨天的") == nil,"vague requests go to AI")
        expect(CommandRouter.parse("今天好累，想听点温柔的，最好是女声，不要太吵") == nil,"long text goes to AI")
        expect(CommandRouter.parse("这是什么歌") == .nowPlaying && CommandRouter.parse("歌词") == .lyrics,"info commands")
        expect(CommandRouter.parse("一直播") == .continuous(true) && CommandRouter.parse("播完这组就停") == .continuous(false),"play mode")
        expect(CommandRouter.parse("30分钟后停") == .sleep(30) && CommandRouter.parse("睡前听半小时") == .sleep(30) && CommandRouter.parse("定时一小时") == .sleep(60),"sleep timer")
        expect(CommandRouter.parse("播完这首就停") == .stopAfterCurrent && CommandRouter.parse("取消定时") == .cancelSleep,"stop after current")
        expect(CommandRouter.sleepMinutes("我想听半小时的爵士") == nil && CommandRouter.parse("500分钟后停") == nil,"not a sleep timer / out of range")
        expect(CommandRouter.parse("下一首。") == .next && CommandRouter.parse("播放《晴天》。") == .play("晴天"),"speech punctuation")
        // 记忆检索
        let night=Track(id:7,name:"夜晚",artist:"李小楚",milliseconds:1)
        let memories=[MusicMemory(text:"大学毕业那年夏天总在宿舍听",trackID:7,trackName:"夜晚",artist:"李小楚"),
                      MusicMemory(text:"下雨天喜欢听钢琴"),MusicMemory(text:"不喜欢太吵的摇滚")]
        expect(MemoryIndex.relevant(memories,query:"随便聊聊",track:night).first?.trackID == 7,"current track memory first")
        expect(MemoryIndex.relevant(memories,query:"今天下雨了想听钢琴",track:nil).first?.text == "下雨天喜欢听钢琴","keyword memory")
        expect(MemoryIndex.relevant(memories,query:"晚饭吃什么",track:nil).isEmpty,"irrelevant memories not sent")
        expect(MemoryIndex.relevant(Array(repeating:memories[1],count:20),query:"下雨钢琴",track:nil).count == 3,"bounded to 3")
        // 口味档案
        var snapshot=LibrarySnapshot()
        let a=Track(id:1,name:"A",artist:"甲",milliseconds:1), b=Track(id:2,name:"B",artist:"甲 / 乙",milliseconds:1), c=Track(id:3,name:"C",artist:"丙",milliseconds:1)
        snapshot.playlists=[IndexedPlaylist(playlist:Playlist(id:1,name:"喜欢的音乐",count:3),tracks:[a,b,c]),IndexedPlaylist(playlist:Playlist(id:2,name:"停用",count:1),tracks:[Track(id:9,name:"X",artist:"丁",milliseconds:1)],enabled:false)]
        snapshot.listening=["3":ListeningRecord(selected:4,skipped:0),"1":ListeningRecord(selected:1,skipped:3)]
        let taste=TasteProfile.compute(snapshot,favorites:[FavoriteTrack(track:c)])
        expect(taste.totalTracks == 3 && taste.playlists == 1,"disabled playlists excluded")
        expect(taste.topArtists.first?.name == "丙" || taste.topArtists.first?.name == "甲","favorites weigh artists")
        expect(taste.topArtists.contains { $0.name == "乙" },"multi-artist split")
        expect(taste.mostPlayed.first?.name == "C" && taste.oftenSkipped == ["甲"],"plays and skips")
        expect(taste.digest.contains("喜欢的音乐") && taste.digest.count <= 900 && !taste.digest.contains("停用"),"digest bounded")
        // 节目单
        var cal=Calendar(identifier:.gregorian); cal.timeZone=TimeZone(identifier:"Asia/Shanghai")!
        func at(_ h:Int,_ m:Int) -> Date { cal.date(from:DateComponents(year:2026,month:11,day:7,hour:h,minute:m))! }
        let rain=WeatherSnapshot(temperature:12,code:63)
        let meeting=DayEvent(id:"e1",title:"周会",start:at(10,30),end:at(11,0))
        let slots=DayPlanner.plan(routines:Routine.defaults,weather:rain,events:[meeting,DayEvent(id:"e2",title:"假期",start:at(0,0),end:at(23,59),allDay:true)],calendar:cal)
        expect(slots.map(\.time) == Routine.defaults.map(\.time),"slots follow routines")
        expect(slots[1].events == ["10:30 周会"] && slots[1].query.contains("不抢注意力"),"event placed in its slot")
        expect(slots.allSatisfy { $0.query.contains("下雨") },"weather adjusts query")
        expect(!slots.contains { $0.events.contains { $0.contains("假期") } },"all-day events not placed")
        expect(DayPlanner.current(slots,at:at(11,0),calendar:cal) == 1 && DayPlanner.current(slots,at:at(23,0),calendar:cal) == 6,"current slot")
        var disabled=Routine.defaults; for i in disabled.indices { disabled[i].enabled=false }
        expect(DayPlanner.plan(routines:disabled,weather:nil,events:[],calendar:cal).count == Routine.defaults.count,"empty routines fall back to default day")
        // 定时触发
        var settings=CompanionSettings(); settings.hourlyCheckIn=true; settings.autoProgram=true
        var (t1,m1)=ProgramScheduler.due(now:at(8,2),settings:settings,memory:SchedulerMemory(),slots:slots,events:[meeting],calendar:cal)
        expect(t1 == [.morningGreeting],"first morning open greets once, no hourly duplicate, no slot switch on launch")
        (t1,m1)=ProgramScheduler.due(now:at(8,3),settings:settings,memory:m1,slots:slots,events:[meeting],calendar:cal)
        expect(t1.isEmpty,"no repeat")
        (t1,m1)=ProgramScheduler.due(now:at(9,1),settings:settings,memory:m1,slots:slots,events:[meeting],calendar:cal)
        expect(t1 == [.hourlyCheckIn(hour:9)],"hourly check-in")
        (t1,m1)=ProgramScheduler.due(now:at(10,1),settings:settings,memory:m1,slots:slots,events:[meeting],calendar:cal)
        expect(t1.contains(.hourlyCheckIn(hour:10)) && t1.contains(.slotStarted(slots[1])),"new slot triggers auto program")
        (t1,m1)=ProgramScheduler.due(now:at(10,22),settings:settings,memory:m1,slots:slots,events:[meeting],calendar:cal)
        expect(t1 == [.eventSoon(id:"e1",title:"周会",minutes:8)],"event reminder")
        (t1,m1)=ProgramScheduler.due(now:at(10,25),settings:settings,memory:m1,slots:slots,events:[meeting],calendar:cal)
        expect(t1.isEmpty,"event reminded once")
        var quiet=settings; quiet.morningGreeting=false; quiet.hourlyCheckIn=false; quiet.eventReminders=false; quiet.autoProgram=false
        let (t2,_)=ProgramScheduler.due(now:at(10,25),settings:quiet,memory:SchedulerMemory(),slots:slots,events:[meeting],calendar:cal)
        expect(t2.isEmpty,"all switches off")
        let (t3,_)=ProgramScheduler.due(now:at(13,0),settings:CompanionSettings(),memory:SchedulerMemory(),slots:slots,events:[],calendar:cal)
        expect(!t3.contains(.morningGreeting),"no morning greeting in afternoon")
        // 天气解析与描述
        let forecast=#"{"current":{"temperature_2m":11.6,"weather_code":61},"daily":{"temperature_2m_max":[14.2],"temperature_2m_min":[9.1]}}"#
        let w=WeatherService.parseForecast(Data(forecast.utf8))
        expect(w?.line == "小雨 12°（9°–14°）" && w?.musicHint.contains("下雨") == true,"forecast parsed")
        expect(WeatherService.parsePlace(Data(#"{"results":[{"name":"上海","latitude":31.22,"longitude":121.46}]}"#.utf8))?.name == "上海","geocode parsed")
        expect(WeatherService.parsePlace(Data(#"{}"#.utf8)) == nil,"unknown city")
        expect(WeatherService.forecastURL(latitude:31.2222,longitude:121.4581)!.absoluteString.contains("latitude=31.222"),"coordinates rounded")
        // 上下文限长、不含无关记忆
        var data=CompanionData(); data.settings.city="上海"
        let digest=CompanionContext.digest(data:data,weather:w,events:[meeting],memories:[memories[0]],taste:String(repeating:"口味",count:600),now:at(9,0))
        expect(digest.count <= 1800 && digest.contains("澜") && digest.contains("上海") && digest.contains("周会") && digest.contains("大学毕业"),"digest content")
        data.settings.shareContextWithDJ=false
        let privateDigest=CompanionContext.digest(data:data,weather:w,events:[meeting],memories:[],taste:"",now:at(9,0))
        expect(!privateDigest.contains("周会") && !privateDigest.contains("小雨"),"weather/calendar withheld when sharing off")
        // 档案持久化与旧文件兼容
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store=CompanionStore(directory:dir)
        store.setFavorite(night,true); store.remember("  第一次听是在火车上  ",track:night); store.data.profile.name="小夜"
        let reopened=CompanionStore(directory:dir)
        expect(reopened.isFavorite(7) && reopened.data.memories.first?.text == "第一次听是在火车上" && reopened.data.profile.name == "小夜","store persists")
        reopened.setFavorite(night,false); expect(!reopened.isFavorite(7),"unfavorite")
        try Data(#"{"profile":{"name":"旧","bio":"b","style":"s"}}"#.utf8).write(to:dir.appendingPathComponent("companion.json"))
        let legacy=CompanionStore(directory:dir)
        expect(legacy.data.profile.name == "旧" && legacy.data.routines.count == Routine.defaults.count && legacy.data.settings.morningGreeting,"old file fills defaults")
        legacy.migrateFavoriteIDs("1,3,999",known:[a,c]); expect(legacy.data.favorites.count == 2,"favorite id migration")
        // UPnP
        expect(UPnPProtocol.location(fromSSDP:"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLocation: http://192.168.1.20:49152/desc.xml\r\n\r\n")?.absoluteString == "http://192.168.1.20:49152/desc.xml","ssdp location")
        expect(UPnPProtocol.location(fromSSDP:"HTTP/1.1 200 OK\r\nLOCATION: http://8.8.8.8/desc.xml\r\n") == nil,"public location rejected")
        let desc=#"<root><URLBase>http://192.168.1.20:49152/</URLBase><device><friendlyName>客厅音箱 &amp; Hi-Fi</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/rc</controlURL></service><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>upnp/control/avt</controlURL></service></serviceList></device></root>"#
        let renderer=UPnPProtocol.renderer(fromDescription:Data(desc.utf8),location:URL(string:"http://192.168.1.20:49152/desc.xml")!)
        expect(renderer?.name == "客厅音箱 & Hi-Fi" && renderer?.controlURL.absoluteString == "http://192.168.1.20:49152/upnp/control/avt","renderer description")
        let foreign=desc.replacingOccurrences(of:"upnp/control/avt",with:"http://10.0.0.9/avt")
        expect(UPnPProtocol.renderer(fromDescription:Data(foreign.utf8),location:URL(string:"http://192.168.1.20:49152/desc.xml")!) == nil,"control URL must stay on device host")
        let soap=UPnPProtocol.soap("SetAVTransportURI",[("CurrentURI","http://a/b?x=1&y=<2>")])
        let soapText=String(decoding:soap.body,as:UTF8.self)
        expect(soapText.contains("x=1&amp;y=&lt;2&gt;") && soapText.contains("<InstanceID>0</InstanceID>") && soap.soapAction.contains("#SetAVTransportURI"),"soap escaped")
        expect(UPnPProtocol.rendererFriendly(URL(string:"https://m701.music.126.net/a.mp3?k=1")!).absoluteString == "http://m701.music.126.net/a.mp3?k=1" && UPnPProtocol.rendererFriendly(URL(string:"https://example.com/a")!).scheme == "https","http for netease cdn only")
        print("Companion checks passed: \(checks)")
    }
}
