import Foundation

/// AI 润色服务 — 对语音识别结果做纠错、断句、标点优化
actor PolishService {

    /// 在风格 prompt 末尾追加词典提示，让模型按上下文判断是否替换
    /// workingLanguages 注入到 prompt 头部影响多语言混输 / 专名 / 语气判断
    static func assemblePrompt(style: OutputStyle, vocabTerms: [String], workingLanguages: [String] = []) -> String {
        var sections: [String] = [OutputStyle.globalContract]
        if !workingLanguages.isEmpty {
            let langList = workingLanguages.joined(separator: ", ")
            sections.append("用户的常用工作语言：\(langList)。处理多语言混输时，按上下文判断专名拼写、语气、行文习惯。")
        }
        sections.append(style.prompt)
        let cleaned = vocabTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            let list = cleaned.prefix(50).map { "- \($0)" }.joined(separator: "\n")
            sections.append("专有名词参考（按上下文判断是否替换；不要强行使用）：\n" + list)
        }
        return sections.joined(separator: "\n\n")
    }

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

    func polish(text: String, settings: PolishSettingsSnapshot, style: OutputStyle = .light, vocabTerms: [String] = [], workingLanguages: [String] = []) async throws -> String {
        guard settings.engine != .none else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        let activePrompt = Self.assemblePrompt(style: style, vocabTerms: vocabTerms, workingLanguages: workingLanguages)
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
    func translate(text: String, settings: PolishSettingsSnapshot, targetLang: String, workingLanguages: [String] = []) async throws -> String {
        guard settings.engine != .none else { throw PolishError.invalidConfig("请先配置 AI 引擎") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        var prompt = Self.translationPrompt(targetLang: targetLang)
        if !workingLanguages.isEmpty {
            let langList = workingLanguages.joined(separator: ", ")
            prompt = "User's working languages: \(langList). Use this context to disambiguate proper nouns and tone.\n\n" + prompt
        }
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
            "stream": stream,
            "options": [
                "temperature": 0.2,           // 降低创造性,倾向严格 follow prompt
                "top_p": 0.5,                 // 收敛输出
                "num_ctx": 8192,              // v2 structured prompt 长,2048 会截断
                "num_predict": 2048,          // 输出上限,防失控
                "repeat_penalty": 1.1         // 默认值,显式写出来文档化
            ]
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
            // 4096 = 全系 Claude 模型都支持的输出上限(用户可能手填旧 model,不能开更高)
            "max_tokens": 4096,
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
            // 截断的润色文本不能上屏 —— 抛错走上层"回退原文"路径
            if let stopReason = json["stop_reason"] as? String, stopReason == "max_tokens" {
                throw PolishError.parseError("润色输出超过 max_tokens 被截断")
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
    func polishStream(text: String, settings: PolishSettingsSnapshot, style: OutputStyle = .light, vocabTerms: [String] = [], workingLanguages: [String] = [], onChunk: @Sendable @escaping (String) -> Void) async throws -> String {
        guard settings.engine != .none else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        let activePrompt = Self.assemblePrompt(style: style, vocabTerms: vocabTerms, workingLanguages: workingLanguages)
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
