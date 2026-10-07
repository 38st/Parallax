import AppKit
import SwiftUI

struct AppIcon: View {
    var path: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

struct UsageBar: View {
    var window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title).font(.callout)
                Spacer()
                Text("\(window.percent)%").font(.callout.monospacedDigit().weight(.semibold))
            }
            ProgressView(value: Double(window.percent), total: 100)
                .tint(window.percent >= 100 ? .red : window.percent >= 85 ? .orange : .accentColor)
            if let resetsAt = window.resetsAt {
                Text("Resets \(resetsAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct UsageBadge: View {
    var account: UsageAccount

    var body: some View {
        if let headline = account.headline {
            Text("\(headline.percent)%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color(headline.percent).opacity(0.18), in: Capsule())
                .foregroundStyle(color(headline.percent))
                .help("\(account.label): \(headline.title) \(headline.percent)% used")
        }
    }

    private func color(_ percent: Int) -> Color {
        percent >= 100 ? .red : percent >= 85 ? .orange : .green
    }
}

struct RunningDot: View {
    var running: Bool

    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.secondary.opacity(0.3))
            .frame(width: 8, height: 8)
            .accessibilityLabel(running ? "Running" : "Not running")
    }
}
