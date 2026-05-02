import Foundation
import Sparkle
import AppKit

/// Sparkle 自动更新封装
/// SUPublicEDKey 为空时认为「未配置」— updater 不启动，UI 应隐藏检查更新按钮。
/// 正式发版前用 Sparkle 的 generate_keys 工具生成 ed25519 密钥对，把公钥贴进 Info.plist。
@MainActor
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()

    let controller: SPUStandardUpdaterController

    /// Sparkle 是否已正确配置（SUPublicEDKey 非空）
    static let isConfigured: Bool = {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.trimmingCharacters(in: .whitespaces).isEmpty
    }()

    override init() {
        // 只在配置就绪时让 Sparkle 启动 updater；否则创建一个不启动的 controller
        // （避免空公钥情况下 Sparkle 内部抛错）
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// 用户主动触发"检查更新"
    func checkForUpdates() {
        guard Self.isConfigured else {
            VJLog.log("⚠️ Sparkle 未配置（SUPublicEDKey 为空），忽略检查更新", prefix: "Updater")
            return
        }
        controller.checkForUpdates(nil)
    }

    /// 当前是否允许检查
    var canCheckForUpdates: Bool {
        Self.isConfigured && controller.updater.canCheckForUpdates
    }
}
