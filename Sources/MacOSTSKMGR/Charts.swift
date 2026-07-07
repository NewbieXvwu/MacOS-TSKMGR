import SwiftUI

struct GridChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let values: [Double]
    let color: Color
    var verticalSteps: Int = 8
    var horizontalSteps: Int = 6
    var lineWidth: CGFloat = 1.25
    var filled: Bool = false
    var ceiling: Double = 100
    var fillOpacityMultiplier: Double = 1
    var minimumVisibleRatio: Double = 0
    var dash: [CGFloat] = []
    var contentInset: CGFloat = 0

    private func normalizedY(_ value: Double) -> Double {
        let rawRatio = min(max(value / ceiling, 0), 1)
        if rawRatio <= 0 {
            return 0
        }
        return min(max(minimumVisibleRatio + (1 - minimumVisibleRatio) * rawRatio, 0), 1)
    }

    private func chartPoint(index: Int, value: Double, count: Int, width: CGFloat, height: CGFloat, inset: CGFloat) -> CGPoint {
        let maxX = max(Double(count - 1), 1)
        let x = inset + CGFloat(Double(index) / maxX) * width
        let y = inset + height * CGFloat(1 - normalizedY(value))
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                let inset = max(contentInset, lineWidth / 2)
                let chartWidth = max(proxy.size.width - inset * 2, 0)
                let chartHeight = max(proxy.size.height - inset * 2, 0)

                Path { path in
                    let width = chartWidth
                    let height = chartHeight
                    for step in 0...verticalSteps {
                        let x = inset + width * CGFloat(step) / CGFloat(max(verticalSteps, 1))
                        path.move(to: CGPoint(x: x, y: inset))
                        path.addLine(to: CGPoint(x: x, y: inset + height))
                    }
                    for step in 0...horizontalSteps {
                        let y = inset + height * CGFloat(step) / CGFloat(max(horizontalSteps, 1))
                        path.move(to: CGPoint(x: inset, y: y))
                        path.addLine(to: CGPoint(x: inset + width, y: y))
                    }
                }
                .stroke(AppTheme.chartGrid(colorScheme, accent: color), lineWidth: 0.7)

                if filled {
                    Path { path in
                        guard let firstValue = values.first else { return }
                        let first = chartPoint(index: 0, value: firstValue, count: values.count, width: chartWidth, height: chartHeight, inset: inset)
                        path.move(to: CGPoint(x: inset, y: inset + chartHeight))
                        path.addLine(to: first)
                        for (index, value) in values.enumerated() {
                            path.addLine(to: chartPoint(index: index, value: value, count: values.count, width: chartWidth, height: chartHeight, inset: inset))
                        }
                        path.addLine(to: CGPoint(x: inset + chartWidth, y: inset + chartHeight))
                        path.closeSubpath()
                    }
                    .fill(AppTheme.chartFill(colorScheme, accent: color).opacity(fillOpacityMultiplier))
                }

                Path { path in
                    guard let firstValue = values.first else { return }
                    path.move(to: chartPoint(index: 0, value: firstValue, count: values.count, width: chartWidth, height: chartHeight, inset: inset))
                    for index in values.indices.dropFirst() {
                        path.addLine(to: chartPoint(index: index, value: values[index], count: values.count, width: chartWidth, height: chartHeight, inset: inset))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: dash))
            }
            .clipShape(Rectangle())
        }
    }
}

struct DualLineGridChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let primaryValues: [Double]
    let secondaryValues: [Double]
    let color: Color
    var verticalSteps: Int = 8
    var horizontalSteps: Int = 4
    var lineWidth: CGFloat = 1.1
    var ceiling: Double = 100
    var primaryFilled: Bool = true
    var contentInset: CGFloat = 0

    private func chartPoint(index: Int, value: Double, count: Int, width: CGFloat, height: CGFloat, inset: CGFloat) -> CGPoint {
        let maxX = max(Double(count - 1), 1)
        let ratio = min(max(value / ceiling, 0), 1)
        return CGPoint(
            x: inset + CGFloat(Double(index) / maxX) * width,
            y: inset + height * CGFloat(1 - ratio)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                let inset = max(contentInset, lineWidth / 2)
                let chartWidth = max(proxy.size.width - inset * 2, 0)
                let chartHeight = max(proxy.size.height - inset * 2, 0)

                Path { path in
                    let width = chartWidth
                    let height = chartHeight
                    for step in 0...verticalSteps {
                        let x = inset + width * CGFloat(step) / CGFloat(max(verticalSteps, 1))
                        path.move(to: CGPoint(x: x, y: inset))
                        path.addLine(to: CGPoint(x: x, y: inset + height))
                    }
                    for step in 0...horizontalSteps {
                        let y = inset + height * CGFloat(step) / CGFloat(max(horizontalSteps, 1))
                        path.move(to: CGPoint(x: inset, y: y))
                        path.addLine(to: CGPoint(x: inset + width, y: y))
                    }
                }
                .stroke(AppTheme.chartGrid(colorScheme, accent: color), lineWidth: 0.7)

                if primaryFilled {
                    Path { path in
                        guard let firstValue = primaryValues.first else { return }
                        let first = chartPoint(index: 0, value: firstValue, count: primaryValues.count, width: chartWidth, height: chartHeight, inset: inset)
                        path.move(to: CGPoint(x: inset, y: inset + chartHeight))
                        path.addLine(to: first)
                        for (index, value) in primaryValues.enumerated() {
                            path.addLine(to: chartPoint(index: index, value: value, count: primaryValues.count, width: chartWidth, height: chartHeight, inset: inset))
                        }
                        path.addLine(to: CGPoint(x: inset + chartWidth, y: inset + chartHeight))
                        path.closeSubpath()
                    }
                    .fill(AppTheme.chartFill(colorScheme, accent: color).opacity(1))
                }

                Path { path in
                    guard let firstValue = primaryValues.first else { return }
                    path.move(to: chartPoint(index: 0, value: firstValue, count: primaryValues.count, width: chartWidth, height: chartHeight, inset: inset))
                    for index in primaryValues.indices.dropFirst() {
                        path.addLine(to: chartPoint(index: index, value: primaryValues[index], count: primaryValues.count, width: chartWidth, height: chartHeight, inset: inset))
                    }
                }
                .stroke(color, lineWidth: lineWidth)

                Path { path in
                    guard let firstValue = secondaryValues.first else { return }
                    path.move(to: chartPoint(index: 0, value: firstValue, count: secondaryValues.count, width: chartWidth, height: chartHeight, inset: inset))
                    for index in secondaryValues.indices.dropFirst() {
                        path.addLine(to: chartPoint(index: index, value: secondaryValues[index], count: secondaryValues.count, width: chartWidth, height: chartHeight, inset: inset))
                    }
                }
                .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: lineWidth, dash: [4, 2]))
            }
            .clipShape(Rectangle())
        }
    }
}
