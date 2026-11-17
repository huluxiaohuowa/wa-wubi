import AppKit
import AVFoundation
import Speech
import Security

enum SpeechProvider: String, CaseIterable, Identifiable, Codable {
    case apple, openAI, groq, siliconFlow, custom
    var id: Self { self }
    var label: String {
        switch self {
        case .apple: return "Apple 语音识别"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .siliconFlow: return "硅基流动"
        case .custom: return "自定义兼容接口"
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
    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        case .siliconFlow: return "FunAudioLLM/SenseVoiceSmall"
        default: return ""
        }
    }
}

struct SpeechConfiguration: Codable, Equatable {
    var enabled = false
    var provider = SpeechProvider.apple
    var locale = "zh-CN"
    var endpoint = ""
    var model = ""
    var onDeviceOnly = false

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "speechConfiguration"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "speechConfiguration")
    }
}

enum SpeechError: LocalizedError {
    case microphone, permission, unavailable, configuration, start, response(Int), noText, keychain, timeout
    var errorDescription: String? {
        switch self {
        case .microphone: return "请在系统设置中授权麦克风。"
        case .permission: return "请在系统设置中授权 Apple 语音识别。"
        case .unavailable: return "当前语言的 Apple 识别不可用。"
        case .configuration: return "请填写 HTTPS 转写接口、模型和 API 密钥。"
        case .start: return "无法开始录音。"
        case .response(let status): return "语音服务请求失败（HTTP \(status)）。"
        case .noText: return "未识别到语音。"
        case .keychain: return "无法更新本机钥匙串。"
        case .timeout: return "语音识别超时。"
        }
    }
}

enum SpeechKeychain {
    static let service = "top.fuluwa.inputmethod.WAWubi.asr"

    static func key(for provider: SpeechProvider) -> String {
        var query = selector(provider)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String, for provider: SpeechProvider) throws {
        var query = selector(provider)
        if key.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw SpeechError.keychain }
            return
        }
        let data = Data(key.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw SpeechError.keychain }
        query[kSecValueData as String] = data
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SpeechError.keychain }
    }

    private static func selector(_ provider: SpeechProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

final class SpeechCapture {
    private var recorder: AVAudioRecorder?
    private var recognition: SFSpeechRecognitionTask?
    private var network: URLSessionDataTask?
    private var pending: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var file: URL?
    private var session = UUID()
    private var configuration = SpeechConfiguration()
    private var key = ""
    private var didFinish: ((Result<String, Error>) -> Void)?
    private var phase: ((String) -> Void)?

    func begin(_ configuration: SpeechConfiguration, phase: @escaping (String) -> Void,
               completed: @escaping (Result<String, Error>) -> Void) {
        cancel()
        self.configuration = configuration
        self.didFinish = completed
        self.phase = phase
        let id = session
        let delay = DispatchWorkItem { [weak self] in self?.authorize(id) }
        pending = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: delay)
    }

    func release() {
        pending?.cancel()
        pending = nil
        guard let recorder, let file else { cancel(); return }
        let duration = recorder.currentTime
        timeout?.cancel()
        recorder.stop()
        self.recorder = nil
        guard duration >= 0.15 else { cancel(); return }
        phase?("正在转写…")
        let id = session
        let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(SpeechError.timeout), id: id) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        if configuration.provider == .apple { recognize(file, id: id) }
        else { send(file, id: id) }
    }

    func cancel() {
        session = UUID()
        pending?.cancel()
        pending = nil
        timeout?.cancel()
        timeout = nil
        recorder?.stop()
        recorder = nil
        recognition?.cancel()
        recognition = nil
        network?.cancel()
        network = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        didFinish = nil
        phase = nil
        key = ""
    }

    private func authorize(_ id: UUID) {
        guard id == session else { return }
        if configuration.provider != .apple {
            key = SpeechKeychain.key(for: configuration.provider)
            guard let endpoint = speechURL(), endpoint.scheme == "https", !key.isEmpty,
                  !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty else {
                finish(.failure(SpeechError.configuration), id: id)
                return
            }
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.session == id else { return }
                guard granted else { self.finish(.failure(SpeechError.microphone), id: id); return }
                if self.configuration.provider != .apple { self.record(id); return }
                SFSpeechRecognizer.requestAuthorization { [weak self] status in
                    DispatchQueue.main.async {
                        guard let self, self.session == id else { return }
                        if status == .authorized { self.record(id) }
                        else { self.finish(.failure(SpeechError.permission), id: id) }
                    }
                }
            }
        }
    }

    private func record(_ id: UUID) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wawubi-\(UUID().uuidString).wav")
        file = url
        do {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
            ])
            guard recorder.record(forDuration: 45) else { throw SpeechError.start }
            self.recorder = recorder
            phase?("正在聆听 · 松手转写")
            let limit = DispatchWorkItem { [weak self] in
                guard let self, self.session == id, self.recorder != nil else { return }
                self.finish(.failure(SpeechError.timeout), id: id)
            }
            timeout = limit
            DispatchQueue.main.asyncAfter(deadline: .now() + 44, execute: limit)
        } catch { finish(.failure(SpeechError.start), id: id) }
    }

    private func recognize(_ url: URL, id: UUID) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: configuration.locale)),
              recognizer.isAvailable,
              !configuration.onDeviceOnly || recognizer.supportsOnDeviceRecognition else {
            finish(.failure(SpeechError.unavailable), id: id)
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result, result.isFinal { self?.finish(.success(result.bestTranscription.formattedString), id: id) }
                else if error != nil { self?.finish(.failure(SpeechError.unavailable), id: id) }
            }
        }
    }

    private func speechURL() -> URL? {
        let text = configuration.provider == .custom ? configuration.endpoint : configuration.provider.endpoint
        guard let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func send(_ file: URL, id: UUID) {
        guard let endpoint = speechURL(), let audio = try? Data(contentsOf: file), !audio.isEmpty else {
            finish(.failure(SpeechError.configuration), id: id)
            return
        }
        let boundary = "WAWubi-\(UUID().uuidString)"
        var body = Data()
        var fields = [("model", configuration.model)]
        if configuration.provider != .siliconFlow { fields.append(("response_format", "json")) }
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint, timeoutInterval: 40)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        struct Transcript: Decodable { let text: String }
        network = URLSession.shared.uploadTask(with: request, from: body) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<String, Error>
            if (200..<300).contains(status), let data, let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
                result = .success(transcript.text)
            } else { result = .failure(SpeechError.response(status)) }
            DispatchQueue.main.async { self?.finish(result, id: id) }
        }
        network?.resume()
    }

    private func finish(_ result: Result<String, Error>, id: UUID) {
        guard id == session else { return }
        let completed = didFinish
        cancel()
        switch result {
        case .success(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            completed?(clean.isEmpty ? .failure(SpeechError.noText) : .success(clean))
        case .failure: completed?(result)
        }
    }
}
