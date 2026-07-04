import XCTest
@testable import VoiceBee

/// SSE 流式解析单元测试 — PolishService.parseStreamLine / parseOllamaChunk / parseClaudeChunk / parseOpenAIChunk.
///
/// 覆盖范围:
/// - A 节:Ollama chunk 格式(每行 bare JSON,message.content + done flag)
/// - B 节:Claude SSE(data: 前缀 / content_block_delta / **in-stream error 帧抛错**)
/// - C 节:OpenAI SSE(data: 前缀 / [DONE] / **in-data error + 无前缀顶层 error 抛错**)
/// - D 节:parseStreamLine 引擎分发
///
/// 其中 error 帧抛 PolishError.apiError 是本周新修的行为(200 之后网关仍可能推
/// overloaded_error / quota 错误帧,不能当空 delta 吞掉),B/C 节的 throw 测试是回归保护。
final class PolishStreamParserTests: XCTestCase {

    // MARK: - A 节:Ollama chunk(bare JSON,非 SSE)

    func testOllamaValidChunkYieldsToken() {
        let line = #"{"message":{"content":"你好"},"done":false}"#
        XCTAssertEqual(PolishService.parseOllamaChunk(line), "你好")
    }

    func testOllamaFinalDoneChunkYieldsNil() {
        // 结束帧 content 为空 → 过滤为 nil,不产出空 token
        let line = #"{"message":{"content":""},"done":true}"#
        XCTAssertNil(PolishService.parseOllamaChunk(line))
    }

