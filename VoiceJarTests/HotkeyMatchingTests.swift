import XCTest
import Carbon.HIToolbox
import CoreGraphics
@testable import VoiceBee

/// Phase 3-B 单元测试 — Hotkey 事件匹配族(HotkeyTests 未覆盖的运行时判定路径).
///
/// 覆盖范围:
/// - A 节:comboMatches — 包含语义(main 录音键 press 判定,允许多余 modifier)
/// - B 节:comboMatchesExact — 严格语义(translate / repeatLast tap-trigger,
///   防 ⌘⌥T 幽灵触发 ⌥T)+ relevant mask 只看 ⌘⌥⇧⌃ 的边界
/// - C 节:comboModifierStillHeld — keyUp fallback stop 路径判定
/// - D 节:modifierMask / flagMask 的事件匹配视角(左右 ⌘ 共享 flag bit,靠 keyCode 区分)
/// - E 节:v1 兼容路径边界 — keyCode == -1 但无 Fn flag 时解码出永不可匹配的 combo(pin 现状)
final class HotkeyMatchingTests: XCTestCase {

    // MARK: - Test isolated UserDefaults

    /// 隔离的 defaults — 每个测试用独立 suite,避免污染主进程
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HotkeyMatchingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - A 节:comboMatches — 包含语义

    func testComboMatchesExactPress() {
        // ⌥Space,事件恰好是 ⌥ + Space → 命中
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertTrue(hk.comboMatches(keyCode: Int64(kVK_Space), flags: .maskAlternate))
    }

    func testComboMatchesWithExtraModifiers() {
        // 包含语义:用户多按了 ⇧(⌥⇧Space)仍算命中 main 录音键
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertTrue(hk.comboMatches(keyCode: Int64(kVK_Space), flags: [.maskAlternate, .maskShift]))
    }

    func testComboMatchesWrongKeyCode() {
        // 主键不对 → 不命中,即使 modifiers 全对
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertFalse(hk.comboMatches(keyCode: Int64(kVK_Tab), flags: .maskAlternate))
    }

    func testComboMatchesMissingModifier() {
        // 缺少要求的 modifier → 不命中(裸 Space 不能触发 ⌥Space)
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertFalse(hk.comboMatches(keyCode: Int64(kVK_Space), flags: []))
    }

    func testComboMatchesMultiModifierRequiresAll() {
        // ⌘⇧V:两个 modifier 必须全按下
        let hk = Hotkey.combo(keyCode: kVK_ANSI_V, modifiers: [.maskCommand, .maskShift], mode: .hold)
        XCTAssertFalse(hk.comboMatches(keyCode: Int64(kVK_ANSI_V), flags: .maskCommand))
        XCTAssertTrue(hk.comboMatches(keyCode: Int64(kVK_ANSI_V), flags: [.maskCommand, .maskShift]))
    }

    func testComboMatchesModifierOnlyAlwaysFalse() {
        // modifierOnly case 走 flagsChanged 状态机,comboMatches 恒 false
        let hk = Hotkey.modifierOnly(.fn, mode: .hold)
        XCTAssertFalse(hk.comboMatches(keyCode: 63, flags: .maskSecondaryFn))
        XCTAssertFalse(hk.comboMatches(keyCode: Int64(kVK_Space), flags: .maskSecondaryFn))
    }

    // MARK: - B 节:comboMatchesExact — 严格语义

    func testComboMatchesExactSameModifiers() {
        // ⌥T,事件恰好是 ⌥ + T → 命中
        let hk = Hotkey.combo(keyCode: kVK_ANSI_T, modifiers: .maskAlternate, mode: .hold)
        XCTAssertTrue(hk.comboMatchesExact(keyCode: Int64(kVK_ANSI_T), flags: .maskAlternate))
    }

    func testComboMatchesExactRejectsExtraModifier() {
        // 关键区分:⌘⌥T 不能幽灵触发 translate 的 ⌥T(comboMatches 会误命中,exact 必须拒绝)
        let hk = Hotkey.combo(keyCode: kVK_ANSI_T, modifiers: .maskAlternate, mode: .hold)
        XCTAssertTrue(hk.comboMatches(keyCode: Int64(kVK_ANSI_T), flags: [.maskAlternate, .maskCommand]),
                      "前提:contains 语义确实会命中(这就是 exact 存在的理由)")
        XCTAssertFalse(hk.comboMatchesExact(keyCode: Int64(kVK_ANSI_T), flags: [.maskAlternate, .maskCommand]))
    }

