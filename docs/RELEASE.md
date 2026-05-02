# 发版指南

VoiceBee 用 GitHub Actions 自动化发版。日常发版只需两步：

```bash
# 1. 改 VoiceJar/Info.plist 的 CFBundleShortVersionString 和 CFBundleVersion
# 2. 推标签
git tag v1.2.0
git push --tags
```

CI 会自动：构建 Release → 用 Apple Developer ID 签名 → 公证 → Sparkle 签名 → 生成 appcast.xml → 创建 GitHub Release 上传 .dmg + appcast.xml。

下面是首次配置 secrets 的步骤（**只需做一次**）。

---

## 一、Sparkle 私钥（必须）

Sparkle 用 ed25519 签名验证更新包。私钥已经在你本机 Keychain（service `https://sparkle-project.org`）。

```bash
# 找到 generate_keys 工具
SPARKLE=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f -path "*Sparkle*" | head -1)

# 把私钥导出到临时文件（base64 字符串）
"$SPARKLE" -x /tmp/sparkle_priv.key
cat /tmp/sparkle_priv.key   # 复制完整内容
rm /tmp/sparkle_priv.key    # 立刻删除！
```

到 GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**：

| Name | Value |
|---|---|
| `SPARKLE_ED_PRIVATE_KEY` | 上一步 cat 输出的完整 base64 字符串 |

⚠️ **私钥泄漏 = 攻击者可以签发恶意更新让所有用户静默自动安装**。永远不要 commit、截图、转发；如果怀疑泄漏立刻 `generate_keys -f`（或手动删 Keychain 条目）重新生成 + 紧急更新所有用户。

---

## 二、Apple Developer ID 证书（必须，否则 Gatekeeper 拦截）

### 2.1 获取证书

1. 你需要一个 [Apple Developer 账号](https://developer.apple.com/) — 个人 99 美元/年
2. 登录 [Apple Developer Certificates](https://developer.apple.com/account/resources/certificates) → 创建一个 **Developer ID Application** 证书
3. 在 Keychain Access 里找到证书 → 右键 → 导出 → 选择 `.p12` 格式 → 设一个密码
4. 把 .p12 文件转成 base64：

```bash
base64 -i ~/Downloads/voicebee_cert.p12 | pbcopy
# 内容已复制到剪贴板
```

### 2.2 添加 secrets

| Name | Value |
|---|---|
| `APPLE_CERT_P12_BASE64` | 上一步 base64 内容 |
| `APPLE_CERT_PASSWORD` | 你设的 .p12 密码 |
| `APPLE_TEAM_ID` | 10 字符 Team ID（在 [Apple Developer Account](https://developer.apple.com/account#MembershipDetailsCard) 看到）|

---

## 三、Notarytool 公证账号（必须）

Apple 公证服务需要 App-Specific Password（不是你的 Apple ID 密码）。

1. 到 [appleid.apple.com](https://appleid.apple.com/account/manage) → Sign-In and Security → App-Specific Passwords → 生成一个，命名比如 `voicebee-ci`
2. 添加 secrets：

| Name | Value |
|---|---|
| `APPLE_ID` | 你的 Apple Developer 账号邮箱 |
| `APPLE_APP_PASSWORD` | 上一步生成的 App-Specific Password（形如 `xxxx-xxxx-xxxx-xxxx`）|

注意：`APPLE_TEAM_ID` 在 §2.2 已经加过，公证步骤复用同一个 secret。

---

## 四、首次发版（v1.2.0）

配置完上述 4 个 secret 后，第一次发版：

```bash
# 1. 确认 Info.plist 版本号已 bump（v1.2.0 已经 bump 到 1.2.0 + build 7）
grep -A1 CFBundleShortVersionString VoiceJar/Info.plist

# 2. 推 tag 触发 workflow
git tag v1.2.0
git push origin v1.2.0
```

到 GitHub Actions 页看进度。约 10-15 分钟后会出现 v1.2.0 release，包含：
- `VoiceBee-1.2.0.dmg`（已签名 + 公证 + Sparkle 签名）
- `appcast.xml`

旧版用户的「检查更新」按钮就能拉到这个版本了。

---

## 五、本机手工发版（应急）

如果 GitHub Actions 出问题或你想本机控制流程：

```bash
# 配置 notarytool keychain profile（一次性）
xcrun notarytool store-credentials voicebee-notary \
  --apple-id "你的@apple.id" \
  --team-id "TEAM_ID_10字符" \
  --password "App-Specific-Password"

# 跑发版脚本
./scripts/release.sh 1.2.0
```

脚本会输出 appcast 的 `<item>` XML 片段供你手工填到 `appcast.xml` 里。

---

## 故障排查

| 现象 | 可能原因 |
|---|---|
| Workflow 在 "Notarize" 步骤超时 | App-Specific Password 失效 / Team ID 错 |
| 用户更新时报 "Update has invalid signature" | `SUPublicEDKey` 与 CI 用的私钥不匹配；检查 Info.plist 公钥 vs `SPARKLE_ED_PRIVATE_KEY` 来自同一个 keypair |
| 用户首次安装报 "无法验证开发者" | 没有公证或公证失败；检查 Notarize 日志 |
| 老用户检查更新拉到的还是旧版 | appcast.xml 没上传；检查 release assets 里有 appcast.xml |
| 跑 `gh release create` 提示 release 已存在 | tag 已存在历史 release；先 `gh release delete v<version>` 或换版本号 |
