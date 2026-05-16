import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - HotkeyMode

/// 录音热键的触发模式(F2=C 只对 main 录音键有意义).
/// - `hold`: 按住说话,松开停止(传统 push-to-talk)
/// - `toggle`: 单击切换,再按一次停止(F3 30 分钟硬超时保护)
enum HotkeyMode: String, Codable, CaseIterable, Sendable {
    case hold
    case toggle

    var displayName: String {
        switch self {
        case .hold: return "按住说话"
        case .toggle: return "单击切换"
        }
    }
}

// MARK: - ModifierKey

/// 单 modifier 键 — 左右独立编码(F4=B,用 flagsChanged 事件的物理 keyCode 区分).
///
/// 物理 keyCode 速查(Carbon HIToolbox):
/// - Fn (Globe)        = 63 (kVK_Function)
/// - 左 ⌘               = 55 (kVK_Command)
/// - 右 ⌘               = 54 (kVK_RightCommand)
/// - 左 ⇧               = 56 (kVK_Shift)
/// - 右 ⇧               = 60 (kVK_RightShift)
/// - 左 ⌥               = 58 (kVK_Option)
/// - 右 ⌥               = 61 (kVK_RightOption)
/// - 左 ⌃               = 59 (kVK_Control)
/// - 右 ⌃               = 62 (kVK_RightControl)
enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case fn
    case leftCommand, rightCommand
    case leftOption, rightOption
    case leftShift, rightShift
    case leftControl, rightControl

    /// CGEventTap flagsChanged 事件的物理 keyCode
    var physicalKeyCode: Int {
        switch self {
        case .fn: return 63
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftControl: return 59
        case .rightControl: return 62
        }
    }

    /// CGEventFlags 中,此 modifier 处于按下状态时对应的 bit.
    /// 注意:CGEventFlags 无法区分左右(.maskCommand 对左右 ⌘ 都设),区分必须看 physicalKeyCode.
    var flagMask: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftShift, .rightShift: return .maskShift
        case .leftOption, .rightOption: return .maskAlternate
        case .leftControl, .rightControl: return .maskControl
        }
    }

    var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .leftCommand: return "左⌘"
        case .rightCommand: return "右⌘"
        case .leftShift: return "左⇧"
        case .rightShift: return "右⇧"
        case .leftOption: return "左⌥"
        case .rightOption: return "右⌥"
        case .leftControl: return "左⌃"
        case .rightControl: return "右⌃"
        }
    }

    /// 给定 flagsChanged 事件的物理 keyCode + 当前 flags,返回对应的 ModifierKey(若识别).
    /// 用于 keypicker 录入态识别"用户按了哪个 modifier".
    static func from(physicalKeyCode: Int) -> ModifierKey? {
        return ModifierKey.allCases.first { $0.physicalKeyCode == physicalKeyCode }
    }
}

// MARK: - Hotkey

/// 全局快捷键定义.两种 case:
/// - `modifierOnly`: 单 modifier 键(Fn / 左右 ⌘⌥⇧⌃)— 通过 flagsChanged 事件状态机检测
/// - `combo`: 主键 + modifier 组合(如 ⌥Space / ⌘⇧V)— 通过 keyDown/keyUp 检测
///
/// `mode` 字段语义只对 main 录音键有意义(F2=C);translate / repeatLast 强制 `.hold`.
enum Hotkey: Equatable, Sendable {
    case modifierOnly(ModifierKey, mode: HotkeyMode)
    case combo(keyCode: Int, modifiers: CGEventFlags, mode: HotkeyMode)

    // MARK: 静态预设

    /// F8 默认:Fn + hold(升级用户走 v1 兼容路径,首次用户拿这个)
    static let fnHold = Hotkey.modifierOnly(.fn, mode: .hold)
    static let optionSpaceHold = Hotkey.combo(keyCode: kVK_Space, modifiers: .maskAlternate, mode: .hold)

