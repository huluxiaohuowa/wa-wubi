import SwiftUI

struct CloudPredictionSettings: View {
    @State private var config = CloudPredictionConfiguration.current
    @State private var keyOrigin = CloudPredictionConfiguration.current.credentialOrigin
    @State private var key = CloudPredictionConfiguration.current.credentialOrigin
        .map { CloudPredictionKeychain.read(origin: $0) } ?? ""
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用云联想", isOn: $config.enabled)
            Text("默认关闭。启用后，停顿时可能将本次拼音或五笔候选，以及本输入框内刚由 WA 五笔上屏的文字发给你填写的服务商。问字和翻译仅发送手动提交的文字。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("API 基础地址（OpenAI 兼容）", text: $config.baseURL)
            TextField("模型 ID", text: $config.model)
            SecureField("API Key（服务商需要时填写）", text: $key)
            TextField("翻译目标语言", text: $config.translationLanguage)
            Toggle("为语言学习提供云端译词", isOn: Binding(
                get: { config.showsGlosses ?? false }, set: { config.showsGlosses = $0 }
            ))
            .disabled(!config.enabled)
            Text("在「外观」开启语言学习后，缺少本地释义的候选会发送给服务商，译成上面设置的目标语言。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("保存设置", action: save)
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            Text("问字和翻译入口在输入法菜单。API Key 存在本机钥匙串。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onChange(of: config.credentialOrigin) { origin in
            keyOrigin = origin
            key = origin.map { CloudPredictionKeychain.read(origin: $0) } ?? ""
        }
    }

    private func save() {
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.translationLanguage = config.translationLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let savedKey = keyOrigin == config.credentialOrigin ? key :
                config.credentialOrigin.map { CloudPredictionKeychain.read(origin: $0) } ?? ""
            try config.save(key: savedKey)
            status = "已保存"
        } catch {
            status = error.localizedDescription
        }
    }
}
