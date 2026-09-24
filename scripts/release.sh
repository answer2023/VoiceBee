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

# 1. 找 Sparkle 工具 — 先搜本项目 build 目录(-derivedDataPath 构建的 SPM 产物),
#    再 fallback 到 ~/Library DerivedData;排除 old_dsa_scripts 下的旧版同名脚本
SIGN_UPDATE=$(find "$BUILD_DIR" ~/Library/Developer/Xcode/DerivedData \
    -name "sign_update" -type f -path "*sparkle*Sparkle/bin*" \
    -not -path "*old_dsa*" 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    echo "❌ 找不到 sign_update。先 build 一次让 SPM 解析 Sparkle。"
    exit 1
fi
SPARKLE_BIN=$(dirname "$SIGN_UPDATE")
echo "Sparkle bin: $SPARKLE_BIN"

# 2. xcodegen + Release build
echo "▶️ 构建 Release..."
xcodegen
xcodebuild \
    -project VoiceJar.xcodeproj \
    -scheme VoiceJar \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    clean build

BUILT_APP="$BUILD_DIR/DerivedData/Build/Products/Release/${APP_NAME}.app"

# 2.5 验证构建产物版本号（从 built app 读，不读源码树 — 防止忘记 bump Info.plist）
BUILT_SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist")
BUILT_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$BUILT_APP/Contents/Info.plist")
if [ "$BUILT_SHORT_VERSION" != "$VERSION" ]; then
    echo "❌ 版本号不一致：构建产物 CFBundleShortVersionString=$BUILT_SHORT_VERSION，脚本参数=$VERSION"
    echo "   先 bump VoiceJar/Info.plist（CFBundleShortVersionString + CFBundleVersion）再重跑。"
    exit 1
fi
echo "✅ 版本号验证通过：$BUILT_SHORT_VERSION (build $BUILT_BUILD_NUMBER)"

# 2.6 对比线上 appcast 最新 build 号（仅警告不阻断；网络失败则跳过）
APPCAST_URL="https://raw.githubusercontent.com/answer2023/VoiceBee-Releases/main/appcast.xml"
if APPCAST_XML=$(curl -fsSL --max-time 15 "$APPCAST_URL" 2>/dev/null); then
    LIVE_BUILD=$(printf '%s' "$APPCAST_XML" | grep -o '<sparkle:version>[^<]*</sparkle:version>' | head -1 | sed 's/<[^>]*>//g' || true)
    if [ -z "$LIVE_BUILD" ]; then
        echo "⚠️ 无法从线上 appcast 解析 sparkle:version，跳过 build 号递增检查"
    elif [ "$BUILT_BUILD_NUMBER" -gt "$LIVE_BUILD" ] 2>/dev/null; then
        echo "✅ CFBundleVersion $BUILT_BUILD_NUMBER > 线上最新 $LIVE_BUILD"
    else
        echo "⚠️ CFBundleVersion ($BUILT_BUILD_NUMBER) 未严格大于线上 appcast 最新 sparkle:version ($LIVE_BUILD)"
        echo "   Sparkle 用 CFBundleVersion 判定升级，客户端可能不会提示更新"
    fi
else
    echo "⚠️ 拉取线上 appcast 失败，跳过 build 号递增检查：$APPCAST_URL"
fi

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
✅ Latest 副本：${DMG_LATEST}（字节同上）

将下面这段 <item> 填进 ~/Developer/VoiceBee-Releases/appcast.xml 的 <channel> 顶部（最新版置顶）：

            <item>
                <title>v${VERSION}</title>
                <description><![CDATA[
                    <h2>v${VERSION}</h2>
                    <ul><li>TODO: 在这里写 release notes</li></ul>
                ]]></description>
                <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
                <sparkle:version>${BUILT_BUILD_NUMBER}</sparkle:version>
                <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                <enclosure
                    url="https://github.com/answer2023/VoiceBee-Releases/releases/download/v${VERSION}/${APP_NAME}-${VERSION}.dmg"
                    ${SIGNATURE_LINE}
                    type="application/octet-stream" />
            </item>

双仓库发版步骤（手工，按顺序 — 先建 Release 再推 appcast，否则客户端可能先收到更新提示、DMG 却 404）：
1. 在 VoiceBee-Releases 仓库的 GitHub Releases 创建 v${VERSION}，附两个 DMG asset：
     - $DMG          ← 版本化 DMG，Sparkle appcast 的 enclosure 引用此 URL
     - $DMG_LATEST   ← Latest 直链 DMG，网站下载按钮 (jotbee.app/voicebee.html) 引用此 URL

2. 在 VoiceBee-Releases 更新 appcast.xml（Sparkle 用）：
     cd ~/Developer/VoiceBee-Releases
     # 把上面 <item> 填进 appcast.xml 的 <channel> 顶部，xmllint --noout appcast.xml 校验
     git add appcast.xml && git commit -m "v${VERSION} release" && git push origin main

3. 在 VoiceBee 主仓库 commit + 打 tag：
     cd ~/Developer/VoiceBee
     git add VoiceJar/Info.plist VoiceJar.xcodeproj
     git commit -m "release: v${VERSION}"
     git tag v${VERSION} && git push origin master --tags
EOF
