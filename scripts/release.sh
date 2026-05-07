#!/usr/bin/env bash
# 本机发版脚本 — 用于不通过 GitHub Actions 时手工发版
# 用法：scripts/release.sh 1.2.0
#
# 前置条件：
#   - 已生成 Sparkle 密钥（generate_keys 已跑过）
#   - macOS Keychain 里有 Sparkle private key（service: https://sparkle-project.org）
#   - 已配置 Apple Developer ID 证书 + notarytool keychain profile（如需公证）
#   - Info.plist CFBundleShortVersionString 已 bump 到目标版本

set -euo pipefail

VERSION="${1:?用法: $0 <版本号>，例如：$0 1.2.0}"
BUILD_DIR="$(pwd)/build"
APP_NAME="VoiceBee"
DMG="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

# 1. 找 Sparkle 工具
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f -path "*sparkle*Sparkle/bin*" 2>/dev/null | head -1 | xargs dirname)
if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ 找不到 Sparkle bin 目录。先在 Xcode 里 build 一次让 SPM 解析 Sparkle。"
    exit 1
fi
echo "Sparkle bin: $SPARKLE_BIN"

# 2. xcodegen + Release build
echo "▶️ 构建 Release..."
xcodegen
xcodebuild \
    -project VoiceJar.xcodeproj \
    -scheme VoiceJar \
    -configuration Release \
    -destination 'platform=macOS' \
    clean build

BUILT_APP="$HOME/Library/Developer/Xcode/DerivedData/VoiceJar-amglfhrjtqgcknbosdsdlmufiwri/Build/Products/Release/${APP_NAME}.app"

# 3. 打包 .dmg（用 hdiutil 简单方案；想要美化 DMG 可以改用 create-dmg）
echo "▶️ 打包 .dmg..."
mkdir -p "$BUILD_DIR"
rm -f "$DMG"
hdiutil create -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "$BUILT_APP" \
    -ov -format UDZO \
    "$DMG"

# 4. 公证（可选；需要 notarytool keychain profile，跳过则跳过）
if xcrun notarytool history --keychain-profile "voicebee-notary" >/dev/null 2>&1; then
    echo "▶️ 提交公证..."
    xcrun notarytool submit "$DMG" --keychain-profile "voicebee-notary" --wait
    xcrun stapler staple "$DMG"
else
    echo "⚠️ 跳过公证（未配置 voicebee-notary keychain profile）"
    echo "   配置方法见 README.md → 维护者发版清单"
fi

# 5. Sparkle 签名
echo "▶️ Sparkle 签名 .dmg..."
SIGNATURE_LINE=$("$SPARKLE_BIN/sign_update" "$DMG")
echo "  $SIGNATURE_LINE"
SIZE=$(stat -f%z "$DMG")

# 6. Latest 直链副本(供 jotbee.app 网站下载按钮的永久 URL）— 字节级一致 = EdDSA 签名同样有效
DMG_LATEST="$BUILD_DIR/${APP_NAME}.dmg"
cp "$DMG" "$DMG_LATEST"
echo "▶️ 已生成 latest 副本：$DMG_LATEST"

# 7. 输出 appcast item 模板
cat <<EOF

✅ 构建完成：$DMG ($SIZE bytes)
✅ Latest 副本：$DMG_LATEST（字节同上）

将下面这段 <item> 填进 ~/Developer/VoiceBee-Releases/appcast.xml 的 <channel> 顶部（最新版置顶）：

            <item>
                <title>v${VERSION}</title>
                <description><![CDATA[
                    <h2>v${VERSION}</h2>
                    <ul><li>TODO: 在这里写 release notes</li></ul>
                ]]></description>
                <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
                <sparkle:version>$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" VoiceJar/Info.plist)</sparkle:version>
                <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                <enclosure
                    url="https://github.com/answer2023/VoiceBee-Releases/releases/download/v${VERSION}/${APP_NAME}-${VERSION}.dmg"
                    ${SIGNATURE_LINE}
                    length="${SIZE}"
                    type="application/octet-stream" />
            </item>

双仓库发版步骤（手工）：
1. 在 VoiceBee-Releases 更新 appcast.xml（Sparkle 用）：
     cd ~/Developer/VoiceBee-Releases
     # 把上面 <item> 填进 appcast.xml 的 <channel> 顶部
     git add appcast.xml && git commit -m "v${VERSION} release" && git push origin main

2. 在 VoiceBee 主仓库 commit + 打 tag：
     cd ~/Developer/VoiceBee
     git add VoiceJar/Info.plist VoiceJar.xcodeproj
     git commit -m "release: v${VERSION}"
     git tag v${VERSION} && git push origin master --tags

3. 在 VoiceBee-Releases 仓库的 GitHub Releases 创建 v${VERSION}，附两个 DMG asset：
     - $DMG          ← 版本化 DMG，Sparkle appcast 的 enclosure 引用此 URL
     - $DMG_LATEST   ← Latest 直链 DMG，网站下载按钮 (jotbee.app/voicebee.html) 引用此 URL
EOF
