import SwiftUI

struct MobileCloudSettings: View {
    @State private var config = MobileCloudPrediction.current
    @State private var key = MobileCloudPrediction.current.origin.map(MobileCloudPrediction.key) ?? ""
    @State private var keyOrigin = MobileCloudPrediction.current.origin
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                Toggle("启用云联想", isOn: $config.enabled)
                TextField("API 基础地址（OpenAI 兼容）", text: $config.baseURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型 ID", text: $config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key（如服务商需要）", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存设置", action: save)
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("默认关闭。系统键盘需要「允许完全访问」。开启后，输入停顿时，本次拼音或五笔候选及本输入框内刚由 WA 五笔上屏的少量文字会直接发送给你配置的服务商。API Key 保存在本机钥匙串。")
            }
        }
        .navigationTitle("云联想")
        .onChange(of: config.origin) { _, origin in
            guard origin != keyOrigin else { return }
            keyOrigin = origin
            key = origin.map(MobileCloudPrediction.key) ?? ""
        }
    }

    private func save() {
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedKey = keyOrigin == config.origin ? key.trimmingCharacters(in: .whitespacesAndNewlines) :
            config.origin.map(MobileCloudPrediction.key) ?? ""
        do {
            try config.save(key: savedKey)
            status = "已保存"
        } catch {
            status = "无法保存云联想设置。请检查服务地址、模型和钥匙串权限。"
        }
    }
}
