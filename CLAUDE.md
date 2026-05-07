# VoiceBee — Claude 协作笔记

> 项目级笔记,记录从代码里看不出来的事实和决策理由。Session 启动加载,辅助以后做发版/调试。

---

## 仓库结构(双仓库)

| 仓库 | 路径 | 可见性 | 用途 |
|---|---|---|---|
| 代码 | `~/Developer/VoiceBee/` → `answer2023/VoiceBee` | **private** | 所有 Swift 源码、project.yml、CI、本文件 |
| 发布 | `~/Developer/VoiceBee-Releases/` → `answer2023/VoiceBee-Releases` | **public** | DMG installer + Sparkle `appcast.xml` + 公开 README |

**为什么分仓库**:Sparkle 自动更新链路和官网下载按钮**必须公开可访问**。如果 release artifact 留在 private 主仓库,GitHub 给未登录用户的 `releases/...` URL 全部 404,Sparkle 拉不到 appcast,在线更新链路彻底断。

**踩坑时间线**:v1.2.1 发版用的还是 private repo 内 release(`https://github.com/answer2023/VoiceBee/releases/latest/download/appcast.xml`)。事后发现公开 404 → 改为双仓库 → v1.2.2 起 SUFeedURL 切到 `raw.githubusercontent.com/answer2023/VoiceBee-Releases/main/appcast.xml`。

---

## 版本号在哪(只在 Info.plist)

`VoiceJar/Info.plist` 是版本号的 **source of truth**:

- `CFBundleShortVersionString` = 营销版本号 (e.g. `1.2.2`)
- `CFBundleVersion` = build 号 (e.g. `9`,**必须严格递增**,Sparkle 用它判定升级)

`project.yml` **不放** `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`(整个仓库 grep 不到这两个 key)。改版本号只动 Info.plist;改 project.yml 没用。

`scripts/release.sh:78` 用 `/usr/libexec/PlistBuddy -c "Print CFBundleVersion" VoiceJar/Info.plist` 印证此唯一来源。

---

## Sparkle 关键事实

- **EdDSA 公钥 hardcoded 在 Info.plist `SUPublicEDKey`**(当前 `9Kamhj8ehbcRIXsfW+2umemdqSuIbeU+0wZm2uNd2M0=`)。**永远不能换**,换了所有旧版用户拒收新签名 → 自动更新断。
- **EdDSA 私钥**在 macOS Keychain,service `https://sparkle-project.org`。`sign_update` 自动从那里读。
- **`sign_update` 工具不在 PATH**:在 `~/Library/Developer/Xcode/DerivedData/VoiceJar-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`。`scripts/release.sh:19` 用 find 自动定位。
- **Sparkle 不依赖 macOS 公证**:它走自己的 EdDSA,公证只影响"用户从浏览器双击安装 DMG"这条路径(Gatekeeper)。两条链路独立。

### SUFeedURL = raw.githubusercontent.com 的设计理由

当前值: `https://raw.githubusercontent.com/answer2023/VoiceBee-Releases/main/appcast.xml`

为什么不用更"规范"的 `releases/latest/download/appcast.xml`?

| 维度 | raw URL(选用) | release asset URL |
|---|---|---|
| push appcast 修改后生效 | ≤ 5 分钟(CDN `max-age=300`) | 必须打新 release tag + 上传 asset |
| 修 release notes 错字 | git push 一次 | 重打 release |
| Bug fix 阶段灵活度 | 高 | 低 |

代价:CDN 5 分钟缓存。叠加 Sparkle 默认 24 小时轮询(`SUScheduledCheckInterval=86400`),实际延迟由轮询周期主导,不感知。

---

## 完整发版流程

