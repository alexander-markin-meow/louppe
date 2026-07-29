import SwiftUI

/// Compact photo-only luminance inspection for the Info panel.
struct HistogramSection: View {
    let analysis: HistogramAnalysis?
    let loadFailed: Bool
    @ObservedObject var store: SessionStore

    private static let chartHeight: CGFloat = 88
    private let warningColor = Color.red.opacity(0.72)

    var body: some View {
        VStack(spacing: 8) {
            chart
                .frame(height: Self.chartHeight)

            if !loadFailed {
                percentageRow
                if store.viewMode == .gallery {
                    clippingButton
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chart: some View {
        if let analysis {
            LuminanceHistogramView(analysis: analysis)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription(for: analysis))
        } else if loadFailed {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("Histogram unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Calculating histogram")
        }
    }

    private var percentageRow: some View {
        HStack(spacing: 8) {
            percentage(
                "Shadows",
                value: analysis?.shadowPercentage
            )
            percentage(
                "Highlights",
                value: analysis?.highlightPercentage
            )
        }
    }

    private func percentage(_ label: String, value: Double?) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.map(Self.formatPercentage) ?? "—")
                .font(.callout.weight(.medium))
                .foregroundStyle(percentageColor(value))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var clippingButton: some View {
        Button {
            store.toggleClippingWarnings()
        } label: {
            Label(
                store.showClippingWarnings
                    ? "Hide Clipping Warnings"
                    : "Show Clipping Warnings",
                systemImage: store.showClippingWarnings
                    ? "exclamationmark.triangle.fill"
                    : "exclamationmark.triangle"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(
                store.showClippingWarnings
                    ? Color.louppeAccent
                    : Color.primary
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    store.showClippingWarnings
                        ? Color.louppeAccent
                        : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        }
        .accessibilityValue(
            store.showClippingWarnings ? "On" : "Off"
        )
        .help("Show or hide red clipping warnings on the photo (X)")
    }

    private func percentageColor(_ value: Double?) -> Color {
        guard let value,
              HistogramAnalysis.isHighPercentage(value)
        else { return .primary }
        return warningColor
    }

    private static func formatPercentage(_ value: Double) -> String {
        if value == 0 { return "0%" }
        if value < 0.1 { return "<0.1%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    private func accessibilityDescription(
        for analysis: HistogramAnalysis
    ) -> String {
        "Luminance histogram. Shadows \(Self.formatPercentage(analysis.shadowPercentage)). Highlights \(Self.formatPercentage(analysis.highlightPercentage))."
    }
}

private struct LuminanceHistogramView: View {
    let analysis: HistogramAnalysis

    var body: some View {
        Canvas { context, size in
            guard let maximum = analysis.bins.max(), maximum > 0 else {
                return
            }
            let binWidth = size.width / CGFloat(analysis.bins.count)
            var normalPath = Path()
            var warningPath = Path()
            for (index, count) in analysis.bins.enumerated() where count > 0 {
                let height = max(
                    CGFloat(count) / CGFloat(maximum) * size.height,
                    1
                )
                let rect = CGRect(
                    x: CGFloat(index) * binWidth,
                    y: size.height - height,
                    width: max(binWidth + 0.35, 0.5),
                    height: height
                )
                if index <= Int(HistogramAnalysis.nearBlackUpperBound)
                    || index >= Int(HistogramAnalysis.nearWhiteLowerBound) {
                    warningPath.addRect(rect)
                } else {
                    normalPath.addRect(rect)
                }
            }
            context.fill(
                normalPath,
                with: .color(Color.secondary.opacity(0.55))
            )
            context.fill(
                warningPath,
                with: .color(Color.red.opacity(0.72))
            )
            context.stroke(
                Path(CGRect(
                    x: 0,
                    y: size.height - 0.5,
                    width: size.width,
                    height: 0.5
                )),
                with: .color(Color.secondary.opacity(0.35)),
                lineWidth: 0.5
            )
        }
    }
}
