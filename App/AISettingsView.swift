import SwiftUI

struct AISettingsView: View {
    @ObservedObject var chat: DJChatModel
    @ObservedObject var voice: DJVoice
    @State private var voiceDraft = VoiceConfiguration()
    @State private var voiceStatus = ""
    @State private var aiProfileID:UUID?
    @State private var voiceProfileID:UUID?
    @State private var aiProfileName = ""
    @State private var voiceProfileName = ""
    @State private var deleteAI = false
    @State private var deleteVoice = false
    @State private var voiceDrafts: [VoiceProvider:VoiceConfiguration] = [:]
    @State private var draft: AIConfiguration
    @State private var saveStatus = ""
    @State private var availableModels: [String] = []
    @State private var modelStatus = ""
    @State private var loadingModels = false
    @State private var refreshCount = 0
    @State private var modelPickerOpen = false
    private struct DiscoveryIdentity: Hashable { let endpoint:String; let key:String; let refresh:Int }
    private var discoveryIdentity: DiscoveryIdentity { DiscoveryIdentity(endpoint:draft.endpoint,key:draft.apiKey,refresh:refreshCount) }
    @AppStorage("aiShareTaste") private var shareTaste = false
    @Environment(\.dismiss) private var dismiss
    init(chat: DJChatModel,voice: DJVoice) {
        self.chat=chat; self.voice=voice
        _draft=State(initialValue:chat.configuration);_voiceDraft=State(initialValue:voice.configuration)
        _aiProfileID=State(initialValue:chat.activeProfileID);_voiceProfileID=State(initialValue:voice.activeProfileID)
        _aiProfileName=State(initialValue:chat.profiles.first(where:{$0.id==chat.activeProfileID})?.name ?? "")
        _voiceProfileName=State(initialValue:voice.profiles.first(where:{$0.id==voice.activeProfileID})?.name ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("已保存的 AI 配置",selection:Binding(get:{aiProfileID},set:{ id in
                        guard let id else { newAIProfile(); return }
                        do { try chat.activateProfile(id); loadAIProfile(); saveStatus="已切换 AI 配置。" }
                        catch { saveStatus=error.localizedDescription }
                    })) {
                        Text("新配置（未保存）").tag(nil as UUID?)
                        ForEach(chat.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    HStack {
                        Button("新增 AI 配置") { newAIProfile() }
                        if aiProfileID != nil { Button("删除此 AI 配置",role:.destructive) { deleteAI=true } }
                    }
                    TextField("AI 配置名称",text:$aiProfileName)
                } header: { Text("AI 配置") } footer: { Text("选择已保存配置会立即切换；下方编辑后点击保存并使用。新增配置不会覆盖已有配置。") }
                .disabled(chat.busy || chat.testing)
                Section {
                    TextField("接口地址（HTTPS 或本机地址）",text:$draft.endpoint)
                        .accessibilityLabel("模型接口地址")
                        .textContentType(.URL).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    SecureField("API Key（本机免认证模型可留空）",text:$draft.apiKey)
                        .autocorrectionDisabled()
                } header: { Text("模型连接") } footer: {
                    Text("支持 Chat Completions 兼容接口。地址填到 /v1，或完整的 /chat/completions；Key 仅保存在此设备的系统钥匙串。")
                }.disabled(chat.busy || chat.testing)
                Section {
                    Button { refreshCount += 1 } label: {
                        HStack { Text(loadingModels ? "正在获取模型…" : "刷新模型列表"); Spacer(); if loadingModels { ProgressView().controlSize(.small) } else { Image(systemName:"arrow.clockwise") } }
                    }.disabled(loadingModels || chat.busy || chat.testing)
                    if !availableModels.isEmpty {
                        Button { modelPickerOpen=true } label: {
                            HStack { Text("选择模型"); Spacer(); Text(draft.model.isEmpty ? "\(availableModels.count) 个可选模型" : draft.model).foregroundStyle(.secondary).lineLimit(1); Image(systemName:"chevron.right").font(.caption) }
                        }.disabled(chat.busy || chat.testing)
                    }
                    TextField("模型名称（可手动填写）",text:$draft.model).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .disabled(chat.busy || chat.testing)
                    if !modelStatus.isEmpty { Text(modelStatus).font(.caption).foregroundStyle(.secondary) }
                } header: { Text("选择模型") } footer: {
                    Text("填写地址与 Key 后自动获取。列表由服务返回，可能包含非聊天模型；选好后可测试是否支持文字对话。不支持列表时仍可手动填写。")
                }
                Section {
                    Picker("已保存的声音配置",selection:Binding(get:{voiceProfileID},set:{ id in
                        guard let id else { newVoiceProfile(); return }
                        do { try voice.activateProfile(id);loadVoiceProfile();voiceStatus="已切换 DJ 声音。" }
                        catch { voiceStatus=error.localizedDescription }
                    })) {
                        Text("新配置（未保存）").tag(nil as UUID?)
                        ForEach(voice.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    HStack {
                        Button("新增声音配置") { newVoiceProfile() }
                        if voiceProfileID != nil { Button("删除此声音配置",role:.destructive) { deleteVoice=true } }
                    }
                    TextField("声音配置名称",text:$voiceProfileName)
                    Picker("声音服务",selection:Binding(get:{ voiceDraft.provider },set:{ provider in
                        voiceDrafts[voiceDraft.provider] = voiceDraft
                        voiceDraft = voiceDrafts[provider] ?? voice.configuration(for:provider)
                        voiceStatus = ""; voice.clearTestStatus()
                    })) { ForEach(VoiceProvider.allCases) { Text($0.title).tag($0) } }
                    SecureField("API Key · " + voiceDraft.provider.title,text:$voiceDraft.apiKey).autocorrectionDisabled()
                    TextField("音色 ID",text:$voiceDraft.voiceID).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Text(voiceDraft.provider.voiceHint).font(.caption).foregroundStyle(.secondary)
                    TextField("语音模型",text:$voiceDraft.model).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    HStack {
                        Button("保存并使用声音配置") {
                            do { try voice.saveProfile(voiceDraft,name:voiceProfileName,id:voiceProfileID);loadVoiceProfile(); voiceStatus="已保存并使用这套声音配置。" } catch { voiceStatus=error.localizedDescription }
                        }
                        Button(voice.preparing ? "正在试听…" : "试听") { voiceStatus=""; voice.test(voiceDraft) }.disabled(voice.preparing || !voiceDraft.ready)
                    }
                    if !voiceStatus.isEmpty { Text(voiceStatus).font(.callout) }
                    if !voice.testStatus.isEmpty { Text(voice.testStatus).font(.callout) }
                } header: { Text("DJ 声音") } footer: {
                    Text("口播文字会发送到所选声音服务，消耗对应账户额度。国内／国际版的 Key、音色和模型分别保存；音色 ID 请从对应平台复制。Key 仅存此设备钥匙串，音频缓存在本机。未配置或失败时使用系统声音。MiniMax 字幕按音频时长近似同步；语音输入仍使用 ElevenLabs 或系统识别。")
                }
                Section {
                    Toggle("聊天时附带音乐偏好",isOn:$shareTaste)
                } footer: {
                    Text("发送聊天时，会向上述服务发送最近最多 12 条消息（合计最多 6,000 字）和当前歌曲资料。开启后另附最多 1,200 字音乐偏好；不会上传整份歌单。聊天记录仅保存在本机，可在聊天页清空。")
                }
                Section {
                    Button("保存并使用 AI 配置") {
                        do { try chat.saveProfile(draft,name:aiProfileName,id:aiProfileID);loadAIProfile(); saveStatus="已保存并使用这套 AI 配置。" }
                        catch { saveStatus=error.localizedDescription }
                    }.disabled(chat.busy || chat.testing)
                    Button { saveStatus=""; chat.test(draft) } label: {
                        HStack { Text(chat.testing ? "正在测试…" : "测试连接"); if chat.testing { Spacer(); ProgressView().controlSize(.small) } }
                    }.disabled(chat.busy || chat.testing)
                    if chat.testing { Button("停止测试") { chat.stop() } }
                    if !saveStatus.isEmpty { Text(saveStatus).font(.callout).textSelection(.enabled) }
                    if !chat.connectionStatus.isEmpty && aiProfileID == chat.activeProfileID { Text(chat.connectionStatus).font(.callout).textSelection(.enabled) }
                } footer: { Text("测试会向所填服务发送一条简短请求，可能消耗少量额度；不会附带聊天或歌单。测试成功后仍需保存连接。") }
            }.formStyle(.grouped).navigationTitle("AI 模型")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
                #if os(macOS)
                .frame(minWidth:560,minHeight:610)
                #endif
        }.tint(.primary)
            .task(id:discoveryIdentity) { await discoverModels(identity:discoveryIdentity) }
            .confirmationDialog("删除这套 AI 配置？",isPresented:$deleteAI,titleVisibility:.visible) {
                Button("删除配置",role:.destructive) { if let id=aiProfileID { do { try chat.deleteProfile(id);loadAIProfile();saveStatus="已删除。" } catch {saveStatus=error.localizedDescription} } }
            } message: { Text("删除后会切换到另一套配置；如果没有其他配置，将断开 AI 连接。") }
            .confirmationDialog("删除这套声音配置？",isPresented:$deleteVoice,titleVisibility:.visible) {
                Button("删除配置",role:.destructive) { if let id=voiceProfileID { do { try voice.deleteProfile(id);loadVoiceProfile();voiceStatus="已删除。" } catch {voiceStatus=error.localizedDescription} } }
            } message: { Text("删除后会切换到另一套配置；如果没有其他配置，将使用系统声音。") }
            .sheet(isPresented:$modelPickerOpen) { ModelChoiceView(models:availableModels,selection:$draft.model) }
    }
    private func newAIProfile() { aiProfileID=nil;aiProfileName="";draft=AIConfiguration();saveStatus="填写后点击保存并使用。" }
    private func newVoiceProfile() { voiceProfileID=nil;voiceProfileName="";voiceDraft=VoiceConfiguration();voiceDrafts=[:];voiceStatus="填写后点击保存并使用。";voice.clearTestStatus() }
    private func loadAIProfile() {
        aiProfileID=chat.activeProfileID;aiProfileName=chat.profiles.first(where:{$0.id==aiProfileID})?.name ?? "";draft=chat.configuration
    }
    private func loadVoiceProfile() {
        voiceProfileID=voice.activeProfileID;voiceProfileName=voice.profiles.first(where:{$0.id==voiceProfileID})?.name ?? "";voiceDraft=voice.configuration;voiceDrafts=[:]
    }
    @MainActor private func discoverModels(identity: DiscoveryIdentity) async {
        availableModels=[]; modelStatus=""; loadingModels=false
        let configuration=AIConfiguration(endpoint:identity.endpoint,apiKey:identity.key)
        guard let url=try? configuration.modelsURL else { return }
        let host=(url.host ?? "").trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
        guard !identity.key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || ["localhost","127.0.0.1","::1"].contains(host) else {
            modelStatus="填好 Key 后将自动获取，也可以手动填写模型名称。"; return
        }
        do {
            try await Task.sleep(nanoseconds:800_000_000)
            guard identity == discoveryIdentity else { return }
            loadingModels=true
            let models=try await AIClient().models(configuration:configuration)
            try Task.checkCancellation()
            guard identity == discoveryIdentity else { return }
            availableModels=models; modelStatus="已获取 \(models.count) 个模型，请点「选择模型」。"
        } catch {
            guard !Task.isCancelled, identity == discoveryIdentity else { return }
            if let known=error as? AIError { modelStatus=known.localizedDescription }
            else if (error as? URLError)?.code == .timedOut { modelStatus="获取超时，请刷新重试，或手动填写模型名称。" }
            else { modelStatus="暂时无法获取模型，请检查连接后刷新，或手动填写模型名称。" }
        }
        if identity == discoveryIdentity { loadingModels=false }
    }
}

private struct ModelChoiceView: View {
    let models: [String]
    @Binding var selection: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var filtered: [String] { search.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty { Text("没有找到匹配的模型").foregroundStyle(.secondary) }
                ForEach(filtered,id:\.self) { model in
                    Button { selection=model; dismiss() } label: {
                        HStack { Text(model).foregroundStyle(.primary); Spacer(); if selection == model { Image(systemName:"checkmark").foregroundStyle(.primary) } }.frame(minHeight:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == model ? .isSelected : [])
                }
            }.searchable(text:$search,prompt:"搜索模型名称").navigationTitle("选择模型")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
                #if os(macOS)
                .frame(minWidth:500,minHeight:550)
                #endif
        }.tint(.primary)
    }
}