    func testComboMatchesExactIgnoresIrrelevantFlags() {
        // 真实 CGEvent 常带非 modifier 位(nonCoalesced 0x100)和 Caps Lock(alphaShift)—
        // exact 只比较 ⌘⌥⇧⌃ 四位,这些噪声位不该导致拒绝
        let hk = Hotkey.combo(keyCode: kVK_ANSI_T, modifiers: .maskAlternate, mode: .hold)
        let noisy: CGEventFlags = [.maskAlternate, .maskAlphaShift, .maskNonCoalesced]
        XCTAssertTrue(hk.comboMatchesExact(keyCode: Int64(kVK_ANSI_T), flags: noisy))
    }

    func testComboMatchesExactWrongKeyCode() {
        let hk = Hotkey.combo(keyCode: kVK_ANSI_T, modifiers: .maskAlternate, mode: .hold)
        XCTAssertFalse(hk.comboMatchesExact(keyCode: Int64(kVK_ANSI_V), flags: .maskAlternate))
    }

    func testComboMatchesExactModifierOnlyAlwaysFalse() {
        let hk = Hotkey.modifierOnly(.rightCommand, mode: .toggle)
        XCTAssertFalse(hk.comboMatchesExact(keyCode: 54, flags: .maskCommand))
    }

    func testComboMatchesExactIgnoresFnFlag() {
        // Pin 现状:relevant mask = [⌘⌥⇧⌃],Fn 不在其中 —
        // (1) 事件多带 Fn flag 不影响 exact 命中
        let hk = Hotkey.combo(keyCode: kVK_ANSI_T, modifiers: .maskAlternate, mode: .hold)
        XCTAssertTrue(hk.comboMatchesExact(keyCode: Int64(kVK_ANSI_T), flags: [.maskAlternate, .maskSecondaryFn]))
        // (2) 反向边界:若 combo 的 modifiers 里写了 Fn,该要求会被 intersection 剥掉 —
        //     裸 T(无任何 modifier)也能 exact 命中 "Fn+T"。这是现状行为,不是理想行为;
        //     当前 keypicker 不产出 Fn 组合,风险仅存在于手工构造/未来扩展路径
        let fnCombo = Hotkey.combo(keyCode: kVK_ANSI_T, modifiers: .maskSecondaryFn, mode: .hold)
        XCTAssertTrue(fnCombo.comboMatchesExact(keyCode: Int64(kVK_ANSI_T), flags: []))
    }

    // MARK: - C 节:comboModifierStillHeld — keyUp fallback 判定

    func testComboModifierStillHeldTrue() {
        // ⌥Space 松开主键但 ⌥ 还按着 → true
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertTrue(hk.comboModifierStillHeld(flags: .maskAlternate))
    }

    func testComboModifierStillHeldFalseAfterRelease() {
        // modifier 全松 → false,keyUp 走 fallback stop
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertFalse(hk.comboModifierStillHeld(flags: []))
        XCTAssertFalse(hk.comboModifierStillHeld(flags: .maskShift))  // 换了别的 modifier 也是 false
    }

    func testComboModifierStillHeldWithExtraFlags() {
        // 包含语义:要求的 ⌥ 还在,多按 ⌘ 不影响判定
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertTrue(hk.comboModifierStillHeld(flags: [.maskAlternate, .maskCommand]))
    }

    func testComboModifierStillHeldPartialMultiModifier() {
        // ⌥⇧V:只剩 ⌥(⇧ 已松)→ contains([⌥,⇧]) 失败 → false
        let hk = Hotkey.combo(keyCode: kVK_ANSI_V, modifiers: [.maskAlternate, .maskShift], mode: .hold)
        XCTAssertFalse(hk.comboModifierStillHeld(flags: .maskAlternate))
        XCTAssertTrue(hk.comboModifierStillHeld(flags: [.maskAlternate, .maskShift]))
    }

    func testComboModifierStillHeldModifierOnlyFalse() {
        // modifierOnly case 恒 false(不走此路径)
        let hk = Hotkey.modifierOnly(.fn, mode: .hold)
        XCTAssertFalse(hk.comboModifierStillHeld(flags: .maskSecondaryFn))
    }

