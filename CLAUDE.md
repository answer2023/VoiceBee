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

### 双 DMG asset 策略(Sparkle vs 网站直链)

每次 release 上传**两个** DMG asset(字节级完全一致,SHA256 相同):

- **`VoiceBee-X.Y.Z.dmg`**(版本化)— **Sparkle 引用**:appcast.xml 的 `<enclosure url="...VoiceBee-X.Y.Z.dmg">` 指向此 URL,EdDSA 签名对此文件字节计算
- **`VoiceBee.dmg`**(无版本名)— **jotbee.app 网站直链**:`releases/latest/download/<filename>` 模式要求文件名跨版本稳定,所以 latest 直链 asset 名永远叫 `VoiceBee.dmg`
- 两个 DMG 字节一致(`cp` 副本)→ EdDSA 签名对两者等效有效;Sparkle 验签只走版本化 URL,浏览器下 `VoiceBee.dmg` 不验签
- `release.sh` 已自动化:hdiutil + Sparkle 签名后 `cp "$DMG" "$DMG_LATEST"`(`scripts/release.sh` section 6)

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

# === 3. 打双 DMG 到 VoiceBee-Releases/dist/(.gitignore 已挡 dist/) ===
VERSION=1.2.3
DMG=~/Developer/VoiceBee-Releases/dist/VoiceBee-${VERSION}.dmg
DMG_LATEST=~/Developer/VoiceBee-Releases/dist/VoiceBee.dmg  # 网站直链字节副本
mkdir -p ~/Developer/VoiceBee-Releases/dist
rm -f "$DMG" "$DMG_LATEST"
hdiutil create -volname "VoiceBee ${VERSION}" -srcfolder "$APP" \
  -ov -format UDZO "$DMG"
cp "$DMG" "$DMG_LATEST"  # latest 直链副本(供 jotbee.app 网站用)

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
# - Attach 两个 DMG asset:
#     - dist/VoiceBee-X.Y.Z.dmg  ← Sparkle appcast 引用此版本化 URL
#     - dist/VoiceBee.dmg         ← 网站下载按钮 latest 直链(jotbee.app/voicebee.html)
# - Publish
# - 或用 gh CLI 一次上传:gh release create vX.Y.Z dist/VoiceBee-X.Y.Z.dmg dist/VoiceBee.dmg --title "VoiceBee X.Y.Z" --notes "..."

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

### git proxy 死端口(`HTTPS_PROXY=` 也覆盖不掉)

**症状**:`git push` 报连 `127.0.0.1:XXXXX` 失败,XXXXX 是 5 位随机端口(如 61965)而非 FlClash 默认 7890;`HTTPS_PROXY=` 也覆盖不掉。

**根因**:IDE / 工具(VS Code / Cursor / Proxyman 等)给 git **global + local 两层都写死**了临时端口。git config 优先级 `local > global > ENV`,所以 ENV 清空也胜不过 git config。

**修复**:四条全 `--unset`(global / local × http / https),清后 fallback 到 ENV(7890)或 TUN。
```bash
git config --global --unset http.proxy && git config --global --unset https.proxy
git -C <repo> config --local --unset http.proxy && git -C <repo> config --local --unset https.proxy
```
**实例**:2026-05-09 push commit `13349ec` 时撞到死端口 `61965`。

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

---

## 已知 follow-up

### voicebee.tangzhihong.com:301 重定向到 jotbee.app/voicebee.html

