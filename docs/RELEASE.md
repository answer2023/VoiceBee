# 发版指南

VoiceBee 发版是**本机手动流程**:`scripts/release.sh` 构建/校验/签名,双仓库分发。
没有 CI 自动发版 —— 曾经的 release.yml(2026-05,双仓库改造前的产物)发布目标指向
private 主仓库、会重演 v1.2.1 的公开 404 事故,且要求把 Sparkle 私钥导出进 GitHub
Secrets,已于 2026-07 删除。将来若重建自动化,以本文档的双仓库模型为准。

---

## 双仓库模型(为什么发版分两个仓库)

| 仓库 | 可见性 | 放什么 |
|---|---|---|
| `answer2023/VoiceBee` | private | 源码、本文档、release.sh |
| `answer2023/VoiceBee-Releases` | **public** | DMG release asset + `appcast.xml` |

Sparkle 自动更新和官网下载按钮必须公开可访问;private 仓库的 release URL 对未登录
用户全部 404。细节与踩坑时间线见 CLAUDE.md「仓库结构」节。

- **SUFeedURL**(app 内嵌):`https://raw.githubusercontent.com/answer2023/VoiceBee-Releases/main/appcast.xml`
- 每个 release 上传**两个字节一致的 DMG**:`VoiceBee-X.Y.Z.dmg`(Sparkle enclosure 引用)
  + `VoiceBee.dmg`(jotbee.app 网站 latest 直链)

---

## 日常发版

```bash
# 0. bump 版本号(唯一 source of truth 是 Info.plist,project.yml 里没有版本键)
#    - CFBundleShortVersionString: X.Y.Z
#    - CFBundleVersion: 严格递增的整数(Sparkle 靠它判定升级)
open VoiceJar/Info.plist

# 1. 跑发版脚本
./scripts/release.sh X.Y.Z
```

脚本会依次:xcodegen + Release build → **版本号校验**(构建产物的
CFBundleShortVersionString 必须等于脚本参数,否则 abort;并对比线上 appcast 检查
CFBundleVersion 递增,warning 级)→ 打 DMG → 公证(仅当 `voicebee-notary` profile
已配置,当前未配置则跳过)→ Sparkle 签名 → 生成 latest 字节副本 → 打印可直接粘贴的
appcast `<item>` 片段和后续手工步骤。

```bash
# 2. 按脚本尾部输出执行三步:
#    a. VoiceBee-Releases: appcast.xml 的 <channel> 顶部前置新 <item>,commit + push
#    b. 主仓库: commit 版本 bump + 打 tag
#    c. VoiceBee-Releases 的 GitHub Releases: 建 vX.Y.Z,上传两个 DMG
```

发布后验证:

```bash
# 线上 appcast 生效(raw CDN 缓存 ≤5 分钟)
curl -s https://raw.githubusercontent.com/answer2023/VoiceBee-Releases/main/appcast.xml | head -30
```

---

## Sparkle 密钥纪律

- **私钥只存在于本机 macOS Keychain**(service `https://sparkle-project.org`),
  `sign_update` 自动读取。**不要**导出到文件、GitHub Secrets 或任何其他位置。
- **`SUPublicEDKey` 永远不能换**:换了所有旧版用户拒收新签名,自动更新链路永久断。
- 私钥泄漏 = 攻击者可签发恶意更新静默推给全部用户;怀疑泄漏立即重新生成密钥对
  并紧急通知用户手动更新(公钥变更意味着自动更新断链,只能走手动)。

---

## 公证(当前未启用)

现状:DMG 未签 Developer ID、未公证。影响仅限**新用户浏览器下载后首次双击安装**
被 Gatekeeper 拦(需右键→打开);Sparkle 自动更新走独立的 EdDSA 验签,不受影响。

启用公证的前置清单(一次性,配齐后 release.sh 第 4 步自动生效):

1. Apple Developer 账号 + **Developer ID Application** 证书(装入本机 Keychain)
2. [appleid.apple.com](https://appleid.apple.com/account/manage) 生成 App-Specific Password,然后:
   ```bash
   xcrun notarytool store-credentials voicebee-notary \
     --apple-id "你的@apple.id" --team-id "TEAM_ID" --password "app-specific-password"
   ```
3. `project.yml` 把 `ENABLE_HARDENED_RUNTIME` 改为 `true`(公证硬性要求;
   entitlements 已备好 `audio-input` + `network.client`,理论兼容,改后需真机回归
   麦克风 / CGEventTap / Sparkle 三条链路)
4. xcodebuild 需带 Developer ID 签名身份(不再是 ad-hoc)

附带收益:Developer ID 固定证书签名后,覆盖安装不再丢 Accessibility 权限
(TCC 按签名而非 inode 识别 app,见 CLAUDE.md「重装后 Accessibility 权限」节)。

---

## 故障排查

| 现象 | 可能原因 |
|---|---|
| release.sh 报"版本号不一致" | 忘 bump Info.plist;脚本读的是构建产物里的版本 |
| release.sh 警告 build 号未递增 | CFBundleVersion 没加;Sparkle 客户端将不提示更新 |
| 用户更新时报 "Update has invalid signature" | appcast 里的 edSignature/length 与 DMG 不匹配;必须用 sign_update 输出原文 |
| 用户首次安装报"无法验证开发者" | 未公证(当前已知状态);右键→打开绕过 |
| 老用户检查更新拉到旧版 | appcast.xml 没 push 到 VoiceBee-Releases,或 raw CDN 缓存未过期(≤5 分钟) |
| 找不到 sign_update | 先在 Xcode 里 build 一次让 SPM 解析 Sparkle 包 |
