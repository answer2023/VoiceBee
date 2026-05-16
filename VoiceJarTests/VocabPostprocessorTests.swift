import XCTest
@testable import VoiceBee

/// Phase 3-A 单元测试 — VocabPostprocessor.
///
/// Fixture 选择(P8=A+B):
/// - A 节:基础边界(空文本 / 空 vocab / disabled / 大小写 / 长度门槛 / 不退化)
/// - B 节:PoC 实测错例 golden file(SFSpeech + WhisperKit 2026-05-11 实测,见
///   docs/whisperkit-poc-results.md C 节 + CLAUDE.md「专名词典注入失效」)
final class VocabPostprocessorTests: XCTestCase {

    // MARK: - Fixtures

    /// 营销专名词典(跟 VocabStore.defaultEntries 同构,但显式写在测试里避免源耦合)
    private let marketingVocab: [VocabEntry] = [
        VocabEntry(
            term: "VoiceBee",
            category: "产品名",
            aliases: ["Vocab", "Voizbee", "Boysbee", "Vorce P", "was be", "VB", "Voice Bee", "voice bee"]
        ),
        VocabEntry(
            term: "JotBee",
            category: "产品名",
            aliases: ["Jotby", "Jot B", "JotB", "Jot Bee", "jot bee"]
        ),
        VocabEntry(
            term: "ClearSky",
            category: "团队",
            aliases: ["Clear Sky", "clear sky", "Clearsky"]
        ),
        VocabEntry(
            term: "WhisperKit",
            category: "技术",
            aliases: ["Whisper Kit", "Whisper kit", "whisper kit", "Whisperkit"]
        ),
        VocabEntry(
            term: "macOS",
            category: "技术",
            aliases: ["MacOS", "Mac OS", "mac OS", "Macos", "mac os"]
        )
    ]

    // MARK: - A 节:基础边界

    func testEmptyTextReturnsUnchanged() {
        XCTAssertEqual(VocabPostprocessor.apply("", vocab: marketingVocab), "")
    }

    func testEmptyVocabReturnsUnchanged() {
        let text = "今天 Voizbee 表现不错"
        XCTAssertEqual(VocabPostprocessor.apply(text, vocab: []), text)
    }

    func testDisabledEntriesIgnored() {
        let vocab = [
            VocabEntry(term: "VoiceBee", aliases: ["Voizbee"], createdAt: Date()),
            VocabEntry(term: "JotBee", enabled: false, aliases: ["Jotby"], createdAt: Date())
        ]
        // VoiceBee 启用 → 命中;JotBee 禁用 → 不命中
        let result = VocabPostprocessor.apply("Voizbee 和 Jotby", vocab: vocab)
        XCTAssertEqual(result, "VoiceBee 和 Jotby")
    }

    func testEmptyAliasInVocabSkipped() {
        let vocab = [VocabEntry(term: "VoiceBee", aliases: ["", "  ", "Voizbee"])]
        XCTAssertEqual(
            VocabPostprocessor.apply("Voizbee 好用", vocab: vocab),
            "VoiceBee 好用"
        )
    }

    func testCleanTranscriptDoesNotRegress() {
        // 不含 vocab 错例的干净中文 transcript,经处理后不应变化
        let text = "今天天气不错,适合出去散步。"
        XCTAssertEqual(VocabPostprocessor.apply(text, vocab: marketingVocab), text)
    }

    func testCorrectTermLeftAlone() {
        // 已经是正确拼写的 term 不应被改
        let text = "今天 VoiceBee 表现不错"
        XCTAssertEqual(VocabPostprocessor.apply(text, vocab: marketingVocab), text)
    }

    // MARK: - A 节:大小写策略(P7=A case-insensitive 匹配,case-preserving 输出)

    func testAliasCaseInsensitiveMatch() {
        // alias "Vocab" 应能匹配 "vocab" / "VOCAB" / "VoCaB"
        let text1 = "听成 vocab 了"
        let text2 = "听成 VOCAB 了"
        let text3 = "听成 VoCaB 了"
        XCTAssertEqual(VocabPostprocessor.apply(text1, vocab: marketingVocab), "听成 VoiceBee 了")
        XCTAssertEqual(VocabPostprocessor.apply(text2, vocab: marketingVocab), "听成 VoiceBee 了")
        XCTAssertEqual(VocabPostprocessor.apply(text3, vocab: marketingVocab), "听成 VoiceBee 了")
    }

