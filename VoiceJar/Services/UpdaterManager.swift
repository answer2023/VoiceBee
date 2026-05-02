import Foundation
import Sparkle
import AppKit

/// Sparkle 自动更新封装
/// SUPublicEDKey 留空时仅运行未签名检查；正式发版必须填入 ed25519 公钥（用 sparkle 的 generate_keys 工具生成）。
@MainActor
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()

    let controller: SPUStandardUpdaterController

    override init() {
        // startingUpdater: true 让 Sparkle 在 App 启动后自动开始周期性检查
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// 用户主动触发"检查更新"
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 当前是否允许检查（Sparkle 在前几秒内可能尚未就绪）
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
