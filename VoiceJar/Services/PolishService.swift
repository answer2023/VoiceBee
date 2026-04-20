import Foundation

/// AI 润色服务 — 对语音识别结果做纠错、断句、标点优化
actor PolishService {

    /// 即时模式：轻度润色
    static let instantPrompt = """
    你是一个中文语音转文字的后处理助手。用户会给你一段语音识别的原始文本，你需要：
    1. 修正同音字错误（如"以经"→"已经"）
    2. 补充或修正标点符号
    3. 修正中英文混输时的拼写（如识别器可能把中文词听成英文）
    4. 数字和日期用中文习惯表达（如"2024年3月"而非"二零二四年三月"，看上下文选合适的）
    5. 去除口头禅和语气词（嗯、啊、那个、就是说）
    6. 保持原意，不要改写、扩写或总结

    直接输出修正后的文本，不要加任何解释、前缀或引号。
    """

    /// 润色模式：深度整理
    static let structuredPrompt = """
    你是一个中文语音整理助手。用户会口述一段内容，可能逻辑跳跃、有重复、有口头禅。你需要：
    1. 修正同音字和标点符号
    2. 去除口头禅、重复内容、无意义的过渡词
    3. 理清逻辑顺序，让表达更流畅
    4. 如果内容有多个要点，用清晰的分段或分点表达
    5. 保持原意和原有的语气风格，不要过度改写或添加原文没有的内容
    6. 如果原文很短或已经很清晰，只做轻度修正即可

    直接输出整理后的文本，不要加任何解释、前缀或引号。
    """

    /// 翻译 prompt
    static func translationPrompt(targetLang: String) -> String {
        """
        You are a professional translator. Translate the following text to \(targetLang).
        Rules:
        1. Preserve the original formatting, tone, and style
        2. For technical terms, keep the original in parentheses when it helps understanding
        3. Output ONLY the translated text — no explanations, notes, or quotation marks
        """
    }

    func polish(text: String, settings: PolishSettingsSnapshot, structured: Bool = false) async throws -> String {
        guard settings.engine != .none else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        let activePrompt = structured ? Self.structuredPrompt : Self.instantPrompt
        let (request, parseResponse) = try buildRequest(text: text, settings: settings, prompt: activePrompt)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PolishError.networkError("无效的响应")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PolishError.apiError(httpResponse.statusCode, body)
        }

        return try parseResponse(data)
    }

    /// 翻译文本
    func translate(text: String, settings: PolishSettingsSnapshot, targetLang: String) async throws -> String {
        guard settings.engine != .none else { throw PolishError.invalidConfig("请先配置 AI 引擎") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        let prompt = Self.translationPrompt(targetLang: targetLang)
        let (request, parseResponse) = try buildRequest(text: text, settings: settings, prompt: prompt)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PolishError.networkError("无效的响应")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PolishError.apiError(httpResponse.statusCode, body)
        }
        return try parseResponse(data)
    }

    private func buildRequest(text: String, settings: PolishSettingsSnapshot, prompt: String, stream: Bool = false) throws -> (URLRequest, (Data) throws -> String) {
        switch settings.engine {
        case .none:
            fatalError("unreachable")
        case .ollama, .ollamaCloud:
            return try buildOllamaRequest(text: text, settings: settings, prompt: prompt, stream: stream)
        case .claude:
            return try buildClaudeRequest(text: text, settings: settings, prompt: prompt, stream: stream)
        case .deepseek, .gemini, .openaiCompatible:
            return try buildOpenAIRequest(text: text, settings: settings, prompt: prompt, stream: stream)
        }
    }

    // MARK: - Ollama

    private func buildOllamaRequest(text: String, settings: PolishSettingsSnapshot, prompt: String, stream: Bool = false) throws -> (URLRequest, (Data) throws -> String) {
        let baseURL = settings.baseURL.isEmpty ? "http://localhost:11434" : settings.baseURL
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw PolishError.invalidConfig("无效的 Ollama 地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": settings.model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ],
            "stream": stream
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let parse: (Data) throws -> String = { data in
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw PolishError.parseError("无法解析 Ollama 响应")
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (request, parse)
    }

    // MARK: - Claude

    private func buildClaudeRequest(text: String, settings: PolishSettingsSnapshot, prompt: String, stream: Bool = false) throws -> (URLRequest, (Data) throws -> String) {
        guard !settings.apiKey.isEmpty else {
            throw PolishError.invalidConfig("请先设置 Claude API Key")
        }
        let baseURL = settings.baseURL.isEmpty ? "https://api.anthropic.com" : settings.baseURL
        guard let url = URL(string: "\(baseURL)/v1/messages") else {
            throw PolishError.invalidConfig("无效的 Claude API 地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": 1024,
            "system": prompt,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]
        if stream { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let parse: (Data) throws -> String = { data in
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let resultText = first["text"] as? String else {
                throw PolishError.parseError("无法解析 Claude 响应")
            }
            return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (request, parse)
    }

    // MARK: - OpenAI Compatible (DeepSeek / Gemini / Custom)

    private func buildOpenAIRequest(text: String, settings: PolishSettingsSnapshot, prompt: String, stream: Bool = false) throws -> (URLRequest, (Data) throws -> String) {
        guard !settings.apiKey.isEmpty else {
            throw PolishError.invalidConfig("请先设置 API Key")
        }

        let baseURL: String
        switch settings.engine {
        case .deepseek:
            baseURL = settings.baseURL.isEmpty ? "https://api.deepseek.com/v1" : settings.baseURL
        case .gemini:
            baseURL = settings.baseURL.isEmpty ? "https://generativelanguage.googleapis.com/v1beta/openai" : settings.baseURL
        default:
            baseURL = settings.baseURL.isEmpty ? "https://api.openai.com/v1" : settings.baseURL
        }

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw PolishError.invalidConfig("无效的 API 地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": settings.model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ],
            "stream": stream
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let parse: (Data) throws -> String = { data in
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw PolishError.parseError("无法解析 API 响应")
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (request, parse)
    }

    // MARK: - Streaming

    /// 流式润色 — 逐 token 回调，首字 ~0.5s 出现
    func polishStream(text: String, settings: PolishSettingsSnapshot, structured: Bool = false, onChunk: @Sendable @escaping (String) -> Void) async throws -> String {
        guard settings.engine != .none else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        let activePrompt = structured ? Self.structuredPrompt : Self.instantPrompt
        let (request, _) = try buildRequest(text: text, settings: settings, prompt: activePrompt, stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PolishError.networkError("无效的响应")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw PolishError.apiError(httpResponse.statusCode, "流式请求失败")
        }

        var accumulated = ""
        let engine = settings.engine

        for try await line in bytes.lines {
            if let token = Self.parseStreamLine(line, engine: engine) {
                accumulated += token
                onChunk(accumulated)
            }
        }

        let result = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text : result
    }

    // MARK: - SSE Parsing

    private static func parseStreamLine(_ line: String, engine: PolishEngine) -> String? {
        switch engine {
        case .ollama, .ollamaCloud:
            return parseOllamaChunk(line)
        case .claude:
            return parseClaudeChunk(line)
        case .deepseek, .gemini, .openaiCompatible:
            return parseOpenAIChunk(line)
        case .none:
            return nil
        }
    }

    /// Ollama: 每行一个 JSON {"message":{"content":"token"},"done":false}
    private static func parseOllamaChunk(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else { return nil }
        return content
    }

    /// Claude SSE: data: {"type":"content_block_delta","delta":{"text":"token"}}
    private static func parseClaudeChunk(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonStr = String(line.dropFirst(6))
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String else { return nil }
        return text
    }

    /// OpenAI SSE: data: {"choices":[{"delta":{"content":"token"}}]}
    private static func parseOpenAIChunk(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonStr = String(line.dropFirst(6))
        guard jsonStr != "[DONE]",
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }
}

// MARK: - Error

enum PolishError: LocalizedError {
    case invalidConfig(String)
    case networkError(String)
    case apiError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let msg): return "配置错误: \(msg)"
        case .networkError(let msg): return "网络错误: \(msg)"
        case .apiError(let code, let body): return "API 错误(\(code)): \(body.prefix(200))"
        case .parseError(let msg): return "解析错误: \(msg)"
        }
    }
}