```bash
# === 0. 改 Info.plist 三个键 ===
# - CFBundleShortVersionString: 1.2.2 → 1.2.3
# - CFBundleVersion: 9 → 10
# - (需要时) SUFeedURL,平时不动

# === 1. 重生成 Xcode project + Release build ===
cd ~/Developer/VoiceBee
xcodegen generate
xcodebuild build -scheme VoiceJar -configuration Release \
  -allowProvisioningUpdates -derivedDataPath build/
# 产物: build/Build/Products/Release/VoiceBee.app

# === 2. 验证 binary 嵌入了新版本 + 新 SUFeedURL ===
APP=build/Build/Products/Release/VoiceBee.app
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
  -c "Print CFBundleVersion" -c "Print SUFeedURL" \
  "$APP/Contents/Info.plist"
lipo -info "$APP/Contents/MacOS/VoiceBee"  # 确认 arch

# === 3. 打 DMG 到 VoiceBee-Releases/dist/(.gitignore 已挡 dist/) ===
VERSION=1.2.3
DMG=~/Developer/VoiceBee-Releases/dist/VoiceBee-${VERSION}.dmg
mkdir -p ~/Developer/VoiceBee-Releases/dist
rm -f "$DMG"
hdiutil create -volname "VoiceBee ${VERSION}" -srcfolder "$APP" \
  -ov -format UDZO "$DMG"

# === 4. Sparkle 签名 ===
SIGN=~/Library/Developer/Xcode/DerivedData/VoiceJar-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
$SIGN "$DMG"
# 输出形如:sparkle:edSignature="..." length="..."

# === 5. 更新 VoiceBee-Releases/appcast.xml ===
# - 在 <channel> 里**前置**新 <item>(让最新版排在最上面)
# - title=vX.Y.Z / pubDate=date -u +"%a, %d %b %Y %H:%M:%S +0000"
# - sparkle:version=BUILD / sparkle:shortVersionString=X.Y.Z
# - enclosure url=https://github.com/answer2023/VoiceBee-Releases/releases/download/vX.Y.Z/VoiceBee-X.Y.Z.dmg
# - sparkle:edSignature + length 用 step 4 输出粘贴

# === 6. push appcast.xml 到公开仓库 ===
cd ~/Developer/VoiceBee-Releases
git add appcast.xml  # 只这一个,DMG 在 gitignore
git commit -m "vX.Y.Z release"
git push origin main

# === 7. GitHub 网页:VoiceBee-Releases → Releases ===
# - Draft a new release
# - Tag: vX.Y.Z (Create new tag on publish)
# - Target: main
# - Title: VoiceBee X.Y.Z
# - Notes: 同 appcast description 的内容
# - Attach: 拖 dist/VoiceBee-X.Y.Z.dmg
# - Publish

# === 8. 在 VoiceBee 主仓库 commit 版本 bump ===
cd ~/Developer/VoiceBee
git add VoiceJar/Info.plist VoiceJar.xcodeproj  # xcodegen 重生了 .xcodeproj
git commit -m "release: vX.Y.Z (build N)"
git push
git tag vX.Y.Z && git push --tags  # 主仓库也打 tag,方便回溯
```

---

## arch 现状

- 当前 build **arm64-only**(`lipo -info` 输出 `Non-fat file`)
- project.yml 没设 `ARCHS`,xcodebuild 默认 `ARCHS_STANDARD` → 在 Apple Silicon 主机 + Xcode 26 上只编 arm64
- README 已写明 "Apple Silicon required"
- 想要 universal binary:project.yml 的 `targets.VoiceJar.settings.base` 加 `ARCHS: "arm64 x86_64"` + `ONLY_ACTIVE_ARCH: NO`(follow-up)

---

## 公证(notarization)现状

- **当前未公证**:v1.2.1、v1.2.2 的 DMG 都没 staple ticket(`xcrun stapler validate` 验证)
- Sparkle 自动更新不受影响(EdDSA 独立)
- 影响:**新用户首次从浏览器下载 DMG 双击安装**会被 Gatekeeper 拦,需要"右键 → 打开"绕过。README 已写
- `scripts/release.sh:48-55` 写好了 notarytool 流程,需要 `voicebee-notary` keychain profile(目前未配置)
- Follow-up:配置公证流程后,在 release.sh 里默认开启

---

## 踩坑教训速查

| 坑 | 症状 | 修复 |
|---|---|---|
| private repo + 公开 release URL | 未登录用户 404,Sparkle 拉不到 appcast | 分双仓库,release 移到公开 repo |
| 改 project.yml 想 bump 版本号 | 完全无效(此项目无 MARKETING_VERSION key) | 只改 Info.plist 三键 |
| 找不到 `sign_update` | 不在 PATH | `find ~/Library/Developer/Xcode/DerivedData -name sign_update -path "*sparkle*"` |
| appcast.xml `length` 不准 | Sparkle 验签失败,客户端"更新失败" | 用 `sign_update` 输出的 length(它就是真实 DMG 字节数) |
| 换了 EdDSA key | 旧版用户拒收新签名,自动更新永久断 | **永远不要换 SUPublicEDKey**;私钥丢了的应急见 Sparkle 文档 |
| pushed appcast 后 5 分钟内客户端没看到 | raw CDN 缓存 | 等,或客户端"立即检查更新"会绕过(Sparkle 加 cache-buster 参数) |

---

## 命令速查

```bash
# Info.plist 三个关键键
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
  -c "Print CFBundleVersion" -c "Print SUFeedURL" -c "Print SUPublicEDKey" \
  VoiceJar/Info.plist

# 实时 appcast(Sparkle 真正拉的 URL)
curl -s https://raw.githubusercontent.com/answer2023/VoiceBee-Releases/main/appcast.xml | head -30

# 检查 .app arch
lipo -info build/Build/Products/Release/VoiceBee.app/Contents/MacOS/VoiceBee

# 检查 DMG 是否公证 + staple
xcrun stapler validate <dmg>
spctl -a -t open --context context:primary-signature -v <dmg>

# 找 sign_update
find ~/Library/Developer/Xcode/DerivedData -name sign_update -path "*sparkle*Sparkle/bin*" 2>/dev/null
```
