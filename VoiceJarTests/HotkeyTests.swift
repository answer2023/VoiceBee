import XCTest
import Carbon.HIToolbox
import CoreGraphics
@testable import VoiceBee

/// Phase 3-B 单元测试 — Hotkey enum / 持久化迁移 / 冲突检测.
///
/// 覆盖范围(F10=A):
/// - A 节:Hotkey 数据模型 + Codable + Equatable
/// - B 节:ModifierKey 物理 keyCode / flagMask 映射
/// - C 节:持久化 v2 编解码 + **v1 兼容路径**(F8 必测)
/// - D 节:冲突检测 — 系统黑名单(F6) + 内部冲突(F7=C 超集语义)
final class HotkeyTests: XCTestCase {

    // MARK: - Test isolated UserDefaults

    /// 隔离的 defaults — 每个测试用独立 suite,避免污染主进程
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "HotkeyTests-\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        if let name = defaults.dictionaryRepresentation().keys.first { _ in true } as String? {
            _ = name
        }
        defaults = nil
        super.tearDown()
    }

    // MARK: - A 节:Hotkey 数据模型

    func testModeAccessor() {
        XCTAssertEqual(Hotkey.modifierOnly(.fn, mode: .hold).mode, .hold)
        XCTAssertEqual(Hotkey.modifierOnly(.rightCommand, mode: .toggle).mode, .toggle)
        XCTAssertEqual(Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .toggle).mode, .toggle)
    }

    func testIsModifierOnly() {
        XCTAssertTrue(Hotkey.modifierOnly(.fn, mode: .hold).isModifierOnly)
        XCTAssertFalse(Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold).isModifierOnly)
    }

    func testWithModeChangesOnlyMode() {
        let original = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        let changed = original.with(mode: .toggle)
        XCTAssertEqual(changed, .combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .toggle))
        XCTAssertNotEqual(original, changed)
    }

    func testEquatableEnumCases() {
        XCTAssertEqual(Hotkey.modifierOnly(.fn, mode: .hold), Hotkey.modifierOnly(.fn, mode: .hold))
        XCTAssertNotEqual(Hotkey.modifierOnly(.fn, mode: .hold), Hotkey.modifierOnly(.rightCommand, mode: .hold))
        XCTAssertNotEqual(Hotkey.modifierOnly(.fn, mode: .hold), Hotkey.modifierOnly(.fn, mode: .toggle))
    }

    func testModifierMaskAccessor() {
        XCTAssertEqual(Hotkey.modifierOnly(.fn, mode: .hold).modifierMask, .maskSecondaryFn)
        XCTAssertEqual(Hotkey.modifierOnly(.rightCommand, mode: .hold).modifierMask, .maskCommand)
        let combo: Hotkey = .combo(keyCode: kVK_ANSI_V, modifiers: [.maskCommand, .maskShift], mode: .hold)
        XCTAssertEqual(combo.modifierMask, [.maskCommand, .maskShift])
    }

    // MARK: - A 节:displayName

    func testDisplayNameModifierOnly() {
        XCTAssertEqual(Hotkey.modifierOnly(.fn, mode: .hold).displayName, "Fn")
        XCTAssertEqual(Hotkey.modifierOnly(.rightCommand, mode: .hold).displayName, "右⌘")
        XCTAssertEqual(Hotkey.modifierOnly(.leftOption, mode: .toggle).displayName, "左⌥")
        XCTAssertEqual(Hotkey.modifierOnly(.rightShift, mode: .hold).displayName, "右⇧")
    }

    func testDisplayNameCombo() {
        XCTAssertEqual(Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold).displayName, "⌥Space")
        let cmdShiftV = Hotkey.combo(keyCode: kVK_ANSI_V, modifiers: [.maskCommand, .maskShift], mode: .hold)
        XCTAssertEqual(cmdShiftV.displayName, "⇧⌘V")
    }

    // MARK: - B 节:ModifierKey 物理 keyCode + flagMask

    func testModifierKeyPhysicalKeyCodes() {
        XCTAssertEqual(ModifierKey.fn.physicalKeyCode, 63)
        XCTAssertEqual(ModifierKey.leftCommand.physicalKeyCode, 55)
        XCTAssertEqual(ModifierKey.rightCommand.physicalKeyCode, 54)
        XCTAssertEqual(ModifierKey.leftShift.physicalKeyCode, 56)
        XCTAssertEqual(ModifierKey.rightShift.physicalKeyCode, 60)
        XCTAssertEqual(ModifierKey.leftOption.physicalKeyCode, 58)
        XCTAssertEqual(ModifierKey.rightOption.physicalKeyCode, 61)
        XCTAssertEqual(ModifierKey.leftControl.physicalKeyCode, 59)
        XCTAssertEqual(ModifierKey.rightControl.physicalKeyCode, 62)
    }

    func testModifierKeyFlagMasks() {
        XCTAssertEqual(ModifierKey.fn.flagMask, .maskSecondaryFn)
        XCTAssertEqual(ModifierKey.leftCommand.flagMask, .maskCommand)
        XCTAssertEqual(ModifierKey.rightCommand.flagMask, .maskCommand)  // L/R share flag bit
        XCTAssertEqual(ModifierKey.leftShift.flagMask, .maskShift)
        XCTAssertEqual(ModifierKey.rightOption.flagMask, .maskAlternate)
        XCTAssertEqual(ModifierKey.leftControl.flagMask, .maskControl)
    }

    func testModifierKeyFromPhysicalKeyCode() {
        XCTAssertEqual(ModifierKey.from(physicalKeyCode: 63), .fn)
        XCTAssertEqual(ModifierKey.from(physicalKeyCode: 55), .leftCommand)
        XCTAssertEqual(ModifierKey.from(physicalKeyCode: 54), .rightCommand)
        XCTAssertEqual(ModifierKey.from(physicalKeyCode: 60), .rightShift)
        XCTAssertNil(ModifierKey.from(physicalKeyCode: 99))  // 不是 modifier
    }

    // MARK: - C 节:Codable round-trip

    func testCodableRoundTripModifierOnly() throws {
        let original = Hotkey.modifierOnly(.rightCommand, mode: .toggle)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testCodableRoundTripCombo() throws {
        let original = Hotkey.combo(keyCode: kVK_ANSI_V, modifiers: [.maskCommand, .maskShift], mode: .toggle)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testCodableModeOptionalDefaultsToHold() throws {
        // 模拟未来某天 mode 字段没编码进 JSON 的情况 — decodeIfPresent 应默认 .hold
        let json = #"{"variant":"modifierOnly","modifier":"fn"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Hotkey.self, from: json)
        XCTAssertEqual(decoded, .modifierOnly(.fn, mode: .hold))
    }

    // MARK: - C 节:UserDefaults v2 持久化 round-trip

    func testV2SaveLoadMain() {
        let hk = Hotkey.modifierOnly(.rightOption, mode: .toggle)
        hk.saveTo(slot: .main, defaults: defaults)
        let loaded = Hotkey.loadFrom(slot: .main, defaults: defaults)
        XCTAssertEqual(loaded, hk)
    }

    func testV2SaveLoadTranslateForcesHold() {
        // F2=C: translate slot 强制 .hold,即使保存时是 .toggle
        let hk = Hotkey.combo(keyCode: kVK_ANSI_T, modifiers: .maskAlternate, mode: .toggle)
        hk.saveTo(slot: .translate, defaults: defaults)
        let loaded = Hotkey.loadFrom(slot: .translate, defaults: defaults)
        XCTAssertEqual(loaded.mode, .hold, "translate slot 应在加载时强制 .hold")
        XCTAssertEqual(loaded, .combo(keyCode: kVK_ANSI_T, modifiers: .maskAlternate, mode: .hold))
    }

    func testV2SaveLoadRepeatLastForcesHold() {
        let hk = Hotkey.combo(keyCode: kVK_ANSI_V, modifiers: [.maskAlternate, .maskShift], mode: .toggle)
        hk.saveTo(slot: .repeatLast, defaults: defaults)
        let loaded = Hotkey.loadFrom(slot: .repeatLast, defaults: defaults)
        XCTAssertEqual(loaded.mode, .hold)
    }

    func testFirstRunDefaultMain() {
        // 既无 v2 也无 v1 → F8 默认 .fnHold
        let loaded = Hotkey.loadFrom(slot: .main, defaults: defaults)
        XCTAssertEqual(loaded, .fnHold)
    }

    func testFirstRunDefaultTranslate() {
        let loaded = Hotkey.loadFrom(slot: .translate, defaults: defaults)
        XCTAssertEqual(loaded, .combo(keyCode: 17, modifiers: .maskAlternate, mode: .hold))  // ⌥T
    }

    func testFirstRunDefaultRepeatLast() {
        let loaded = Hotkey.loadFrom(slot: .repeatLast, defaults: defaults)
        XCTAssertEqual(loaded, .combo(keyCode: kVK_ANSI_V, modifiers: [.maskAlternate, .maskShift], mode: .hold))  // ⌥⇧V
    }

    // MARK: - C 节:**F8 兼容路径** — v1 整数 → v2 enum decode

    /// 旧用户:hotkey_keyCode = -1, hotkey_modifiers = maskSecondaryFn → .modifierOnly(.fn, .hold)
    func testV1LegacyFnOnlyDecodes() {
        defaults.set(-1, forKey: "hotkey_keyCode")
        defaults.set(Int(CGEventFlags.maskSecondaryFn.rawValue), forKey: "hotkey_modifiers")
        let loaded = Hotkey.loadFrom(slot: .main, defaults: defaults)
        XCTAssertEqual(loaded, .modifierOnly(.fn, mode: .hold))
    }

    /// 旧用户:hotkey_keyCode = Space, hotkey_modifiers = .maskAlternate → .combo(Space, ⌥, .hold)
    func testV1LegacyComboDecodes() {
        defaults.set(kVK_Space, forKey: "hotkey_keyCode")
        defaults.set(Int(CGEventFlags.maskAlternate.rawValue), forKey: "hotkey_modifiers")
        let loaded = Hotkey.loadFrom(slot: .main, defaults: defaults)
        XCTAssertEqual(loaded, .combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold))
    }

    /// 旧用户:translate_hotkey_keyCode = T, modifiers = ⌥ → ⌥T 组合
    func testV1LegacyTranslateDecodes() {
        defaults.set(17, forKey: "translate_hotkey_keyCode")  // kVK_ANSI_T
        defaults.set(Int(CGEventFlags.maskAlternate.rawValue), forKey: "translate_hotkey_modifiers")
        let loaded = Hotkey.loadFrom(slot: .translate, defaults: defaults)
        XCTAssertEqual(loaded, .combo(keyCode: 17, modifiers: .maskAlternate, mode: .hold))
    }

    /// v2 存在 → 优先用 v2,忽略 v1 残留
    func testV2TakesPrecedenceOverV1() {
        // v1 留下 ⌥Space
        defaults.set(kVK_Space, forKey: "hotkey_keyCode")
        defaults.set(Int(CGEventFlags.maskAlternate.rawValue), forKey: "hotkey_modifiers")
        // v2 存了不同的 hotkey
        let v2 = Hotkey.modifierOnly(.rightCommand, mode: .toggle)
        v2.saveTo(slot: .main, defaults: defaults)
        // 应读 v2 而不是 v1
        let loaded = Hotkey.loadFrom(slot: .main, defaults: defaults)
        XCTAssertEqual(loaded, v2)
    }

    // MARK: - D 节:HotkeyConflictChecker — 系统冲突(F6=A)

    func testSystemConflictDetectsCmdSpace() {
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskCommand, mode: .hold)
        XCTAssertNotNil(HotkeyConflictChecker.systemConflict(for: hk))
    }

    func testSystemConflictDetectsCmdShiftThree() {
        let hk = Hotkey.combo(keyCode: kVK_ANSI_3, modifiers: [.maskCommand, .maskShift], mode: .hold)
        let conflict = HotkeyConflictChecker.systemConflict(for: hk)
        XCTAssertNotNil(conflict)
        XCTAssertTrue(conflict!.label.contains("截图"), "label should mention 截图")
    }

    func testSystemConflictDetectsF3MissionControl() {
        let hk = Hotkey.combo(keyCode: kVK_F3, modifiers: [], mode: .hold)
        XCTAssertNotNil(HotkeyConflictChecker.systemConflict(for: hk))
    }

    func testSystemConflictModifierOnlyNeverConflicts() {
        // modifier-only(Fn / 右⌘)裸键在系统层没占用,F6 永远 nil
        XCTAssertNil(HotkeyConflictChecker.systemConflict(for: .modifierOnly(.fn, mode: .hold)))
        XCTAssertNil(HotkeyConflictChecker.systemConflict(for: .modifierOnly(.rightCommand, mode: .toggle)))
    }

    func testSystemConflictNonConflictingComboReturnsNil() {
        // ⌥Space 不在黑名单 — 应返回 nil
        let hk = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertNil(HotkeyConflictChecker.systemConflict(for: hk))
    }

    // MARK: - D 节:HotkeyConflictChecker — 内部冲突(F7=C)

    func testInternalConflictSameModifierOnly() {
        // 两个 modifier-only 都是 Fn → 冲突
        XCTAssertTrue(HotkeyConflictChecker.hotkeyOverlap(
            .modifierOnly(.fn, mode: .hold),
            .modifierOnly(.fn, mode: .toggle)
        ))
    }

    func testInternalConflictDifferentModifierOnly() {
        // Fn vs 右⌘ → 不冲突
        XCTAssertFalse(HotkeyConflictChecker.hotkeyOverlap(
            .modifierOnly(.fn, mode: .hold),
            .modifierOnly(.rightCommand, mode: .hold)
        ))
    }

    func testInternalConflictLeftVsRightSameModifier() {
        // 左⌘ vs 右⌘ → 当前简化策略:不同 ModifierKey case 即不冲突
        XCTAssertFalse(HotkeyConflictChecker.hotkeyOverlap(
            .modifierOnly(.leftCommand, mode: .hold),
            .modifierOnly(.rightCommand, mode: .hold)
        ))
    }

    func testInternalConflictModifierOnlyVsComboSameModifier() {
        // .modifierOnly(.fn) vs .combo(Space, fn) — combo 用 Fn 作为唯一 modifier → 冲突
        XCTAssertTrue(HotkeyConflictChecker.hotkeyOverlap(
            .modifierOnly(.fn, mode: .hold),
            .combo(keyCode: kVK_Space, modifiers: .maskSecondaryFn, mode: .hold)
        ))
    }

    func testInternalConflictModifierOnlyVsComboDifferentModifier() {
        // .modifierOnly(.fn) vs .combo(Space, ⌥) — combo 没用 Fn → 不冲突
        XCTAssertFalse(HotkeyConflictChecker.hotkeyOverlap(
            .modifierOnly(.fn, mode: .hold),
            .combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        ))
    }

    func testInternalConflictExactCombo() {
        // ⌥Space vs ⌥Space → 冲突
        XCTAssertTrue(HotkeyConflictChecker.hotkeyOverlap(
            .combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold),
            .combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .toggle)
        ))
    }

    func testInternalConflictSupersetCombo() {
        // F7=C 超集语义:⌘V vs ⌘⇧V → 冲突(子集/超集相交)
        XCTAssertTrue(HotkeyConflictChecker.hotkeyOverlap(
            .combo(keyCode: kVK_ANSI_V, modifiers: .maskCommand, mode: .hold),
            .combo(keyCode: kVK_ANSI_V, modifiers: [.maskCommand, .maskShift], mode: .hold)
        ))
    }

    func testInternalConflictDifferentKeyNoConflict() {
        // ⌘V vs ⌘C → 不同 key,不冲突
        XCTAssertFalse(HotkeyConflictChecker.hotkeyOverlap(
            .combo(keyCode: kVK_ANSI_V, modifiers: .maskCommand, mode: .hold),
            .combo(keyCode: kVK_ANSI_C, modifiers: .maskCommand, mode: .hold)
        ))
    }

    // MARK: - D 节:main + trigger 冲突(F7=C 附加)

    func testMainConflictsWithTriggerWhenOverlapping() {
        // main = combo(V, ⌥⇧),trigger = ⇧ → main 占用 ⇧,trigger 冲突
        let main = Hotkey.combo(keyCode: kVK_ANSI_V, modifiers: [.maskAlternate, .maskShift], mode: .hold)
        XCTAssertTrue(HotkeyConflictChecker.mainConflictsWithTrigger(main: main, triggerMask: .maskShift))
    }

    func testMainConflictsWithTriggerNoOverlap() {
        // main = combo(Space, ⌥),trigger = ⇧ → 不冲突
        let main = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)
        XCTAssertFalse(HotkeyConflictChecker.mainConflictsWithTrigger(main: main, triggerMask: .maskShift))
    }

    func testMainConflictsWithTriggerDisabled() {
        // trigger = nil → 永远不冲突
        let main = Hotkey.modifierOnly(.fn, mode: .hold)
        XCTAssertFalse(HotkeyConflictChecker.mainConflictsWithTrigger(main: main, triggerMask: nil))
    }

    func testMainConflictsWithTriggerModifierOnly() {
        // main = .modifierOnly(.fn),trigger = .fn → main 占用 fn,trigger 冲突
        let main = Hotkey.modifierOnly(.fn, mode: .hold)
        XCTAssertTrue(HotkeyConflictChecker.mainConflictsWithTrigger(main: main, triggerMask: .maskSecondaryFn))
    }
}