    // MARK: 派生属性

    var mode: HotkeyMode {
        switch self {
        case .modifierOnly(_, let m), .combo(_, _, let m): return m
        }
    }

    var isModifierOnly: Bool {
        if case .modifierOnly = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .modifierOnly(let mk, _):
            return mk.displayName
        case .combo(let kc, let mods, _):
            var parts: [String] = []
            if mods.contains(.maskControl) { parts.append("⌃") }
            if mods.contains(.maskAlternate) { parts.append("⌥") }
            if mods.contains(.maskShift) { parts.append("⇧") }
            if mods.contains(.maskCommand) { parts.append("⌘") }
            if mods.contains(.maskSecondaryFn) { parts.append("Fn+") }
            parts.append(Self.keyName(kc))
            return parts.joined()
        }
    }

    /// 仅修改 mode 字段,其他不变(用于 UI segmented control 切换)
    func with(mode newMode: HotkeyMode) -> Hotkey {
        switch self {
        case .modifierOnly(let mk, _): return .modifierOnly(mk, mode: newMode)
        case .combo(let kc, let mods, _): return .combo(keyCode: kc, modifiers: mods, mode: newMode)
        }
    }

    /// 此 hotkey 占用的 modifier mask — 用于 TranslationSettings.conflictingTriggers 对接.
    /// modifierOnly 返回该 modifier 自身的 flagMask;combo 返回 modifiers 字段.
    var modifierMask: CGEventFlags {
        switch self {
        case .modifierOnly(let mk, _): return mk.flagMask
        case .combo(_, let mods, _): return mods
        }
    }

    // MARK: 事件匹配(combo case 专用)

    /// 包含匹配:flags 包含全部要求的 modifiers(允许多余 modifier).
    /// 用于 main hotkey 的 press 判定.
    func comboMatches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard case .combo(let kc, let mods, _) = self else { return false }
        return keyCode == Int64(kc) && flags.contains(mods)
    }

    /// 严格匹配:modifier mask 必须完全相同(防 ⌘⌥T 误触发 ⌥T).
    /// 用于 translate / repeatLast 的 tap-trigger 判定.
    func comboMatchesExact(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard case .combo(let kc, let mods, _) = self else { return false }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        return keyCode == Int64(kc) && flags.intersection(relevant) == mods.intersection(relevant)
    }

    /// modifier 是否仍被按住 — 用于 keyUp 时判断要不要走 fallback stop 路径.
    func comboModifierStillHeld(flags: CGEventFlags) -> Bool {
        guard case .combo(_, let mods, _) = self else { return false }
        return flags.contains(mods)
    }

    // MARK: keyName

    /// Carbon virtual key code 转显示字符
    static func keyName(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Esc"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        default:
            if let char = keyCodeToChar(keyCode) {
                return char.uppercased()
            }
            return "Key(\(keyCode))"
        }
    }

    private static func keyCodeToChar(_ code: Int) -> String? {
        guard let sourceRef = TISCopyCurrentASCIICapableKeyboardLayoutInputSource() else { return nil }
        let source = sourceRef.takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            UCKeyTranslate(ptr, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
        }
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: - Codable

extension Hotkey: Codable {
    private enum CodingKeys: String, CodingKey {
        case variant, modifier, keyCode, modifiers, mode
    }

    private enum Variant: String, Codable {
        case modifierOnly
        case combo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let variant = try c.decode(Variant.self, forKey: .variant)
        let mode = try c.decodeIfPresent(HotkeyMode.self, forKey: .mode) ?? .hold
        switch variant {
        case .modifierOnly:
            let mk = try c.decode(ModifierKey.self, forKey: .modifier)
            self = .modifierOnly(mk, mode: mode)
        case .combo:
            let kc = try c.decode(Int.self, forKey: .keyCode)
            let modRaw = try c.decode(UInt64.self, forKey: .modifiers)
            self = .combo(keyCode: kc, modifiers: CGEventFlags(rawValue: modRaw), mode: mode)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modifierOnly(let mk, let mode):
            try c.encode(Variant.modifierOnly, forKey: .variant)
            try c.encode(mk, forKey: .modifier)
            try c.encode(mode, forKey: .mode)
        case .combo(let kc, let mods, let mode):
            try c.encode(Variant.combo, forKey: .variant)
            try c.encode(kc, forKey: .keyCode)
            try c.encode(mods.rawValue, forKey: .modifiers)
            try c.encode(mode, forKey: .mode)
        }
    }
}

// MARK: - 持久化(v2 JSON + v1 兼容 fallback,F8=B)

extension Hotkey {
    /// 三个持久化槽位.每个 slot 是一对 (v2 key, v1 legacy keyCode key, v1 legacy modifiers key).
    enum Slot {
        case main, translate, repeatLast

        var v2Key: String {
            switch self {
            case .main: return "hotkey_v2"
            case .translate: return "translate_hotkey_v2"
            case .repeatLast: return "repeat_last_hotkey_v2"
            }
        }

        var legacyKeyCodeKey: String {
            switch self {
            case .main: return "hotkey_keyCode"
            case .translate: return "translate_hotkey_keyCode"
            case .repeatLast: return "repeat_last_hotkey_keyCode"
            }
        }

        var legacyModifiersKey: String {
            switch self {
            case .main: return "hotkey_modifiers"
            case .translate: return "translate_hotkey_modifiers"
            case .repeatLast: return "repeat_last_hotkey_modifiers"
            }
        }

        /// 首次启动默认值(无 v1 也无 v2 时返回)
        var firstRunDefault: Hotkey {
            switch self {
            case .main: return .fnHold  // F8: Fn + hold
            case .translate:
                return .combo(keyCode: 17, modifiers: .maskAlternate, mode: .hold)  // ⌥T
            case .repeatLast:
                return .combo(keyCode: kVK_ANSI_V, modifiers: [.maskAlternate, .maskShift], mode: .hold)  // ⌥⇧V
            }
        }
    }

    /// 加载 main 录音键(向后兼容旧 UserDefaults)
    static func load() -> Hotkey { loadFrom(slot: .main) }
    static func loadTranslateHotkey() -> Hotkey { loadFrom(slot: .translate) }
    static func loadRepeatLastHotkey() -> Hotkey { loadFrom(slot: .repeatLast) }

    static func loadFrom(slot: Slot, defaults: UserDefaults = .standard) -> Hotkey {
        // v2 优先:JSON-encoded Hotkey
        if let data = defaults.data(forKey: slot.v2Key),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) {
            // translate/repeatLast 在数据层兜底强制 .hold(F2=C 语义)
            if slot == .translate || slot == .repeatLast {
                return decoded.with(mode: .hold)
            }
            return decoded
        }
        // v1 fallback:旧 keyCode + modifiers 整数对
        if defaults.object(forKey: slot.legacyKeyCodeKey) != nil {
            let kc = defaults.integer(forKey: slot.legacyKeyCodeKey)
            let modRaw = UInt64(defaults.integer(forKey: slot.legacyModifiersKey))
            let flags = CGEventFlags(rawValue: modRaw)
            // 旧 Fn-only 编码:keyCode == -1 && flags 含 maskSecondaryFn
            if kc == -1 && flags.contains(.maskSecondaryFn) {
                return .modifierOnly(.fn, mode: .hold)
            }
            // 其他都是 combo
            return .combo(keyCode: kc, modifiers: flags, mode: .hold)
        }
        // 首次启动 — 用 slot 默认
        return slot.firstRunDefault
    }

    func save() { saveTo(slot: .main) }
    func saveAsTranslateHotkey() { saveTo(slot: .translate) }
    func saveAsRepeatLastHotkey() { saveTo(slot: .repeatLast) }

    func saveTo(slot: Slot, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: slot.v2Key)
    }
}
