import XCTest
@testable import VoiceBee

/// Unit A 单元测试 — PolishService prompt 拼装.
///
/// 这两个 prompt 是每次润色 / 翻译调用的契约,下游(所有 LLM engine 的 system prompt)
/// 依赖其结构。测结构性质(contains / 顺序 / 数量),不做整串 golden 比对,避免措辞微调就碎:
/// - A 节:assemblePrompt 段落顺序(globalContract 恒在最前)
/// - B 节:workingLanguages 段落有/无
/// - C 节:style.prompt 按 OutputStyle 注入
/// - D 节:vocab terms 清洗(trim / 过滤空白)+ 50 词上限 + 列表格式
/// - E 节:translationPrompt(targetLang + 只输出译文规则)
final class PolishPromptTests: XCTestCase {

    // MARK: - Helpers

    /// 断言 needle 在 haystack 中出现,且返回首次出现的位置(供顺序比较)
    private func indexOf(_ needle: String, in haystack: String,
                         file: StaticString = #filePath, line: UInt = #line) -> String.Index? {
        guard let range = haystack.range(of: needle) else {
            XCTFail("prompt 应包含 \"\(needle.prefix(30))…\"", file: file, line: line)
            return nil
        }
        return range.lowerBound
    }

    // MARK: - A 节:段落顺序

    func testGlobalContractIsFirstSection() {
        for style in OutputStyle.allCases {
            let prompt = PolishService.assemblePrompt(style: style, vocabTerms: [])
            XCTAssertTrue(prompt.hasPrefix(OutputStyle.globalContract),
                          "globalContract 必须是 \(style.rawValue) prompt 的第一段")
        }
    }

    func testSectionOrderContractThenLanguagesThenStyleThenVocab() {
        let prompt = PolishService.assemblePrompt(
            style: .light,
            vocabTerms: ["VoiceBee"],
            workingLanguages: ["简体中文", "English"]
        )
        guard let contractIdx = indexOf(OutputStyle.globalContract, in: prompt),
              let langIdx = indexOf("用户的常用工作语言", in: prompt),
              let styleIdx = indexOf(OutputStyle.light.prompt, in: prompt),
              let vocabIdx = indexOf("专有名词参考", in: prompt) else { return }
        XCTAssertLessThan(contractIdx, langIdx, "globalContract 应在 workingLanguages 段之前")
        XCTAssertLessThan(langIdx, styleIdx, "workingLanguages 段应在 style prompt 之前")
        XCTAssertLessThan(styleIdx, vocabIdx, "style prompt 应在 vocab 段之前")
    }

    func testSectionsJoinedByBlankLine() {
        // 段落间用空行(\n\n)分隔 — globalContract 结尾紧跟空行再接下一段
        let prompt = PolishService.assemblePrompt(style: .raw, vocabTerms: ["VoiceBee"])
        XCTAssertTrue(prompt.contains(OutputStyle.globalContract + "\n\n"),
                      "globalContract 与下一段之间应有空行")
    }

    // MARK: - B 节:workingLanguages 段落有/无

    func testWorkingLanguagesSectionPresent() {
        let prompt = PolishService.assemblePrompt(
            style: .light, vocabTerms: [], workingLanguages: ["简体中文", "English"]
        )
        XCTAssertTrue(prompt.contains("用户的常用工作语言：简体中文, English"),
                      "workingLanguages 应以 \", \" 连接注入语言段")
    }

    func testWorkingLanguagesSectionAbsentWhenEmpty() {
        let prompt = PolishService.assemblePrompt(style: .light, vocabTerms: [], workingLanguages: [])
        XCTAssertFalse(prompt.contains("用户的常用工作语言"),
                       "无 workingLanguages 时不应出现语言段")
    }

    func testWorkingLanguagesDefaultParameterIsEmpty() {
        // 省略参数 == 传空数组(默认值契约)
        let omitted = PolishService.assemblePrompt(style: .light, vocabTerms: [])
        let explicit = PolishService.assemblePrompt(style: .light, vocabTerms: [], workingLanguages: [])
        XCTAssertEqual(omitted, explicit)
    }

    // MARK: - C 节:style.prompt 按 OutputStyle 注入

    func testStylePromptIncludedPerStyle() {
        for style in OutputStyle.allCases {
            let prompt = PolishService.assemblePrompt(style: style, vocabTerms: [])
            XCTAssertTrue(prompt.contains(style.prompt),
                          "assemblePrompt(\(style.rawValue)) 应完整包含该风格的 prompt")
        }
    }

    func testDifferentStylesProduceDifferentPrompts() {
        // 4 档风格两两不同 — 防止 style 参数被忽略的回归
        let prompts = OutputStyle.allCases.map {
            PolishService.assemblePrompt(style: $0, vocabTerms: [])
        }
        XCTAssertEqual(Set(prompts).count, OutputStyle.allCases.count)
    }

