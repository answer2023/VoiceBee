import SwiftUI

/// 输出风格设置 — 2x2 卡片布局，灵感来自 OpenLess
struct StyleSettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 标题 + 整体启用
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("STYLE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(1.2)
                        Text("输出风格")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Text("整体启用")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(
                            get: { appState.outputStyle.masterEnabled },
                            set: { appState.outputStyle.masterEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                }

                Text("选择默认风格用于全局录音。每张卡可单独启停；启停的风格不会出现在历史记录的「重新润色」切换中。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                // 2x2 卡片
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 10) {
                    ForEach(OutputStyle.allCases) { style in
                        StyleCard(
                            style: style,
                            isDefault: appState.outputStyle.defaultStyle == style,
                            isEnabled: appState.outputStyle.enabledStyles.contains(style),
                            masterOn: appState.outputStyle.masterEnabled,
                            onSelect: { appState.outputStyle.setDefault(style) },
                            onToggle: { newValue in
                                appState.outputStyle.setEnabled(style, enabled: newValue)
                            }
                        )
                    }
                }
                .opacity(appState.outputStyle.masterEnabled ? 1.0 : 0.45)

                if !appState.outputStyle.masterEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("整体已关闭：录音将直接上屏，不调用 AI 润色。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

/// 单张风格卡
private struct StyleCard: View {
    let style: OutputStyle
    let isDefault: Bool
    let isEnabled: Bool
    let masterOn: Bool
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部：radio + title + 启停 toggle
            HStack(alignment: .top, spacing: 6) {
                Button(action: onSelect) {
                    Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isDefault ? .blue : .secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)

                VStack(alignment: .leading, spacing: 1) {
                    Text(style.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isEnabled ? .primary : .tertiary)
                    Text(style.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: onToggle
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            // 样例预览
            Text(style.samplePreview)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)

            // 底部：当前默认徽章
            if isDefault && isEnabled && masterOn {
                Text("当前默认")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.12), in: Capsule())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDefault && isEnabled ? Color.blue : Color.secondary.opacity(0.15),
                        lineWidth: isDefault && isEnabled ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isEnabled { onSelect() }
        }
    }
}
