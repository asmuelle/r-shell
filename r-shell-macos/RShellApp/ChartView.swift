import SwiftUI

/// Horizontal gauge bar for a single percentage value.
struct GaugeBar: View {
    var label: String
    var value: Double  // 0–100
    var color: Color
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 40, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .frame(height: 12)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(value, 100) / 100), height: 12)
                }
            }
            .frame(height: 12)

            Text(String(format: "%.1f%%", value))
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 46, alignment: .trailing)

            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }
}

/// Simple line chart for time-series data.
struct MiniLineChart: View {
    var data: [Double]
    var color: Color
    var lineWidth: CGFloat = 1.5
    var showLabels: Bool = false

    var body: some View {
        GeometryReader { geo in
            let maxVal = max(data.max() ?? 1, 1)
            let stepX = data.count > 1 ? geo.size.width / CGFloat(data.count - 1) : 0

            Path { path in
                for (i, val) in data.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height * (1 - CGFloat(val / maxVal))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Small status indicator showing a numeric value with icon.
struct StatTile: View {
    var icon: String
    var label: String
    var value: String
    var color: Color = .secondary

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 64)
        .padding(6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}
