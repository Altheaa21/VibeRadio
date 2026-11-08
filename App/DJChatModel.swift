import Foundation
import Combine

struct AIConnectionProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: String
    var model: String
    var keyAccount: String { "aiProfile-" + id.uuidString }
}

@MainActor final class DJChatModel: ObservableObject {
    @Published private(set) var profiles: [AIConnectionProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published var configuration: AIConfiguration
    @Published private(set) var messages: [AIMessage] = []
    @Published private(set) var busy = false
    @Published private(set) var testing = false
    @Published private(set) var error = ""
    @Published private(set) var connectionStatus = ""
    @Published private(set) var canRetry = false
    private let defaults: UserDefaults
    private let client: AIClient
    private let preview: Bool
    private let now: () -> Date
    private let calendar: Calendar
    private var historyDay: String
    private var task: Task<Void,Never>?
    private var testTask: Task<Void,Never>?
    private var generation = UUID()
    private var testGeneration = UUID()
    private var lastContext = DJContext()
    /// 可选：允许 DJ 调用的本机工具及执行器。
    var tools: [AITool] = []
    var executeTool: ((AIToolCall) async -> String)?
    var ready: Bool { (try? configuration.completionURL) != nil }

    init(preview: Bool = false, defaults: UserDefaults = .standard, client: AIClient = AIClient(), now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.defaults=defaults; self.client=client; self.preview=preview
        self.now=now; self.calendar=calendar
        historyDay=defaults.string(forKey:"djChatDay") ?? Self.chatDay(at:now(),calendar:calendar)
        configuration=AIConfiguration(endpoint:preview ? "" : defaults.string(forKey:"aiEndpoint") ?? "",model:preview ? "" : defaults.string(forKey:"aiModel") ?? "",apiKey:preview ? "" : Vault.read("aiAPIKey"))
        if !preview, let data=defaults.data(forKey:"djChatHistory"), let saved=try? JSONDecoder().decode([AIMessage].self,from:data) { messages=Array(saved.suffix(60)) }
        if !preview {
            if let data=defaults.data(forKey:"aiProfiles"),let saved=try? JSONDecoder().decode([AIConnectionProfile].self,from:data) { profiles=saved }
            activeProfileID=defaults.string(forKey:"activeAIProfile").flatMap(UUID.init(uuidString:))
            if profiles.isEmpty, !configuration.endpoint.isEmpty { try? saveProfile(configuration,name:"当前 AI 配置") }
        }
        resetForNewDayIfNeeded()
    }
    func save(_ draft: AIConfiguration) throws {
        _ = try draft.completionURL
        guard !busy && !testing else { throw AIError.configuration("请先停止当前请求，再修改连接。") }
        try Vault.write("aiAPIKey",draft.apiKey)
        defaults.set(draft.endpoint.trimmingCharacters(in:.whitespacesAndNewlines),forKey:"aiEndpoint")
        defaults.set(draft.model.trimmingCharacters(in:.whitespacesAndNewlines),forKey:"aiModel")
        configuration=draft; connectionStatus="已保存，尚未测试"; error=""
    }
    private func persistProfiles() {
        defaults.set(try? JSONEncoder().encode(profiles),forKey:"aiProfiles")
        defaults.set(activeProfileID?.uuidString,forKey:"activeAIProfile")
    }
    func profileConfiguration(_ profile:AIConnectionProfile) -> AIConfiguration {
        AIConfiguration(endpoint:profile.endpoint,model:profile.model,apiKey:Vault.read(profile.keyAccount))
    }
    func saveProfile(_ draft:AIConfiguration,name:String,id:UUID? = nil) throws {
        let name=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { throw AIError.configuration("请给配置起个名字。") }
        _ = try draft.completionURL
        guard !busy && !testing else { throw AIError.configuration("请先停止当前请求，再切换配置。") }
        let profile=AIConnectionProfile(id:id ?? UUID(),name:name,endpoint:draft.endpoint.trimmingCharacters(in:.whitespacesAndNewlines),model:draft.model.trimmingCharacters(in:.whitespacesAndNewlines))
        try Vault.write(profile.keyAccount,draft.apiKey)
        try save(draft)
        if let i=profiles.firstIndex(where:{$0.id==profile.id}) { profiles[i]=profile } else { profiles.append(profile) }
        activeProfileID=profile.id; persistProfiles()
    }
    func activateProfile(_ id:UUID) throws {
        guard let profile=profiles.first(where:{$0.id==id}) else { return }
        try save(profileConfiguration(profile));activeProfileID=id;persistProfiles()
    }
    func deleteProfile(_ id:UUID) throws {
        guard !busy && !testing else { throw AIError.configuration("请先停止当前请求，再删除配置。") }
        guard let profile=profiles.first(where:{$0.id==id}) else { return }
        if activeProfileID==id {
            if let next=profiles.first(where:{$0.id != id}) { try activateProfile(next.id) }
            else {
                try Vault.write("aiAPIKey","")
                defaults.removeObject(forKey:"aiEndpoint");defaults.removeObject(forKey:"aiModel")
                configuration=AIConfiguration();activeProfileID=nil
            }
        }
        try Vault.write(profile.keyAccount,"")
        profiles.removeAll {$0.id==id};persistProfiles();connectionStatus=""
    }
    func test(_ draft: AIConfiguration) {
        guard !testing && !busy else { return }
        testing=true; connectionStatus="正在连接…"
        let testID=UUID(); testGeneration=testID
        testTask=Task { [weak self] in
            guard let self else { return }
            defer { if self.testGeneration == testID { self.testing=false } }
            do {
                _ = try await self.client.reply(configuration:draft,history:[AIMessage(role:"user",content:"请只回复：连接成功。")],context:DJContext())
                guard self.testGeneration == testID else { return }
                self.connectionStatus="连接成功 · 已收到模型回复"
            } catch {
                guard self.testGeneration == testID else { return }
                self.connectionStatus=Self.message(error)
            }
        }
    }
    func send(_ text: String, context: DJContext) {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !busy && !testing && !text.isEmpty else { return }
        guard ready else { error="先在设置中连接 AI 模型，再开始聊天。"; return }
        guard text.count <= 2000 else { error="这段话有点长，请控制在 2,000 字以内。"; return }
        messages.append(AIMessage(role:"user",content:text)); persist()
        lastContext=context; perform()
    }
    func retry(context: DJContext? = nil) {
        guard canRetry && !busy && !testing else { return }
        if let context { lastContext=context }
        perform()
    }
    private func perform() {
        busy=true; error=""; canRetry=false
        let id=UUID(); generation=id
        let config=configuration, history=messages, context=lastContext
        task=Task { [weak self] in
            guard let self else { return }
            do {
                if context.agent, !self.tools.isEmpty, let execute=self.executeTool {
                    let reply=try await self.client.agentReply(configuration:config,history:history,context:context,tools:self.tools,execute:execute)
                    guard self.generation == id else { return }
                    var message=AIMessage(role:"assistant",content:reply.text)
                    message.actions=reply.actions.isEmpty ? nil : reply.actions; message.usage=reply.usage
                    self.messages.append(message); self.persist(); self.translate(message.id)
                } else {
                    let text=try await self.client.reply(configuration:config,history:history,context:context)
                    guard self.generation == id else { return }
                    let message=AIMessage(role:"assistant",content:text)
                    self.messages.append(message); self.persist(); self.translate(message.id)
                }
            } catch {
                guard self.generation == id else { return }
                self.error=Self.message(error); self.canRetry=true
            }
            if self.generation == id { self.busy=false }
        }
    }
    func stop() {
        generation=UUID(); testGeneration=UUID(); task?.cancel(); testTask?.cancel()
        if busy { error="已停止，可以重试这条消息。"; canRetry=true }
        if testing { connectionStatus="测试已停止" }
        busy=false; testing=false
    }
    func recordSongRequest(_ text:String) { messages.append(AIMessage(role:"user",content:String(text.prefix(2000))));persist() }
    func recordSongSelection(_ selection:SongSelection) {
        var message=AIMessage(role:"assistant",content:selection.intro)
        message.recommendations=selection.tracks;message.usage=selection.usage
        messages.append(message);persist(); translate(message.id)
    }
    /// 本机直接执行的指令、定时问候等：不经过模型，直接记一条。
    func recordLocal(user:String?,reply:String,actions:[String]=[]) {
        if let user, !user.isEmpty { messages.append(AIMessage(role:"user",content:String(user.prefix(2000)))) }
        var message=AIMessage(role:"assistant",content:reply); message.actions=actions.isEmpty ? nil : actions
        messages.append(message); persist(); translate(message.id)
    }
    @discardableResult func appendAssistant(_ text:String) -> AIMessage { let m=AIMessage(role:"assistant",content:text); messages.append(m); persist(); translate(m.id); return m }
    /// DJ 不说中文时，在后台把这条（含推荐理由）翻成中文，显示在下方；失败就不显示。
    func translate(_ id:UUID) {
        guard DJLanguage.current != .chinese, ready, !preview, let message=messages.first(where:{ $0.id == id }), !message.mine, message.translation == nil else { return }
        let texts=[ToneMarks.strip(message.content)]+(message.recommendations ?? []).map { ToneMarks.strip($0.reason) }
        guard texts.contains(where:{ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else { return }
        let config=configuration
        Task { [weak self] in
            guard let self, let raw=try? await self.client.reply(configuration:config,history:[AIMessage(role:"user",content:DJTranslator.request(texts))],context:DJTranslator.context()),
                  let list=DJTranslator.parse(raw,count:texts.count), let index=self.messages.firstIndex(where:{ $0.id == id }) else { return }
            self.messages[index].translation=list[0]
            if list.count > 1 { self.messages[index].reasonTranslations=Array(list.dropFirst()) }
            self.persist()
        }
    }
    /// 以本机日历凌晨 4 点作为聊天日边界，避免用固定 24 小时跨越夏令时。
    static func chatDay(at date:Date,calendar:Calendar) -> String {
        let boundary=calendar.date(bySettingHour:4,minute:0,second:0,of:date) ?? calendar.startOfDay(for:date)
        let day=date < boundary ? (calendar.date(byAdding:.day,value:-1,to:date) ?? date) : date
        let parts=calendar.dateComponents([.era,.year,.month,.day],from:day)
        return "\(parts.era ?? 0)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
    /// 仅在启动／重新激活时调用；正在回复时延后到下次激活，不中断当前对话。
    func resetForNewDayIfNeeded() {
        guard !preview, !busy, !testing else { return }
        let day=Self.chatDay(at:now(),calendar:calendar)
        if historyDay != day { clear() }
        else { defaults.set(historyDay,forKey:"djChatDay") }
    }
    func clear() {
        stop(); messages=[]; error=""; canRetry=false; lastContext=DJContext()
        historyDay=Self.chatDay(at:now(),calendar:calendar)
        if !preview { defaults.removeObject(forKey:"djChatHistory"); defaults.set(historyDay,forKey:"djChatDay") }
    }
    private func persist() {
        messages=Array(messages.suffix(60))
        if !preview {
            defaults.set(try? JSONEncoder().encode(messages),forKey:"djChatHistory")
            defaults.set(historyDay,forKey:"djChatDay")
        }
    }
    private static func message(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "请求已停止，可以重试。" }
        if (error as? URLError)?.code == .timedOut { return "模型回复超时，请稍后重试。" }
        if let known=error as? AIError { return known.localizedDescription }
        return "暂时无法连接模型，请检查网络和接口设置后重试。"
    }
}