    func testOutputUsesTermOriginalCase() {
        // alias 命中后输出必须是 term 原拼写(VoiceBee),不是 alias 的大小写(VOCAB)
        let result = VocabPostprocessor.apply("VOCAB", vocab: marketingVocab)
        XCTAssertEqual(result, "VoiceBee")
    }

    // MARK: - A 节:word boundary 防误改

    func testAliasDoesNotMatchSubstring() {
        // alias "VB"(在默认 vocab 里)不该匹配 "VBA" / "VBScript" 这类 prefix
        let text = "用 VBA 编程很复杂"
        XCTAssertEqual(VocabPostprocessor.apply(text, vocab: marketingVocab), text)
    }

    func testAliasWithSpaceMatchesPhrase() {
        // 含空格的 alias("Voice Bee" / "Mac OS")按 substring 匹配,不需 word boundary
        let result = VocabPostprocessor.apply("我用的是 Mac OS 系统", vocab: marketingVocab)
        XCTAssertEqual(result, "我用的是 macOS 系统")
    }

    // MARK: - A 节:编辑距离 fallback 阈值(P6=B)

    func testFuzzyMatchHitsLongerTerm() {
        // VoiceBee(8字符)→ 阈值 8/4=2.随便造一个跟 VoiceBee 距离 1 的拼写:"VoiceBeee"(d=1)
        let vocab = [VocabEntry(term: "VoiceBee")]
        let result = VocabPostprocessor.apply("用 VoiceBeee 测试", vocab: vocab)
        XCTAssertEqual(result, "用 VoiceBee 测试")
    }

    func testFuzzyMatchSkipsShortTerm() {
        // term "Bee"(3字符,< 4)→ fuzzyPass 不处理,不会把 "Boy"(d=2)误改为 "Bee"
        let vocab = [VocabEntry(term: "Bee")]
        let result = VocabPostprocessor.apply("the Boy ran", vocab: vocab)
        XCTAssertEqual(result, "the Boy ran")
    }

    func testFuzzyMatchRespectsThreshold() {
        // term "VoiceBee"(8字符,阈值 max(1, 8/4)=2)
        let vocab = [VocabEntry(term: "VoiceBee")]
        // d=2 case:替换 8th 和 7th 字符 e→x e→y → "VoiceBxy"(8字符,d=2)→ 命中
        XCTAssertEqual(VocabPostprocessor.apply("a VoiceBxy b", vocab: vocab), "a VoiceBee b")
        // 长度差超阈值不命中:lenDiff=3 > threshold=2
        XCTAssertEqual(VocabPostprocessor.apply("a Voice b", vocab: vocab), "a Voice b")
        // 距离明显超阈值不命中
        XCTAssertEqual(VocabPostprocessor.apply("a Random b", vocab: vocab), "a Random b")
    }

    func testFuzzySkipsCJKToken() {
        // 中文 token 不走 fuzzy(只处理 ASCII 英文专名)— 不会把"今天"改成 vocab 里的任何 term
        let vocab = [VocabEntry(term: "VoiceBee")]
        XCTAssertEqual(VocabPostprocessor.apply("今天天气", vocab: vocab), "今天天气")
    }

    // MARK: - A 节:多 alias / 优先级

    func testLongerAliasPriority() {
        // alias "Voice Bee"(含空格,9字符)和 "Bee"(假设)同时存在时,长的优先匹配
        let vocab = [
            VocabEntry(term: "VoiceBee", aliases: ["Voice Bee"]),
            VocabEntry(term: "Bumblebee", aliases: ["Bee"])
        ]
        // "我喜欢 Voice Bee" → "Voice Bee" 整段命中 → "VoiceBee",而不是先把 "Bee" 替换为 "Bumblebee"
        let result = VocabPostprocessor.apply("我喜欢 Voice Bee 这个产品", vocab: vocab)
        XCTAssertEqual(result, "我喜欢 VoiceBee 这个产品")
    }

