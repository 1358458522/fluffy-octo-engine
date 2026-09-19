import SwiftUI

// MARK: - 统一视觉规范
//
// 各页面共用这里的排版组件，保证「首页 / 站点详情 / 设置 / 诊断」风格一致：
// 统一字号层级、统一等宽数字（避免数值跳动）、统一状态配色与留白。

/// 信息行：左标题（次要色）+ 右数值（等宽数字，可加重）
struct InfoRow: View {
    let title: String
    let value: String
    var valueColor: Color = .primary
    var emphasized: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 交班状态胶囊
struct StatusBadge: View {
    let timing: ShiftTiming
    var compact = false

    var body: some View {
        Text(timing.rawValue)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .background(timing.displayColor.opacity(0.12), in: Capsule())
            .foregroundStyle(timing.displayColor)
    }
}

/// 「指标 + 数值」竖块，用于总览卡片
struct MetricBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

/// 列表内空状态提示
struct EmptyHint: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