    // MARK: - D 节:vocab terms 清洗 + 上限 + 格式

    func testVocabSectionAbsentWhenNoTerms() {
        let prompt = PolishService.assemblePrompt(style: .light, vocabTerms: [])
        XCTAssertFalse(prompt.contains("专有名词参考"), "无 vocab 时不应出现专名段")
    }

    func testVocabSectionAbsentWhenAllTermsBlank() {
        // 全是空白/空串 → 清洗后为空 → 段落不出现
        let prompt = PolishService.assemblePrompt(style: .light, vocabTerms: ["", "   ", "\n", "\t"])
        XCTAssertFalse(prompt.contains("专有名词参考"),
                       "清洗后为空的 vocab 不应产生专名段")
    }

    func testVocabTermsWhitespaceTrimmed() {
        let prompt = PolishService.assemblePrompt(
            style: .light, vocabTerms: ["  VoiceBee  ", "\nClearSky\t"]
        )
        XCTAssertTrue(prompt.contains("- VoiceBee\n"), "term 前后空白应被 trim")
        XCTAssertTrue(prompt.hasSuffix("- ClearSky"), "最后一个 term 应 trim 后作为 prompt 结尾")
        XCTAssertFalse(prompt.contains("-   VoiceBee"), "不应保留 trim 前的空白")
    }

    func testVocabEmptyTermsFilteredButValidKept() {
        // 空串夹在有效 term 中间 → 只留有效的,不产生空行 "- "
        let prompt = PolishService.assemblePrompt(
            style: .light, vocabTerms: ["VoiceBee", "", "  ", "JotBee"]
        )
        XCTAssertTrue(prompt.contains("- VoiceBee\n- JotBee"),
                      "有效 term 应连续列出,空 term 不占行")
    }

    func testVocabFiftyTermCap() {
        // 60 个 term → 只保留前 50 个
        let terms = (1...60).map { "Term\($0)" }
        let prompt = PolishService.assemblePrompt(style: .light, vocabTerms: terms)
        XCTAssertTrue(prompt.contains("- Term50"), "第 50 个 term 应保留")
        XCTAssertFalse(prompt.contains("- Term51"), "第 51 个 term 应被截断")
        // 列表行数恰为 50 — 只在 vocab 段内数(globalContract / style prompt 里也有 "- " 行,不能全串数)
        guard let vocabStart = prompt.range(of: "专有名词参考")?.lowerBound else {
            XCTFail("prompt 应包含专名段")
            return
        }
        let vocabSection = String(prompt[vocabStart...])
        let bulletLines = vocabSection.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bulletLines.count, 50, "vocab 列表应恰好 50 行")
    }

    func testVocabCapAppliedAfterCleaning() {
        // 50 上限作用于清洗后的列表:前面塞 10 个空串不挤占配额
        let terms = Array(repeating: "  ", count: 10) + (1...50).map { "Term\($0)" }
        let prompt = PolishService.assemblePrompt(style: .light, vocabTerms: terms)
        XCTAssertTrue(prompt.contains("- Term50"),
                      "空 term 先被过滤,50 个有效 term 应全部保留")
    }

    func testVocabListFormatting() {
        let prompt = PolishService.assemblePrompt(
            style: .light, vocabTerms: ["VoiceBee", "ClearSky", "Sparkle"]
        )
        // 段落头 + "- " 前缀 + \n 分隔
        XCTAssertTrue(prompt.contains("专有名词参考（按上下文判断是否替换；不要强行使用）：\n- VoiceBee\n- ClearSky\n- Sparkle"),
                      "vocab 段应为「头部：\\n- term 每行一个」格式")
    }

    // MARK: - E 节:translationPrompt

    func testTranslationPromptContainsTargetLanguage() {
        XCTAssertTrue(PolishService.translationPrompt(targetLang: "English").contains("English"))
        XCTAssertTrue(PolishService.translationPrompt(targetLang: "日本語").contains("日本語"))
    }

    func testTranslationPromptContainsOutputOnlyRule() {
        // 下游依赖:译文直接上屏,不能带解释/引号 — 规则 3 是硬契约
        let prompt = PolishService.translationPrompt(targetLang: "English")
        XCTAssertTrue(prompt.contains("Output ONLY the translated text"),
                      "translationPrompt 必须含只输出译文的规则")
    }

    func testTranslationPromptContainsTranslatorRole() {
        let prompt = PolishService.translationPrompt(targetLang: "English")
        XCTAssertTrue(prompt.contains("Translate the following text to English"),
                      "targetLang 应插入在翻译指令句中")
    }
}
