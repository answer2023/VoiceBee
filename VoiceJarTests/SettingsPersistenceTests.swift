import XCTest
import CoreGraphics
@testable import VoiceBee

/// Settings 持久化回归测试 — PolishSettings / TranslationSettings / OutputStyleSettings
/// 核心回归:load() 期间 didSet→save() 曾用未加载完的默认值清空磁盘上的用户配置
/// (isLoading 旗标修复,pre-fix 代码跑这些测试必挂)
final class SettingsPersistenceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsPersistenceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - A. init 不 clobber 已存配置(数据丢失回归)

    func testPolishSettingsInitDoesNotClobberPersistedValues() {
        defaults.set(PolishEngine.claude.rawValue, forKey: "testpolish_engine")
        defaults.set("custom-model", forKey: "testpolish_model")
        defaults.set("https://example.com", forKey: "testpolish_baseURL")

        let settings = PolishSettings(keyPrefix: "testpolish", defaults: defaults)

        // 内存值正确
        XCTAssertEqual(settings.engine, .claude)
        XCTAssertEqual(settings.model, "custom-model")
        XCTAssertEqual(settings.baseURL, "https://example.com")
        // 磁盘值未被 init 期间的 didSet→save() 清空(pre-fix 这里是 "")
        XCTAssertEqual(defaults.string(forKey: "testpolish_model"), "custom-model")
        XCTAssertEqual(defaults.string(forKey: "testpolish_baseURL"), "https://example.com")
    }

    func testTranslationSettingsInitDoesNotClobberPersistedValues() {
        defaults.set([WorkingLanguage.zhHans.rawValue, WorkingLanguage.ja.rawValue],
                     forKey: "translation_workingLanguages")
        defaults.set(WorkingLanguage.en.rawValue, forKey: "translation_targetLanguage")
        defaults.set(TranslationTrigger.control.rawValue, forKey: "translation_trigger")

        let settings = TranslationSettings(defaults: defaults)

        XCTAssertEqual(settings.workingLanguages, [.zhHans, .ja])
        XCTAssertEqual(settings.targetLanguage, .en)
        XCTAssertEqual(settings.trigger, .control)
        // pre-fix:workingLanguages 的 didSet 会把 targetLanguage 写回 ""、trigger 写回默认
        XCTAssertEqual(defaults.string(forKey: "translation_targetLanguage"), WorkingLanguage.en.rawValue)
        XCTAssertEqual(defaults.string(forKey: "translation_trigger"), TranslationTrigger.control.rawValue)
    }

    func testOutputStyleSettingsInitDoesNotClobberPersistedValues() {
        defaults.set(false, forKey: "outputStyle_master")
        defaults.set(OutputStyle.structured.rawValue, forKey: "outputStyle_default")
        defaults.set([OutputStyle.light.rawValue, OutputStyle.structured.rawValue],
                     forKey: "outputStyle_enabled")

        let settings = OutputStyleSettings(defaults: defaults)

        XCTAssertFalse(settings.masterEnabled)
        XCTAssertEqual(settings.defaultStyle, .structured)
        XCTAssertEqual(settings.enabledStyles, [.light, .structured])
        // pre-fix:masterEnabled 的 didSet 会把 default 写回 .light、enabled 写回全集
        XCTAssertEqual(defaults.string(forKey: "outputStyle_default"), OutputStyle.structured.rawValue)
        XCTAssertEqual(Set(defaults.stringArray(forKey: "outputStyle_enabled") ?? []),
                       [OutputStyle.light.rawValue, OutputStyle.structured.rawValue])
    }

    // MARK: - B. 持久化 round-trip(改动确实落盘,新实例读得回)

    func testPolishSettingsRoundTripViaSecondInstance() {
        let first = PolishSettings(keyPrefix: "testpolish", defaults: defaults)
        first.engine = .deepseek
        first.model = "deepseek-custom"
        first.baseURL = "https://proxy.example.com"

        let second = PolishSettings(keyPrefix: "testpolish", defaults: defaults)
        XCTAssertEqual(second.engine, .deepseek)
        XCTAssertEqual(second.model, "deepseek-custom")
        XCTAssertEqual(second.baseURL, "https://proxy.example.com")
    }

    func testTranslationSettingsRoundTripViaSecondInstance() {
        let first = TranslationSettings(defaults: defaults)
        first.workingLanguages = [.en, .fr]
        first.targetLanguage = .ja
        first.trigger = .option

        let second = TranslationSettings(defaults: defaults)
        XCTAssertEqual(second.workingLanguages, [.en, .fr])
        XCTAssertEqual(second.targetLanguage, .ja)
        XCTAssertEqual(second.trigger, .option)
    }

    func testTranslationSettingsNilTargetLanguagePersistsAsDisabled() {
        let first = TranslationSettings(defaults: defaults)
        first.targetLanguage = .ja
        first.targetLanguage = nil

        let second = TranslationSettings(defaults: defaults)
        XCTAssertNil(second.targetLanguage)
    }

    // MARK: - C. OutputStyleSettings 行为契约

    func testCycleAdvancesWithinEnabledStylesInAllCasesOrder() {
        let settings = OutputStyleSettings(defaults: defaults)
        settings.enabledStyles = [.raw, .structured]
        settings.defaultStyle = .raw

        XCTAssertEqual(settings.cycle(), .structured)
    }

    func testCycleWrapsAroundToFirstEnabled() {
        let settings = OutputStyleSettings(defaults: defaults)
        settings.enabledStyles = [.raw, .structured]
        settings.defaultStyle = .structured

        XCTAssertEqual(settings.cycle(), .raw)
    }

    func testCycleWithDefaultNotInEnabledFallsBackToFirstEnabled() {
        let settings = OutputStyleSettings(defaults: defaults)
        settings.enabledStyles = [.light, .formal]
        settings.defaultStyle = .structured  // 不在 enabled 集合里

        XCTAssertEqual(settings.cycle(), .light)
    }

    func testSetEnabledCannotDisableLastRemainingStyle() {
        let settings = OutputStyleSettings(defaults: defaults)
        settings.enabledStyles = [.light]
        settings.setEnabled(.light, enabled: false)

        XCTAssertEqual(settings.enabledStyles, [.light])
    }

    func testSetEnabledDisablingCurrentDefaultReassignsIt() {
        let settings = OutputStyleSettings(defaults: defaults)
        settings.enabledStyles = [.raw, .light]
        settings.defaultStyle = .raw
        settings.setEnabled(.raw, enabled: false)

        XCTAssertEqual(settings.enabledStyles, [.light])
        XCTAssertEqual(settings.defaultStyle, .light)
    }

    func testSetDefaultRejectsDisabledStyle() {
        let settings = OutputStyleSettings(defaults: defaults)
        settings.enabledStyles = [.light]
        settings.defaultStyle = .light
        settings.setDefault(.formal)  // 未启用,应被拒绝

        XCTAssertEqual(settings.defaultStyle, .light)
    }

    func testLegacyPolishModeMigratesOnlyWhenNoNewKey() {
        defaults.set("structured", forKey: "polishMode_legacy")

        let settings = OutputStyleSettings(defaults: defaults)
        XCTAssertEqual(settings.defaultStyle, .structured)
    }

    func testLegacyPolishModeIgnoredWhenNewKeyPresent() {
        defaults.set("structured", forKey: "polishMode_legacy")
        defaults.set(OutputStyle.formal.rawValue, forKey: "outputStyle_default")

        let settings = OutputStyleSettings(defaults: defaults)
        XCTAssertEqual(settings.defaultStyle, .formal)
    }

    func testLegacyPolishModeNonStructuredMapsToLight() {
        defaults.set("simple", forKey: "polishMode_legacy")

        let settings = OutputStyleSettings(defaults: defaults)
        XCTAssertEqual(settings.defaultStyle, .light)
    }

    // MARK: - D. TranslationSettings 行为契约

    func testTriggerMaskMapping() {
        let settings = TranslationSettings(defaults: defaults)
        settings.trigger = .shift
        XCTAssertEqual(settings.triggerMask, .maskShift)
        settings.trigger = .control
        XCTAssertEqual(settings.triggerMask, .maskControl)
        settings.trigger = .option
        XCTAssertEqual(settings.triggerMask, .maskAlternate)
        settings.trigger = .fn
        XCTAssertEqual(settings.triggerMask, .maskSecondaryFn)
        settings.trigger = .disabled
        XCTAssertNil(settings.triggerMask)
    }

    func testConflictingTriggersMatchesMainModifiers() {
        XCTAssertEqual(
            TranslationSettings.conflictingTriggers(mainModifiers: [.maskShift, .maskControl]),
            [.shift, .control]
        )
        XCTAssertEqual(
            TranslationSettings.conflictingTriggers(mainModifiers: .maskSecondaryFn),
            [.fn]
        )
        XCTAssertEqual(
            TranslationSettings.conflictingTriggers(mainModifiers: .maskCommand),
            []
        )
    }

    func testIsActiveForRecordingRequiresTargetAndTrigger() {
        let settings = TranslationSettings(defaults: defaults)
        settings.targetLanguage = nil
        settings.trigger = .shift
        XCTAssertFalse(settings.isActiveForRecording)

        settings.targetLanguage = .en
        settings.trigger = .disabled
        XCTAssertFalse(settings.isActiveForRecording)

        settings.trigger = .shift
        XCTAssertTrue(settings.isActiveForRecording)
    }
}