    // MARK: - A 节:Levenshtein 算法正确性

    func testLevenshteinBasic() {
        // 经典 case(Wikipedia 教科书例子)
        XCTAssertEqual(VocabPostprocessor.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(VocabPostprocessor.levenshtein("hello", "hallo"), 1)
        XCTAssertEqual(VocabPostprocessor.levenshtein("abc", "xyz"), 3)
        // 边界
        XCTAssertEqual(VocabPostprocessor.levenshtein("", ""), 0)
        XCTAssertEqual(VocabPostprocessor.levenshtein("abc", ""), 3)
        XCTAssertEqual(VocabPostprocessor.levenshtein("", "abc"), 3)
        XCTAssertEqual(VocabPostprocessor.levenshtein("abc", "abc"), 0)
        // 对称性
        XCTAssertEqual(
            VocabPostprocessor.levenshtein("kitten", "sitting"),
            VocabPostprocessor.levenshtein("sitting", "kitten")
        )
    }

    func testLevenshteinUnicode() {
        // Swift Character 是 grapheme cluster,中文按字符计数
        XCTAssertEqual(VocabPostprocessor.levenshtein("今天", "明天"), 1)
        XCTAssertEqual(VocabPostprocessor.levenshtein("今天天气", "今天好天气"), 1)
    }

    // MARK: - B 节:PoC 实测错例 golden file

    /// 来源:docs/whisperkit-poc-results.md C 节 + CLAUDE.md「专名词典注入失效」
    /// SFSpeech zh-Hans 把 VoiceBee 听成 "Vocab"(5/5 失败实测)
    func testSFSpeechVocabError() {
        let result = VocabPostprocessor.apply("今天 Vocab 这个产品表现不错", vocab: marketingVocab)
        XCTAssertEqual(result, "今天 VoiceBee 这个产品表现不错")
    }

    /// WhisperKit large-v3 实测:VoiceBee → "Voizbee"
    func testWhisperKitVoizbeeError() {
        let result = VocabPostprocessor.apply("今天Voizbee這個產品表現不錯", vocab: marketingVocab)
        XCTAssertEqual(result, "今天VoiceBee這個產品表現不錯")
    }

    /// WhisperKit 实测:VoiceBee → "Boysbee"(aiff 路径首次冷启动)
    func testWhisperKitBoysbeeError() {
        let result = VocabPostprocessor.apply("今天Boysbee這個產品表現不錯", vocab: marketingVocab)
        XCTAssertEqual(result, "今天VoiceBee這個產品表現不錯")
    }

    /// WhisperKit 实测:JotBee → "Jotby"
    func testWhisperKitJotbyError() {
        let result = VocabPostprocessor.apply("我覺得Jotby這個App挺好", vocab: marketingVocab)
        XCTAssertEqual(result, "我覺得JotBee這個App挺好")
    }

    /// WhisperKit 实测:WhisperKit → "Whisper Kit"(中间插入空格)
    func testWhisperKitSpaceError() {
        let result = VocabPostprocessor.apply("Whisper Kit集成测试中", vocab: marketingVocab)
        XCTAssertEqual(result, "WhisperKit集成测试中")
    }

    /// WhisperKit 实测:macOS → "MacOS"(大小写)
    func testWhisperKitMacOSCase() {
        let result = VocabPostprocessor.apply("用 ClearSky 团队开发的 MacOS 工具", vocab: marketingVocab)
        XCTAssertEqual(result, "用 ClearSky 团队开发的 macOS 工具")
    }

    /// 综合场景:多个错例同段
    func testMultipleErrorsInOneTranscript() {
        let raw = "用 Clear Sky 团队开发的 MacOS 工具,Whisper Kit 集成测试,Voizbee 表现不错"
        let result = VocabPostprocessor.apply(raw, vocab: marketingVocab)
        XCTAssertEqual(
            result,
            "用 ClearSky 团队开发的 macOS 工具,WhisperKit 集成测试,VoiceBee 表现不错"
        )
    }
}