- **当前状态**(2026-05-09 部署):Cloudflare Redirect Rule(zone `tangzhihong.com`),`voicebee.tangzhihong.com/*` → `https://jotbee.app/voicebee.html` 301。已 curl 验证四条:直接访问 / 子路径 / 查询参数保留 / redirect chain 终落 200,全通过
- **背景**:这个子域历史上是 Cloudflare Pages 独立部署的 VoiceBee 产品页。在 ClearSky 工作室主仓库重做时(`tangzhihong.com` 仓库 commit `6294da5`)被边缘化,源码已不在 git 维护,Cloudflare Pages 项目继续提供 stale 快照,且下载链是死链(指向旧 private repo URL `answer2023/VoiceBee/releases/download/v1.2.1/...`,未登录 404)
- **临时方案**:301 跳到 jotbee.app/voicebee.html,统一入口,SEO 权重也归并过去
- **未来 follow-up**:
  - 重建独立产品页(Cloudflare Pages 重新接 git 源)
  - 或迁回 GitHub Pages,跟 jotbee.app 同部署链路
  - 决策点:这个独立子域是否值得维护(取决于 SNS / 海报推广策略 — 例如海报上印 `voicebee.tangzhihong.com` 比 `jotbee.app/voicebee.html` 更短更易记)

### 专名词典注入失效

**症状**:用户在设置→词典里配了 "VoiceBee" 等专名,2026-05-11 实测 5/5 次仍被 LLM 改成 VB / Vocab / Web / 沃尔 b / Vocab 等。

**当前注入路径**(代码里数组名 `vocabTerms`):`PolishService.assemblePrompt` 把"专有名词参考"段拼到 system prompt **末尾**,段内是用户配的专名列表(VoiceBee / ClearSky / Sparkle / JotBee 等,最多 50 词)。

**疑点**:
- 词典段位置太靠后,模型 attention 衰减(虽然 num_ctx 8192 够装下)
- 或 LLM 把词典当"参考"而非"硬约束"(prompt 文字 "按上下文判断是否替换;不要强行使用")
- ASR 转录环节就错(在 polish 之前 — Whisper 输出 "Vocab" 给 LLM,LLM 看不出哪里错)

**待诊断顺序**:
1. 先看 ASR(WhisperKit / SFSpeechRecognizer)转录原文是什么 — 如果 ASR 就输出 "Vocab",那 polish 无能为力(LLM 不知道用户原意是 VoiceBee)
2. 如果 ASR 输出正确、polish 后才错 → 改进 prompt:
   - 词典段提到 prompt 前部(globalContract 之后,style prompt 之前)
   - 用强语气("MUST USE these terms verbatim" 而非"参考")
   - 加专名识别 few-shot:`input contains "vocab" but vocabulary says "VoiceBee" → output VoiceBee`

### 重装后 Accessibility 权限需重启 app 才生效

**症状**:替换 `/Applications/VoiceBee.app`(覆盖 build)后,即使系统设置里 Accessibility 已授权,VoiceBee 仍需 quit + 重新打开才能用 hotkey;否则可能 `dispatch_assert` 崩溃(AXIsProcessTrusted = false → dispatch_assert)。

**原因**:macOS 14+ 安全特性 — bundle 替换后权限数据库(TCC)需同步,新 inode 默认拿不到旧 inode 的授权。Xcode Run 启动调试版也会触发同问题。

**修复方向(短期 · 治标)**:启动时检测 `AXIsProcessTrusted()`,若 false 用 `NSAlert` 弹友好对话框引导:
- "请退出并重新打开 VoiceBee 让权限生效"
- 或直接拉起"系统设置 → 隐私与安全性 → 辅助功能"(`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`)
- 不要直接 `dispatch_assert` 崩溃 —— 这是标准 macOS UX 反模式

**根治路径(长期 · 治本)**:ad-hoc 签名(`codesign --sign -`)每次 build 签名 hash 不同,macOS TCC 数据库把这判定为"不同的 app",所以替换后权限丢失。**Developer ID 签名(固定证书)+ Apple 公证后,bundle 替换权限自动继承**,Accessibility 不再需要重新授权。
- 配置 `voicebee-notary` keychain profile + `scripts/release.sh` 走完整公证流程
- 详见上文「公证(notarization)现状」节 — 这两个 follow-up 同根:都是因为当前未走 Developer ID + 公证链路

