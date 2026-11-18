import AVFoundation
import Security
import Speech
import SwiftUI
import WubiCore

enum VoiceService: String, CaseIterable, Identifiable {
    case apple, openAI, groq, siliconFlow, custom
    var id: Self { self }
    var label: String {
        switch self {
        case .apple: return "Apple 语音识别"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .siliconFlow: return "硅基流动"
        case .custom: return "自定义接口"
        }
    }
    var endpoint: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1/audio/transcriptions"
        case .groq: return "https://api.groq.com/openai/v1/audio/transcriptions"
        case .siliconFlow: return "https://api.siliconflow.cn/v1/audio/transcriptions"
        default: return ""
        }
    }
    var suggestedModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .siliconFlow: return "FunAudioLLM/SenseVoiceSmall"
        default: return ""
        }
    }
}

struct MobileVoiceProfile {
    private var json: [String: Any]

    init(_ preferences: Preferences) {
        json = preferences.speechConfiguration.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    var enabled: Bool { get { json["enabled"] as? Bool ?? false } set { json["enabled"] = newValue } }
    var service: VoiceService {
        get { VoiceService(rawValue: json["provider"] as? String ?? "") ?? .apple }
        set { json["provider"] = newValue.rawValue }
    }
    var locale: String { get { json["locale"] as? String ?? "zh-CN" } set { json["locale"] = newValue } }
    var localOnly: Bool { get { json["onDeviceOnly"] as? Bool ?? false } set { json["onDeviceOnly"] = newValue } }
    var endpoint: String { get { json["endpoint"] as? String ?? "" } set { json["endpoint"] = newValue } }
    var model: String { get { json["model"] as? String ?? "" } set { json["model"] = newValue } }

    func encoded() -> Data? {
        let defaults: [String: Any] = ["enabled": false, "provider": VoiceService.apple.rawValue,
                                       "locale": "zh-CN", "onDeviceOnly": false, "endpoint": "", "model": ""]
        return try? JSONSerialization.data(withJSONObject: defaults.merging(json) { _, value in value },
                                           options: [.sortedKeys])
    }
}

@MainActor final class MobileVoice: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var message = ""
    var result: (String) -> Void = { _ in }
    var profile: () -> MobileVoiceProfile = { MobileVoiceProfile(Preferences()) }
    private var activeProfile: MobileVoiceProfile?
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var held = false

    func hold(_ down: Bool) {
        guard held != down, !down || profile().enabled else { return }
        held = down
        if down { Task { await start() } } else { finish() }
    }

    private func start() async {
        guard !recording, await AVAudioApplication.requestRecordPermission(), held else {
            if held { message = "请允许 WA 五笔使用麦克风。" }
            return
        }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement)
            try audio.setActive(true)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            guard recorder.record(forDuration: 90) else { throw CocoaError(.fileWriteUnknown) }
            self.file = file
            activeProfile = profile()
            self.recorder = recorder
            message = "松手结束录音"
            recording = true
        } catch {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            message = "录音未启动，请检查麦克风。"
        }
    }

    private func finish() {
        guard recording, let file, let configuration = activeProfile else { return }
        recorder?.stop()
        recorder = nil
        self.file = nil
        activeProfile = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        message = "正在转写…"
        Task {
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let text = configuration.service == .apple
                    ? try await apple(file, configuration: configuration)
                    : try await remote(file, configuration: configuration)
                if !text.isEmpty { result(text) }
                message = text.isEmpty ? "没有识别到语音。" : ""
            } catch { message = "转写失败。请检查语音授权或服务配置。" }
        }
    }

    private func apple(_ url: URL, configuration: MobileVoiceProfile) async throws -> String {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: configuration.locale)),
              recognizer.isAvailable else { throw CocoaError(.userCancelled) }
        let once = SpeechResult()
        let request = SFSpeechURLRecognitionRequest(url: url)
        let onDevice = configuration.localOnly
        if onDevice && !recognizer.supportsOnDeviceRecognition { throw CocoaError(.featureUnsupported) }
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            once.continuation = continuation
            once.task = recognizer.recognitionTask(with: request) { result, error in
                if let error { once.complete(.failure(error)) }
                else if let result, result.isFinal { once.complete(.success(result.bestTranscription.formattedString)) }
            }
        }
    }

    private func remote(_ file: URL, configuration: MobileVoiceProfile) async throws -> String {
        let service = configuration.service
        let endpoint = service == .custom ? configuration.endpoint : service.endpoint
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil else { throw URLError(.badURL) }
        let token = Self.token(for: service)
        guard service == .custom || !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let boundary = UUID().uuidString
        var payload = Data()
        payload.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model.isEmpty ? service.suggestedModel : model)\r\n".utf8))
        payload.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))
        payload.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        payload.append(try Data(contentsOf: file))
        payload.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        if !token.isEmpty { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        req.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct Transcription: Decodable { let text: String }
        return try JSONDecoder().decode(Transcription.self, from: data).text
    }

    static func token(for service: VoiceService) -> String {
        var properties = keychain(for: service)
        properties[kSecMatchLimit as String] = kSecMatchLimitOne
        properties[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(properties as CFDictionary, &item) == errSecSuccess,
              let bytes = item as? Data else { return "" }
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    static func saveToken(_ token: String, for service: VoiceService) -> Bool {
        let properties = keychain(for: service)
        if token.isEmpty {
            let status = SecItemDelete(properties as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(properties as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            return SecItemAdd(properties.merging(attributes) { _, value in value } as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private static func keychain(for service: VoiceService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "top.fuluwa.WAWubi.mobile.voice",
         kSecAttrAccount as String: service.rawValue]
    }
}

private final class SpeechResult: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<String, Error>?
    var task: SFSpeechRecognitionTask?

    func complete(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