    func testOllamaMissingMessageYieldsNil() {
        XCTAssertNil(PolishService.parseOllamaChunk(#"{"done":true}"#))
    }

    func testOllamaMalformedJSONYieldsNil() {
        XCTAssertNil(PolishService.parseOllamaChunk(#"{"message":{"content":"#))
    }

    func testOllamaEmptyStringYieldsNil() {
        XCTAssertNil(PolishService.parseOllamaChunk(""))
    }

    func testOllamaSSEStyleLineYieldsNil() {
        // Ollama 不是 SSE — 带 data: 前缀的行不是合法 bare JSON,应返回 nil
        XCTAssertNil(PolishService.parseOllamaChunk(#"data: {"message":{"content":"x"},"done":false}"#))
    }

    // MARK: - B 节:Claude SSE — content_block_delta

    func testClaudeContentBlockDeltaYieldsToken() throws {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"润色"}}"#
        XCTAssertEqual(try PolishService.parseClaudeChunk(line), "润色")
    }

    func testClaudeNonDataLinesYieldNil() throws {
        // SSE event 行 / 空行都不是 data 行 → nil
        XCTAssertNil(try PolishService.parseClaudeChunk("event: content_block_delta"))
        XCTAssertNil(try PolishService.parseClaudeChunk(""))
    }

    func testClaudeDoneMarkerYieldsNil() throws {
        // Claude 协议本身不发 [DONE],但网关可能混发 — "[DONE]" 不是 JSON,应安静返回 nil
        XCTAssertNil(try PolishService.parseClaudeChunk("data: [DONE]"))
    }

    func testClaudeMalformedJSONYieldsNil() throws {
        XCTAssertNil(try PolishService.parseClaudeChunk(#"data: {"type":"content_block_delta","del"#))
    }

    func testClaudeOtherEventTypesYieldNil() throws {
        // 非 delta 的正常事件帧(message_start / content_block_stop / ping)→ nil,不抛错
        XCTAssertNil(try PolishService.parseClaudeChunk(#"data: {"type":"message_start","message":{"id":"msg_1"}}"#))
        XCTAssertNil(try PolishService.parseClaudeChunk(#"data: {"type":"content_block_stop","index":0}"#))
        XCTAssertNil(try PolishService.parseClaudeChunk(#"data: {"type":"ping"}"#))
    }

    // MARK: - B 节:Claude in-stream error 帧 **抛错**(本周修复,回归保护)

    func testClaudeErrorFrameThrowsApiError() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertThrowsError(try PolishService.parseClaudeChunk(line)) { error in
            guard case PolishError.apiError(let code, let message) = error else {
                return XCTFail("应抛 PolishError.apiError,实际是 \(error)")
            }
            XCTAssertEqual(code, 200)
            XCTAssertEqual(message, "Overloaded")
        }
    }

    func testClaudeErrorFrameWithoutMessageFallsBackToRawJSON() {
        // error 帧缺 error.message → fallback 带上原始 JSON,便于排障
        let line = #"data: {"type":"error"}"#
        XCTAssertThrowsError(try PolishService.parseClaudeChunk(line)) { error in
            guard case PolishError.apiError(let code, let message) = error else {
                return XCTFail("应抛 PolishError.apiError,实际是 \(error)")
            }
            XCTAssertEqual(code, 200)
            XCTAssertEqual(message, #"{"type":"error"}"#)
        }
    }

    // MARK: - C 节:OpenAI SSE — delta.content

    func testOpenAIDeltaContentYieldsToken() throws {
        let line = #"data: {"choices":[{"delta":{"content":"token"},"index":0}]}"#
        XCTAssertEqual(try PolishService.parseOpenAIChunk(line), "token")
    }

    func testOpenAIDoneMarkerYieldsNil() throws {
        XCTAssertNil(try PolishService.parseOpenAIChunk("data: [DONE]"))
    }

    func testOpenAIMalformedJSONYieldsNil() throws {
        XCTAssertNil(try PolishService.parseOpenAIChunk(#"data: {"choices":[{"del"#))
    }

    func testOpenAIEmptyStringYieldsNil() throws {
        XCTAssertNil(try PolishService.parseOpenAIChunk(""))
    }

    func testOpenAICommentLineYieldsNil() throws {
        // SSE keep-alive 注释行(": keep-alive")不是 data 行也不是 JSON → nil,不抛错
        XCTAssertNil(try PolishService.parseOpenAIChunk(": keep-alive"))
    }

    func testOpenAIRoleOnlyDeltaYieldsNil() throws {
        // 流首帧只有 role 没有 content → nil
        let line = #"data: {"choices":[{"delta":{"role":"assistant"},"index":0}]}"#
        XCTAssertNil(try PolishService.parseOpenAIChunk(line))
    }

    // MARK: - C 节:OpenAI in-data / 无前缀 error **抛错**(本周修复,回归保护)

    func testOpenAIInDataErrorThrowsApiError() {
        let line = #"data: {"error":{"message":"quota exceeded","type":"insufficient_quota"}}"#
        XCTAssertThrowsError(try PolishService.parseOpenAIChunk(line)) { error in
            guard case PolishError.apiError(let code, let message) = error else {
                return XCTFail("应抛 PolishError.apiError,实际是 \(error)")
            }
            XCTAssertEqual(code, 200)
            XCTAssertEqual(message, "quota exceeded")
        }
    }

    func testOpenAITopLevelErrorWithoutPrefixThrowsApiError() {
        // 部分兼容网关 200 后直接推顶层 error JSON(无 data: 前缀)
        let line = #"{"error":{"message":"Invalid API key","code":"invalid_api_key"}}"#
        XCTAssertThrowsError(try PolishService.parseOpenAIChunk(line)) { error in
            guard case PolishError.apiError(let code, let message) = error else {
                return XCTFail("应抛 PolishError.apiError,实际是 \(error)")
            }
            XCTAssertEqual(code, 200)
            XCTAssertEqual(message, "Invalid API key")
        }
    }

    func testOpenAIInDataErrorWithoutMessageFallsBackToRawJSON() {
        // error object 缺 message → fallback 带上原始 JSON
        let line = #"data: {"error":{"code":"unknown"}}"#
        XCTAssertThrowsError(try PolishService.parseOpenAIChunk(line)) { error in
            guard case PolishError.apiError(let code, let message) = error else {
                return XCTFail("应抛 PolishError.apiError,实际是 \(error)")
            }
            XCTAssertEqual(code, 200)
            XCTAssertEqual(message, #"{"error":{"code":"unknown"}}"#)
        }
    }

    // MARK: - D 节:parseStreamLine 引擎分发

    func testParseStreamLineNoneEngineYieldsNil() throws {
        // .none 引擎理论上不会走到流式,但分发层应安静返回 nil
        XCTAssertNil(try PolishService.parseStreamLine(#"{"message":{"content":"x"}}"#, engine: .none))
    }

    func testParseStreamLineDispatchesOllamaFamily() throws {
        let line = #"{"message":{"content":"本地"},"done":false}"#
        XCTAssertEqual(try PolishService.parseStreamLine(line, engine: .ollama), "本地")
        XCTAssertEqual(try PolishService.parseStreamLine(line, engine: .ollamaCloud), "本地")
    }

    func testParseStreamLineDispatchesClaude() throws {
        let line = #"data: {"type":"content_block_delta","delta":{"text":"克劳德"}}"#
        XCTAssertEqual(try PolishService.parseStreamLine(line, engine: .claude), "克劳德")
    }

    func testParseStreamLineDispatchesOpenAIFamily() throws {
        let line = #"data: {"choices":[{"delta":{"content":"兼容"}}]}"#
        XCTAssertEqual(try PolishService.parseStreamLine(line, engine: .deepseek), "兼容")
        XCTAssertEqual(try PolishService.parseStreamLine(line, engine: .gemini), "兼容")
        XCTAssertEqual(try PolishService.parseStreamLine(line, engine: .openaiCompatible), "兼容")
    }

    func testParseStreamLineClaudeErrorPropagatesThroughDispatch() {
        // error 帧抛错必须穿透分发层到 polishStream 的 for-loop
        let line = #"data: {"type":"error","error":{"type":"api_error","message":"boom"}}"#
        XCTAssertThrowsError(try PolishService.parseStreamLine(line, engine: .claude))
    }
}
