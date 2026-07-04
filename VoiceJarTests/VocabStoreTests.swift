import XCTest
@testable import VoiceBee

/// VocabStore 单元测试 — parseImport 解析 / isSuspect 启发式 / add·addBatch 去重 / 持久化容错.
///
/// 覆盖范围:
/// - A 节:parseImport — Rime frontmatter / Tab / 逗号·管道分隔 / 纯行 / 注释
/// - B 节:isSuspect — URL / 邮箱 / 空格 / 超长 / 纯标点 vs 干净词条
/// - C 节:add / addBatch — trim-then-dedup 语义对齐 + 批量跳过计数(空白变体回归)
/// - D 节:持久化 — 默认词典注入条件 / 损坏 JSON → loadFailed + .bak / 旧格式容错 / round-trip
///
/// 所有文件 IO 走每测试独立的 temp 目录,绝不碰真实 Application Support/VoiceBee/vocab.json.
final class VocabStoreTests: XCTestCase {

    // MARK: - Test isolated temp dir

    /// 隔离的 temp 目录 — 每个测试用独立 UUID 子目录,tearDown 整目录删除
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabStoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("vocab.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        fileURL = nil
        super.tearDown()
    }

    /// 预置磁盘 JSON 再建 store — 让 add/addBatch 测试从确定的种子词典出发.
    /// 注意:空 seed 绕不过默认词典注入(P9=A 判的是 entries.isEmpty,不是文件存在性),
    /// 需要"从零开始"的测试请放一条 "Seed" 占位词
    private func makeStore(seed: [VocabEntry]) throws -> VocabStore {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(seed)
        try data.write(to: fileURL)
        return VocabStore(fileURL: fileURL)
    }

    /// 直接从磁盘 decode vocab.json — 验证 save() 落盘内容
    private func entriesOnDisk() throws -> [VocabEntry] {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([VocabEntry].self, from: data)
    }

    // MARK: - A 节:parseImport — 纯行 / 注释

    func testParseImportPlainLines() {
        let text = """
        VoiceBee

          JotBee
        ClearSky
        """
        let parsed = VocabStore.parseImport(text)
        // 空行跳过,前后空白 trim
        XCTAssertEqual(parsed.map(\.term), ["VoiceBee", "JotBee", "ClearSky"])
        XCTAssertTrue(parsed.allSatisfy { $0.category.isEmpty })
    }

    func testParseImportSkipsComments() {
        let text = """
        # 这是注释
        VoiceBee
          # 缩进的注释也跳过
        JotBee
        """
        XCTAssertEqual(VocabStore.parseImport(text).map(\.term), ["VoiceBee", "JotBee"])
    }

    func testParseImportEmptyInput() {
        XCTAssertTrue(VocabStore.parseImport("").isEmpty)
        XCTAssertTrue(VocabStore.parseImport("\n\n  \n").isEmpty)
        XCTAssertTrue(VocabStore.parseImport("# 只有注释").isEmpty)
    }

    // MARK: - A 节:parseImport — 逗号 / 管道分隔