    func testComboModifierStillHeldEmptyModsAlwaysTrue() {
        // Pin 现状:combo 无 modifier(裸 F 键类)时 contains([]) 恒 true —
        // 即"modifier 永远算按着",keyUp 永远不走 fallback stop 路径
        let hk = Hotkey.combo(keyCode: kVK_F5, modifiers: [], mode: .hold)
        XCTAssertTrue(hk.comboModifierStillHeld(flags: []))
        XCTAssertTrue(hk.comboModifierStillHeld(flags: .maskCommand))
    }

    // MARK: - D 节:modifierMask / flagMask — 事件匹配视角

    func testLeftRightCommandShareFlagMaskDistinguishedByKeyCode() {
        // CGEventFlags 无法区分左右 ⌘(共享 .maskCommand bit),区分只能靠 flagsChanged 的物理 keyCode
        XCTAssertEqual(ModifierKey.leftCommand.flagMask, ModifierKey.rightCommand.flagMask)
        XCTAssertEqual(Hotkey.modifierOnly(.leftCommand, mode: .hold).modifierMask,
                       Hotkey.modifierOnly(.rightCommand, mode: .hold).modifierMask)
        XCTAssertNotEqual(ModifierKey.leftCommand.physicalKeyCode, ModifierKey.rightCommand.physicalKeyCode)
        XCTAssertEqual(ModifierKey.from(physicalKeyCode: 55), .leftCommand)
        XCTAssertEqual(ModifierKey.from(physicalKeyCode: 54), .rightCommand)
    }

    func testFnFlagMaskDisjointFromStandardModifiers() {
        // Fn 的 flag bit 与 ⌘⌥⇧⌃ 四位互不重叠 — comboMatchesExact 的 relevant mask 剥 Fn 依赖此事实
        let standard: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        XCTAssertTrue(ModifierKey.fn.flagMask.intersection(standard).isEmpty)
        XCTAssertEqual(Hotkey.modifierOnly(.fn, mode: .hold).modifierMask, .maskSecondaryFn)
    }

    // MARK: - E 节:v1 兼容路径边界 — keyCode == -1 且无 Fn flag

    /// Pin 现状:v1 数据 keyCode == -1 但 modifiers 里没有 maskSecondaryFn(理论上不该出现,
    /// 但可能因旧 bug / plist 手工编辑 / modifiers key 丢失产生)→ 解码走 combo 分支,
    /// 得到 .combo(keyCode: -1, ...)。真实 CGEvent 的 keycode 是 UInt16(≥ 0),
    /// 永远不等于 -1 → 这个 hotkey 永不可触发(录音键静默失效,直到用户重新设置)。
    func testV1LegacyMinusOneWithoutFnFlagDecodesToUnmatchableCombo() {
        defaults.set(-1, forKey: "hotkey_keyCode")
        defaults.set(Int(CGEventFlags.maskAlternate.rawValue), forKey: "hotkey_modifiers")
        let loaded = Hotkey.loadFrom(slot: .main, defaults: defaults)
        // 现状:解码成 keyCode = -1 的 combo,而不是 fallback 到 .fnHold
        XCTAssertEqual(loaded, .combo(keyCode: -1, modifiers: .maskAlternate, mode: .hold))
        // 任何真实 keycode 都无法命中(采样几个代表值:0 / Space / Fn 物理码)
        for keyCode: Int64 in [0, Int64(kVK_Space), 63] {
            XCTAssertFalse(loaded.comboMatches(keyCode: keyCode, flags: .maskAlternate))
            XCTAssertFalse(loaded.comboMatchesExact(keyCode: keyCode, flags: .maskAlternate))
        }
    }

    /// Pin 现状:keyCode == -1 且 modifiers key 缺失(integer(forKey:) 返回 0 → flags 空)
    /// → 同样落入 combo 分支,combo(-1, []) 永不可匹配
    func testV1LegacyMinusOneMissingModifiersKeyDecodesToUnmatchableCombo() {
        defaults.set(-1, forKey: "hotkey_keyCode")
        // 不写 hotkey_modifiers
        let loaded = Hotkey.loadFrom(slot: .main, defaults: defaults)
        XCTAssertEqual(loaded, .combo(keyCode: -1, modifiers: [], mode: .hold))
        XCTAssertFalse(loaded.comboMatches(keyCode: 0, flags: []))
    }
}
