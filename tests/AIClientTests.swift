import Foundation

final class MockProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    static var failure: Error?
    static var lastRequest: URLRequest?
    static var queue: [(Int,Data)] = []
    static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest=request
        if let stream=request.httpBodyStream { stream.open(); var data=Data(); var buffer=[UInt8](repeating:0,count:4096); while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:4096); if n<=0 {break}; data.append(buffer,count:n) }; stream.close(); Self.bodies.append(data) } else if let body=request.httpBody { Self.bodies.append(body) }
        if let failure=Self.failure { client?.urlProtocol(self,didFailWithError:failure); return }
        let (status,payload)=Self.queue.isEmpty ? (Self.status,Self.payload) : Self.queue.removeFirst()
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
// Test model persistence/cancellation without touching the real system Keychain.
enum Vault {
    static var items: [String:String] = [:]
    static func read(_ key:String)->String { items[key] ?? "" }
    static func write(_ key:String,_ value:String) throws { items[key]=value }
}
@main struct AIClientTests {
    @MainActor static func main() async throws {
        var checks=0
        func expect(_ value:Bool,_ message:String) { precondition(value,message);checks += 1 }
        var config=AIConfiguration(endpoint:"https://models.example/v1/",model:"example-model",apiKey:"private-test-key")
        expect(try config.completionURL.absoluteString == "https://models.example/v1/chat/completions","base normalization")
        for endpoint in ["https://models.example/v1/chat/completions","https://models.example/v1/chat/completions/"] {
            config.endpoint=endpoint
            expect(try config.completionURL.absoluteString == "https://models.example/v1/chat/completions","full URL normalization")
        }
        for endpoint in ["http://models.example/v1","https://name:secret@models.example/v1","https://models.example/v1?api_key=secret","file:///tmp/private","https://models.example/#fragment"] {
            config.endpoint=endpoint;expect((try? config.completionURL) == nil,"reject unsafe URL")
        }
        config.endpoint="http://127.0.0.1:11434/v1"
        expect((try? config.completionURL) != nil,"local model accepted")
        config.endpoint="https://models.example/v1"
        let history=(0..<100).map { AIMessage(role:$0 % 2 == 0 ? "user" : "assistant",content:String(repeating:"歌",count:2500)) }
        let context=DJContext(taste:String(repeating:"偏好",count:3000),track:"A · B",shareTaste:false)
        let request=try AIClient.request(configuration:config,history:history,context:context)
        let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let messages=body["messages"] as! [[String:String]]
        expect(messages.count <= 13,"history count bound")
        expect(messages.dropFirst().reduce(0) {$0+($1["content"]?.count ?? 0)} <= 6000,"context character budget")
        expect(!(messages.first!["content"]!).contains("偏好"),"taste excluded without opt-in")
        expect(messages.dropFirst().first?["role"] == "user","history starts with user")
        expect(body["max_tokens"] as? Int == 600,"output bounded")
        expect(request.value(forHTTPHeaderField:"Authorization") == "Bearer private-test-key","authentication header")
        var optIn=context;optIn.shareTaste=true
        let opted=try AIClient.request(configuration:config,history:[],context:optIn)
        let optedBody=try JSONSerialization.jsonObject(with:opted.httpBody!) as! [String:Any]
        let system=(optedBody["messages"] as! [[String:String]])[0]["content"]!
        expect(system.count < 1800 && system.contains("偏好"),"taste clipped")
        config.apiKey=""
        expect(try AIClient.request(configuration:config,history:[],context:context).value(forHTTPHeaderField:"Authorization") == nil,"optional local auth")
        let sessionConfig=URLSessionConfiguration.ephemeral;sessionConfig.protocolClasses=[MockProtocol.self]
        let client=AIClient(session:URLSession(configuration:sessionConfig))
        MockProtocol.payload=Data(#"{"choices":[{"message":{"content":"  今晚慢慢听。  "}}]}"#.utf8)
        let reply=try await client.reply(configuration:config,history:[],context:context)
        expect(reply == "今晚慢慢听。","completion text decoded")
        for (status,payload,expected) in [(401,"secret provider detail","认证失败"),(429,"quota","限流"),(200,"{}","格式"),(200,#"{"choices":[{"message":{"content":" "}}]}"#,"文字")] {
            MockProtocol.status=status;MockProtocol.payload=Data(payload.utf8)
            do { _=try await client.reply(configuration:config,history:[],context:context);preconditionFailure("expected error") }
            catch {expect(error.localizedDescription.contains(expected),"actionable redacted errors")}
        }
        MockProtocol.status=200;MockProtocol.payload=Data(#"{"choices":[{"message":{"content":"模型回复"}}]}"#.utf8)
        // Model discovery must work before a model has been selected.
        config.model=""
        for endpoint in ["https://models.example/v1", "https://models.example/v1/chat/completions/", "https://models.example/v1/models"] {
            config.endpoint=endpoint
            expect(try config.modelsURL.absoluteString == "https://models.example/v1/models","models URL normalization")
        }
        config.apiKey="catalog-key"
        let modelRequest=try AIClient.modelsRequest(configuration:config)
        expect(modelRequest.httpMethod == "GET" && modelRequest.httpBody == nil,"catalog GET without completion")
        expect(modelRequest.value(forHTTPHeaderField:"Authorization") == "Bearer catalog-key","catalog auth")
        MockProtocol.payload=Data(#"{"data":[{"id":"z-model"},{"id":"a-model"},{"id":"a-model"},{"id":" "}]}"#.utf8)
        let models=try await client.models(configuration:config)
        expect(models == ["a-model","z-model"],"catalog trimmed deduplicated sorted")
        for (status,payload,expected) in [(404,"{}","不支持"),(401,"private-key-echo","认证失败"),(200,#"{"data":[]}"#,"未返回"),(200,#"{"wrong":[]}"#,"不支持")] {
            MockProtocol.status=status;MockProtocol.payload=Data(payload.utf8)
            do { _=try await client.models(configuration:config);preconditionFailure("expected catalog error") }
            catch { expect(error.localizedDescription.contains(expected) && !error.localizedDescription.contains("private-key-echo"),"safe catalog fallback") }
        }
        config.model="example-model";config.endpoint="https://models.example/v1"
        MockProtocol.status=200;MockProtocol.payload=Data(#"{"choices":[{"message":{"content":"模型回复"}}]}"#.utf8)
        let google=AIConfiguration(endpoint:"https://generativelanguage.googleapis.com/v1beta/openai/",model:"models/gemini-test",apiKey:"test-key")
        let googleRequest=try AIClient.request(configuration:google,history:[],context:DJContext())
        let googleBody=try JSONSerialization.jsonObject(with:googleRequest.httpBody!) as! [String:Any]
        expect(googleBody["model"] as? String == "gemini-test","Google resource prefix stripped for completion")
        expect(AIConfiguration(model:"models/custom").normalizedModel(for:URL(string:"https://other.example")!) == "models/custom","other providers keep model namespace")
        MockProtocol.payload=Data(#"{"data":[{"id":"models/gemini-test"},{"id":"gemini-test"}]}"#.utf8)
        expect(try await client.models(configuration:google) == ["gemini-test"],"Google catalog normalized and deduplicated")
        expect(AIError.http(503).localizedDescription.contains("暂时不可用"),"503 recovery message")
        MockProtocol.payload=Data(#"{"choices":[{"message":{"content":"模型回复"}}]}"#.utf8)
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(identifier:"America/New_York")!
        func localDate(_ year:Int,_ month:Int,_ day:Int,_ hour:Int,_ minute:Int=0)->Date { calendar.date(from:DateComponents(year:year,month:month,day:day,hour:hour,minute:minute))! }
        var clock=localDate(2026,11,7,23)
        let dailySuite="dev.viberadio.daily-tests.\(UUID().uuidString)"
        let dailyDefaults=UserDefaults(suiteName:dailySuite)!
        defer { dailyDefaults.removePersistentDomain(forName:dailySuite) }
        let daily=DJChatModel(defaults:dailyDefaults,now:{clock},calendar:calendar)
        dailyDefaults.set("保留的音乐偏好",forKey:"studioTaste")
        daily.recordLocal(user:"今晚听什么",reply:"先慢下来。")
        clock=localDate(2026,11,8,3,59); daily.resetForNewDayIfNeeded()
        expect(daily.messages.count == 2,"history survives midnight and background return before 4am")
        clock=localDate(2026,11,8,4)
        expect(daily.messages.count == 2,"active conversation not reset by clock alone")
        daily.resetForNewDayIfNeeded()
        expect(daily.messages.isEmpty && dailyDefaults.data(forKey:"djChatHistory") == nil,"reactivation at 4am clears transcript")
        expect(dailyDefaults.string(forKey:"studioTaste") == "保留的音乐偏好","daily reset preserves taste")
        daily.recordLocal(user:"新的一天",reply:"早安")
        expect(DJChatModel(defaults:dailyDefaults,now:{clock},calendar:calendar).messages.count == 2,"same day relaunch restores transcript")
        clock=localDate(2026,11,10,12)
        expect(DJChatModel(defaults:dailyDefaults,now:{clock},calendar:calendar).messages.isEmpty,"relaunch after several days resets history")
        expect(DJChatModel.chatDay(at:localDate(2026,11,1,3,59),calendar:calendar) != DJChatModel.chatDay(at:localDate(2026,11,1,4),calendar:calendar),"DST fall day still changes at local 4am")
        expect(DJChatModel.chatDay(at:localDate(2026,3,8,3,59),calendar:calendar) != DJChatModel.chatDay(at:localDate(2026,3,8,4),calendar:calendar),"DST spring day still changes at local 4am")
        let suite="dev.viberadio.tests.\(UUID().uuidString)";let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let model=DJChatModel(defaults:defaults,client:client)
        try model.save(config)
        expect(defaults.string(forKey:"aiEndpoint") == config.endpoint,"saved endpoint")
        expect(defaults.string(forKey:"aiAPIKey") == nil,"secret not in defaults")
        model.send("你好",context:DJContext())
        while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
        expect(model.messages.map(\.role) == ["user","assistant"],"real response appended")
        let restored=DJChatModel(defaults:defaults,client:client)
        expect(restored.messages.count == 2,"local conversation restored")
        MockProtocol.failure=URLError(.timedOut)
        model.send("下一条",context:DJContext())
        while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
        expect(model.canRetry && model.error.contains("超时"),"retry after timeout")
        MockProtocol.failure=nil
        model.retry()
        while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
        expect(model.messages.filter(\.mine).count == 2,"retry does not duplicate user")
        model.send("取消",context:DJContext());model.stop()
        try await Task.sleep(nanoseconds:20_000_000)
        expect(model.messages.last?.content == "取消" && model.canRetry,"cancel cannot append stale response")
        model.clear()
        expect(model.messages.isEmpty && defaults.data(forKey:"djChatHistory") == nil,"clear removes local history")
        clock=localDate(2026,11,10,23)
        let activeDaily=DJChatModel(defaults:dailyDefaults,client:client,now:{clock},calendar:calendar)
        try activeDaily.save(config)
        activeDaily.send("跨夜继续聊",context:DJContext())
        clock=localDate(2026,11,11,4)
        activeDaily.resetForNewDayIfNeeded()
        expect(activeDaily.busy && !activeDaily.messages.isEmpty,"daily reset defers while reply is in flight")
        while activeDaily.busy { try await Task.sleep(nanoseconds:1_000_000) }
        expect(activeDaily.messages.count == 2,"cross-boundary reply completes without clearing")
        activeDaily.resetForNewDayIfNeeded()
        expect(activeDaily.messages.isEmpty,"next idle activation performs deferred reset")
        let profileSuite="dev.viberadio.profile-tests.\(UUID().uuidString)"
        let profileDefaults=UserDefaults(suiteName:profileSuite)!
        defer { profileDefaults.removePersistentDomain(forName:profileSuite) }
        let profileChat=DJChatModel(defaults:profileDefaults)
        let firstAI=AIConfiguration(endpoint:"https://one.example/v1",model:"one",apiKey:"key-one")
        let secondAI=AIConfiguration(endpoint:"https://two.example/v1",model:"two",apiKey:"key-two")
        try profileChat.saveProfile(firstAI,name:"日常")
        let firstID=profileChat.activeProfileID!
        try profileChat.saveProfile(secondAI,name:"备用")
        let secondID=profileChat.activeProfileID!
        expect(profileChat.profiles.count == 2 && firstID != secondID,"multiple AI profiles created")
        try profileChat.activateProfile(firstID)
        expect(profileChat.configuration == firstAI,"AI switch restores independent key and model")
        try profileChat.saveProfile(firstAI,name:"改名",id:firstID)
        expect(profileChat.profiles.count == 2 && profileChat.profiles.first?.name == "改名","editing keeps identity")
        let metadata=String(decoding:profileDefaults.data(forKey:"aiProfiles")!,as:UTF8.self)
        expect(!metadata.contains("key-one") && !metadata.contains("key-two"),"AI profile metadata has no credentials")
        let restoredProfiles=DJChatModel(defaults:profileDefaults)
        expect(restoredProfiles.activeProfileID == firstID && restoredProfiles.profiles.count == 2,"AI profile selection restores")
        restoredProfiles.clear()
        expect(restoredProfiles.profiles.count == 2,"clearing chat preserves profiles")
        try restoredProfiles.deleteProfile(firstID)
        expect(restoredProfiles.activeProfileID == secondID && restoredProfiles.configuration == secondAI,"deleting active AI falls back")
        try restoredProfiles.deleteProfile(secondID)
        expect(restoredProfiles.profiles.isEmpty && restoredProfiles.configuration.apiKey.isEmpty && restoredProfiles.activeProfileID == nil,"deleting last AI clears connection")
        expect(Vault.read("aiProfile-"+firstID.uuidString).isEmpty,"deleted AI credential cleared")
        // 串词
        let a=Track(id:1,name:"夜航",artist:"甲",milliseconds:200_000), b=Track(id:2,name:"晚风",artist:"乙",milliseconds:200_000)
        expect(BridgeWriter.template(from:a,to:b,reason:"适合慢慢走。") == "刚才是甲的《夜航》。接下来，乙的《晚风》。适合慢慢走。","bridge template")
        expect(!BridgeWriter.template(from:a,to:b,reason:"按你的歌单补位，DJ 未单独点评。").contains("补位"),"template skips backfill reason")
        var night=DateComponents(); night.year=2026; night.month=11; night.day=7; night.hour=23
        let bridge=BridgeWriter.context(from:a,to:b,fromReason:"r1",toReason:"按你的歌单补位",request:"想听适合夜晚的歌",now:Calendar.current.date(from:night)!)
        let prompt=bridge.systemOverride ?? ""
        expect(prompt.contains("晚风") && prompt.contains("夜航") && prompt.contains("想听适合夜晚的歌") && prompt.contains("深夜"),"bridge facts present")
        expect(!prompt.contains("补位"),"bridge facts skip backfill reason")
        let bridgeRequest=try AIClient.request(configuration:config,history:[AIMessage(role:"user",content:"请说这段串词。")],context:bridge)
        let bridgeBody=try JSONSerialization.jsonObject(with:bridgeRequest.httpBody!) as! [String:Any]
        let bridgeMessages=bridgeBody["messages"] as! [[String:Any]]
        expect((bridgeMessages.first?["content"] as? String) == prompt + DJLength.current.directive + DJToneRule.directive + DJLanguage.chinese.directive,"override replaces system prompt")
        var english=bridge; english.language = .english
        let englishBody=try JSONSerialization.jsonObject(with:try AIClient.request(configuration:config,history:[AIMessage(role:"user",content:"今天好累")],context:english).httpBody!) as! [String:Any]
        let englishSystem=((englishBody["messages"] as! [[String:Any]]).first?["content"] as? String) ?? ""
        expect(englishSystem.hasSuffix(DJLanguage.english.directive) && englishSystem.contains("no matter what language the user writes in"),"english directive appended last")
        expect(DJContext().language == DJLanguage.current,"default language from settings")
        for language in [DJLanguage.korean,.japanese,.french] {
            var c=bridge; c.language=language
            let body=try JSONSerialization.jsonObject(with:try AIClient.request(configuration:config,history:[AIMessage(role:"user",content:"hello")],context:c).httpBody!) as! [String:Any]
            expect((((body["messages"] as! [[String:Any]]).first?["content"] as? String) ?? "").hasSuffix(language.directive),"\(language.rawValue) directive")
        }
        expect(DJLanguage.english.directive.contains("Never add translations") && DJLanguage.japanese.directive.contains("spoken Japanese") && DJLanguage.french.directive.contains("spoken French") && DJLanguage.korean.directive.contains("spoken Korean"),"language names")
        var jaSelect=DJContext(); jaSelect.language = .japanese; jaSelect.selectionPayload="[]"
        let jaBody=try JSONSerialization.jsonObject(with:try AIClient.request(configuration:config,history:[AIMessage(role:"user",content:"周末")],context:jaSelect).httpBody!) as! [String:Any]
        let jaSystem=((jaBody["messages"] as! [[String:Any]]).first?["content"] as? String) ?? ""
        expect(jaSystem.contains("简短日本語（Japanese）开场") && !jaSystem.contains("简短中文开场"),"selection prompt names the chosen language")
        expect(DJTranslator.parse("```json\n[\" 你好 \",\"适合深夜\"]\n```",count:2) == ["你好","适合深夜"],"translation parsed from fenced json")
        expect(DJTranslator.parse("[\"只有一项\"]",count:2) == nil && DJTranslator.parse("不是数组",count:1) == nil,"translation count checked")
        expect(DJTranslator.request(["a\"b"]) == "[\"a\\\"b\"]","translation request is json")
        expect(DJTranslator.context().language == .chinese && DJTranslator.context().systemOverride == DJTranslator.system,"translator context")
        let old=try JSONDecoder().decode(AIMessage.self,from:Data(#"{"id":"8C2E1F5C-3C4B-4C9E-9A57-2E4E3B6E9C11","role":"assistant","content":"hi"}"#.utf8))
        expect(old.translation == nil && old.reasonTranslations == nil,"old history still decodes")
        for length in DJLength.allCases {
            var c=DJContext(); c.length=length
            let sys=((try JSONSerialization.jsonObject(with:try AIClient.request(configuration:config,history:[AIMessage(role:"user",content:"hi")],context:c).httpBody!) as! [String:Any])["messages"] as! [[String:Any]]).first?["content"] as? String ?? ""
            expect(sys.contains(length.directive) && sys.hasSuffix(c.language.directive),"\(length.rawValue) length rule before language rule")
        }
        var noLength=DJTranslator.context(); noLength.language = .chinese
        let tSys=((try JSONSerialization.jsonObject(with:try AIClient.request(configuration:config,history:[AIMessage(role:"user",content:"[]")],context:noLength).httpBody!) as! [String:Any])["messages"] as! [[String:Any]]).first?["content"] as? String ?? ""
        expect(!tSys.contains("篇幅规则"),"translator has no length rule")
        expect(DJLength.short.bridgeLimit < DJLength.medium.bridgeLimit && DJLength.medium.bridgeLimit < DJLength.long.bridgeLimit && DJLength.allCases.map(\.label) == ["短","中","长"],"length labels and limits")
        var toneOn=DJContext(); toneOn.tone=true
        let toneSys=((try JSONSerialization.jsonObject(with:try AIClient.request(configuration:config,history:[AIMessage(role:"user",content:"hi")],context:toneOn).httpBody!) as! [String:Any])["messages"] as! [[String:Any]]).first?["content"] as? String ?? ""
        expect(toneSys.contains("（叹气）（轻笑）") && !tSys.contains("语气规则") && !DJTranslator.context().tone,"tone rule for DJ lines only")
        expect(DJLanguage.english.directive.contains("tone sounds"),"language rule allows tone marks")
        expect(DJLanguage.allCases.map(\.label) == ["中文","English","한국어","日本語","Français"],"five language labels")
        expect((bridgeBody["max_tokens"] as? Int) == 200,"short token budget for bridge")
        expect(BridgeWriter.clean("「下一首是《晚风》，慢慢听。」\n",to:b) == "下一首是《晚风》，慢慢听。","clean strips quotes and newlines")
        expect(BridgeWriter.clean("夜深了。",to:b) == "夜深了。接下来，《晚风》。","clean appends next song")
        expect(BridgeWriter.clean("  **  ",to:b) == nil,"empty reply falls back")
        expect((BridgeWriter.clean(String(repeating:"好",count:400),to:b)?.count ?? 0) <= DJLength.current.bridgeLimit + 20,"clean caps length")
        // DJ 调用工具
        let toolCall=#"{"choices":[{"message":{"content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"control_playback","arguments":"{\"action\":\"next\"}"}}]}}]}"#
        let finalText=#"{"choices":[{"message":{"content":"换好了，这首更安静。"}}],"usage":{"prompt_tokens":5,"completion_tokens":3}}"#
        MockProtocol.queue=[(200,Data(toolCall.utf8)),(200,Data(finalText.utf8))]; MockProtocol.bodies=[]
        var agentContext=DJContext(); agentContext.agent=true; agentContext.companion="现在：周六 21:00"
        var executed:[AIToolCall]=[]
        let tools=[AITool(name:"control_playback",description:"控制播放",parameters:["type":"object","properties":["action":["type":"string"]]])]
        let agent=try await client.agentReply(configuration:config,history:[AIMessage(role:"user",content:"换一首")],context:agentContext,tools:tools) { call in executed.append(call); return "下一首：《晚风》" }
        expect(executed.map(\.name) == ["control_playback"] && (executed.first?.args["action"] as? String) == "next","tool executed with parsed args")
        expect(agent.text == "换好了，这首更安静。" && agent.actions == ["下一首：《晚风》"] && agent.usage?.completion_tokens == 3,"final reply after tool")
        let second=try JSONSerialization.jsonObject(with:MockProtocol.bodies[1]) as! [String:Any]
        let secondMessages=second["messages"] as! [[String:Any]]
        expect(secondMessages.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == "c1" } && secondMessages.contains { ($0["tool_calls"] as? [Any])?.isEmpty == false },"tool result sent back")
        let firstBody=try JSONSerialization.jsonObject(with:MockProtocol.bodies[0]) as! [String:Any]
        let agentSystem=((firstBody["messages"] as! [[String:Any]]).first?["content"] as? String) ?? ""
        expect((firstBody["tools"] as? [Any])?.count == 1 && agentSystem.contains("工具") && agentSystem.contains("周六 21:00"),"agent prompt has tools and companion facts")
        MockProtocol.queue=[(400,Data("{}".utf8)),(200,Data(#"{"choices":[{"message":{"content":"普通回复"}}]}"#.utf8))]
        let fallback=try await client.agentReply(configuration:config,history:[AIMessage(role:"user",content:"你好")],context:agentContext,tools:tools) { _ in "x" }
        expect(fallback.text == "普通回复" && fallback.actions.isEmpty,"service without tools falls back")
        let loop=#"{"choices":[{"message":{"content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"control_playback","arguments":"{}"}}]}}]}"#
        MockProtocol.queue=Array(repeating:(200,Data(loop.utf8)),count:4)
        var calls=0
        let bounded=try await client.agentReply(configuration:config,history:[AIMessage(role:"user",content:"x")],context:agentContext,tools:tools) { _ in calls+=1; return "ok" }
        expect(calls == 3 && bounded.text == "好的。","tool loop bounded")
        MockProtocol.queue=[]
        let plainPrompt=((try JSONSerialization.jsonObject(with:AIClient.request(configuration:config,history:[AIMessage(role:"user",content:"x")],context:DJContext()).httpBody!) as! [String:Any])["messages"] as! [[String:Any]]).first?["content"] as? String ?? ""
        expect(plainPrompt.contains("只能文字对话"),"non-agent prompt unchanged")
        let legacy=try JSONDecoder().decode(AIMessage.self,from:Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","content":"旧"}"#.utf8))
        expect(legacy.actions == nil && legacy.date == nil,"old messages decode without actions/date")
        print("AI checks passed: \(checks)")
    }
}