    func testParseImportCommaSeparated() {
        let parsed = VocabStore.parseImport("VoiceBee, 产品名")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].term, "VoiceBee")
        XCTAssertEqual(parsed[0].category, "产品名")
    }

    func testParseImportPipeSeparated() {
        let parsed = VocabStore.parseImport("ClearSky | 团队")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].term, "ClearSky")
        XCTAssertEqual(parsed[0].category, "团队")
    }

    func testParseImportCategoryTakesRestAfterFirstSeparator() {
        // 只在第一个分隔符处切分 — category 保留后续内容
        let parsed = VocabStore.parseImport("Claude, AI, assistant")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].term, "Claude")
        XCTAssertEqual(parsed[0].category, "AI, assistant")
    }

    func testParseImportSeparatorWithEmptyTermSkipped() {
        // ", category" → term 为空 → 整行跳过
        XCTAssertTrue(VocabStore.parseImport(", 产品名").isEmpty)
    }

    // MARK: - A 节:parseImport — Tab 分隔(Rime 词典行)

    func testParseImportTabTakesFirstColumn() {
        // Rime 格式:term\tcode\tweight → 只取第一列,丢弃编码/权重
        let parsed = VocabStore.parseImport("语音蜂\tyu yin feng\t100")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].term, "语音蜂")
        XCTAssertEqual(parsed[0].category, "")
    }

    // MARK: - A 节:parseImport — Rime YAML frontmatter

    func testParseImportRimeFrontmatterSkipped() {
        // 标准 Rime 词典:--- 开 YAML,... 关(YAML doc end marker),之后是词条
        let text = """
        # Rime dictionary
        ---
        name: luna_pinyin.custom
        version: "1.0"
        sort: by_weight
        ...
        语音蜂\tyu yin feng\t100
        VoiceBee\tvoice bee\t50
        """
        XCTAssertEqual(VocabStore.parseImport(text).map(\.term), ["语音蜂", "VoiceBee"])
    }

    func testParseImportFrontmatterClosedByDashes() {
        // frontmatter 也可用 --- 关闭(通用 YAML frontmatter 风格)
        let text = """
        ---
        name: custom
        ---
        VoiceBee
        """
        XCTAssertEqual(VocabStore.parseImport(text).map(\.term), ["VoiceBee"])
    }

    func testParseImportDashesAfterFrontmatterClosedIgnored() {
        // frontmatter 关闭后再出现 --- 只当普通分隔线跳过,不会重新吞掉后续词条
        let text = """
        ---
        name: custom
        ...
        JotBee
        ---
        ClearSky
        """
        XCTAssertEqual(VocabStore.parseImport(text).map(\.term), ["JotBee", "ClearSky"])
    }

    // MARK: - B 节:isSuspect — 可疑词条

    func testIsSuspectURL() {
        XCTAssertTrue(VocabStore.isSuspect("https://jotbee.app/voicebee.html"))
        XCTAssertTrue(VocabStore.isSuspect("http://example.com"))
    }

    func testIsSuspectEmail() {
        XCTAssertTrue(VocabStore.isSuspect("xtry96@gmail.com"))
    }

    func testIsSuspectAtWithoutDotIsClean() {
        // 只有 @ 没有 . 不算 email-like(社交 handle)
        XCTAssertFalse(VocabStore.isSuspect("@handle"))
    }

    func testIsSuspectSpacesAndTabs() {
        // 含空格 = 句子/短语,不适合作为 ASR 热词
        XCTAssertTrue(VocabStore.isSuspect("今天 天气 不错"))
        XCTAssertTrue(VocabStore.isSuspect("a\tb"))
    }

    func testIsSuspectLengthBoundary() {
        // 长度门槛 30:31 字符可疑,30 字符干净
        XCTAssertTrue(VocabStore.isSuspect(String(repeating: "a", count: 31)))
        XCTAssertFalse(VocabStore.isSuspect(String(repeating: "a", count: 30)))
    }

    func testIsSuspectPunctuationOnlyAndEmpty() {
        XCTAssertTrue(VocabStore.isSuspect(""))
        XCTAssertTrue(VocabStore.isSuspect("   "))
        XCTAssertTrue(VocabStore.isSuspect("!!!"))
        XCTAssertTrue(VocabStore.isSuspect("……"))
    }

    func testIsSuspectCleanTerms() {
        XCTAssertFalse(VocabStore.isSuspect("VoiceBee"))
        XCTAssertFalse(VocabStore.isSuspect("GPT4"))
        XCTAssertFalse(VocabStore.isSuspect("语音蜂"))
        // 首尾空白 trim 后判断
        XCTAssertFalse(VocabStore.isSuspect("  ClearSky  "))
    }

    // MARK: - C 节:add — trim-then-dedup

    func testAddAppendsAndPersists() throws {
        let store = try makeStore(seed: [VocabEntry(term: "VoiceBee")])
        store.add(VocabEntry(term: "JotBee"))
        XCTAssertEqual(store.entries.map(\.term), ["VoiceBee", "JotBee"])
        // save() 已落盘
        XCTAssertEqual(try entriesOnDisk().map(\.term), ["VoiceBee", "JotBee"])
    }

    func testAddDedupCaseInsensitive() throws {
        let store = try makeStore(seed: [VocabEntry(term: "VoiceBee")])
        store.add(VocabEntry(term: "voicebee"))
        store.add(VocabEntry(term: "VOICEBEE"))
        XCTAssertEqual(store.entries.count, 1)
    }

    /// 回归:add 的空白变体判重必须与 addBatch 对齐 — " VoiceBee " 不能绕过已存在的 "VoiceBee"
    func testAddDedupWhitespaceVariant() throws {
        let store = try makeStore(seed: [VocabEntry(term: "VoiceBee")])
        store.add(VocabEntry(term: " VoiceBee "))
        store.add(VocabEntry(term: "\tvoicebee"))
        XCTAssertEqual(store.entries.count, 1, "空白变体重复词条应被判重跳过")
    }

    func testAddStoresTrimmedTerm() throws {
        let store = try makeStore(seed: [VocabEntry(term: "Seed")])
        store.add(VocabEntry(term: "  JotBee  "))
        XCTAssertEqual(store.entries.map(\.term), ["Seed", "JotBee"], "term 应以 trim 后的形式入库")
    }

    func testAddRejectsEmptyOrWhitespaceTerm() throws {
        let store = try makeStore(seed: [VocabEntry(term: "Seed")])
        store.add(VocabEntry(term: ""))
        store.add(VocabEntry(term: "   "))
        XCTAssertEqual(store.entries.map(\.term), ["Seed"])
    }

    // MARK: - C 节:addBatch — 批量去重 + 跳过计数

    func testAddBatchCountsAddedAndSkipped() throws {
        let store = try makeStore(seed: [VocabEntry(term: "VoiceBee")])
        let result = store.addBatch([
            VocabEntry(term: " voicebee "),   // 与已有重复(trim + case-insensitive)→ skip
            VocabEntry(term: "JotBee"),       // 新增
            VocabEntry(term: "jotbee"),       // 批内重复 → skip
            VocabEntry(term: "   "),          // trim 后为空 → skip
            VocabEntry(term: "ClearSky")      // 新增
        ])
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.skipped, 3)
        XCTAssertEqual(store.entries.map(\.term), ["VoiceBee", "JotBee", "ClearSky"])
    }

    func testAddBatchStoresTrimmedTerms() throws {
        let store = try makeStore(seed: [VocabEntry(term: "Seed")])
        let result = store.addBatch([VocabEntry(term: "  语音蜂  ")])
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(store.entries.map(\.term), ["Seed", "语音蜂"])
    }

    func testAddBatchAllDuplicatesAddsNothing() throws {
        let store = try makeStore(seed: [VocabEntry(term: "VoiceBee")])
        let result = store.addBatch([
            VocabEntry(term: "VoiceBee"),
            VocabEntry(term: "VOICEBEE")
        ])
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testAddBatchPersistsInOneWrite() throws {
        let store = try makeStore(seed: [VocabEntry(term: "Seed")])
        store.addBatch([VocabEntry(term: "VoiceBee"), VocabEntry(term: "JotBee")])
        XCTAssertEqual(try entriesOnDisk().map(\.term), ["Seed", "VoiceBee", "JotBee"])
    }

    // MARK: - D 节:持久化 — 默认词典注入条件

    func testFreshStoreInjectsDefaults() {
        // 首次运行(文件不存在)→ 注入默认营销词典并落盘
        let store = VocabStore(fileURL: fileURL)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.entries, VocabStore.defaultEntries)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testExistingEntriesNotOverwrittenByDefaults() throws {
        // 老用户哪怕只有一条自定义条目,默认词典都不注入(P9=A)
        let store = try makeStore(seed: [VocabEntry(term: "自定义词")])
        XCTAssertEqual(store.entries.map(\.term), ["自定义词"])
    }

    // MARK: - D 节:持久化 — 损坏 JSON → loadFailed + .bak

    func testCorruptJSONSetsLoadFailedAndSkipsDefaults() throws {
        try Data("{ 这不是合法 JSON".utf8).write(to: fileURL)
        let store = VocabStore(fileURL: fileURL)

        // loadFailed 置位,entries 为空但**不注入默认词典**(防止 save() 覆盖用户数据)
        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(store.entries.isEmpty)

        // 损坏文件被挪到 vocab.json.corrupt-<ts>.bak 保留现场,原路径不再存在
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix("vocab.json.corrupt-") && $0.hasSuffix(".bak") }
        XCTAssertEqual(backups.count, 1)
        // 备份内容 = 原始损坏字节
        let backupData = try Data(contentsOf: tempDir.appendingPathComponent(backups[0]))
        XCTAssertEqual(String(data: backupData, encoding: .utf8), "{ 这不是合法 JSON")
    }

    // MARK: - D 节:持久化 — 旧格式容错 + round-trip

    func testLoadsLegacyJSONWithoutAliases() throws {
        // Phase 3-A 之前的 vocab.json 只有部分字段 — decodeIfPresent 全量容错
        let legacy = #"[{"term":"OldTerm","enabled":false}]"#
        try Data(legacy.utf8).write(to: fileURL)
        let store = VocabStore(fileURL: fileURL)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].term, "OldTerm")
        XCTAssertFalse(store.entries[0].enabled)
        XCTAssertEqual(store.entries[0].aliases, [])
        // 有一条旧数据 → 默认词典不注入
        XCTAssertEqual(store.entries.map(\.term), ["OldTerm"])
    }

    func testPersistenceRoundTrip() throws {
        let store1 = try makeStore(seed: [VocabEntry(term: "Seed")])
        store1.add(VocabEntry(term: "VoiceBee", category: "产品名", aliases: ["Vocab"]))
        store1.add(VocabEntry(term: "语音蜂"))

        // 用同一 fileURL 建第二个 store — 应完整读回
        let store2 = VocabStore(fileURL: fileURL)
        XCTAssertFalse(store2.loadFailed)
        XCTAssertEqual(store2.entries.map(\.term), ["Seed", "VoiceBee", "语音蜂"])
        XCTAssertEqual(store2.entries[1].category, "产品名")
        XCTAssertEqual(store2.entries[1].aliases, ["Vocab"])
    }
}
