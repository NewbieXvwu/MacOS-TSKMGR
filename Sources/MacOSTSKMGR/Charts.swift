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

    private var normalized: [CGPoint] {
        guard !values.isEmpty else { return [] }
        let maxX = max(Double(values.count - 1), 1)
        return values.enumerated().map { index, value in
            let rawRatio = min(max(value / ceiling, 0), 1)
            let liftedRatio: Double
            if rawRatio <= 0 {
                liftedRatio = 0
            } else {
                liftedRatio = minimumVisibleRatio + (1 - minimumVisibleRatio) * rawRatio
            }
            return CGPoint(x: Double(index) / maxX, y: min(max(liftedRatio, 0), 1))
        }
    }

    var body: some View {
        let points = normalized
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
                        guard let first = points.first else { return }
                        path.move(to: CGPoint(x: inset, y: inset + chartHeight))
                        path.addLine(to: CGPoint(x: inset + first.x * chartWidth, y: inset + chartHeight * (1 - first.y)))
                        for point in points {
                            path.addLine(to: CGPoint(x: inset + point.x * chartWidth, y: inset + chartHeight * (1 - point.y)))
                        }
                        path.addLine(to: CGPoint(x: inset + chartWidth, y: inset + chartHeight))
                        path.closeSubpath()
                    }
                    .fill(AppTheme.chartFill(colorScheme, accent: color).opacity(fillOpacityMultiplier))
                }

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: inset + first.x * chartWidth, y: inset + chartHeight * (1 - first.y)))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: inset + point.x * chartWidth, y: inset + chartHeight * (1 - point.y)))
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

    private func normalizedPoints(for values: [Double]) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let maxX = max(Double(values.count - 1), 1)
        return values.enumerated().map { index, value in
            CGPoint(x: Double(index) / maxX, y: min(max(value / ceiling, 0), 1))
        }
    }

    var body: some View {
        let primary = normalizedPoints(for: primaryValues)
        let secondary = normalizedPoints(for: secondaryValues)

        return GeometryReader { proxy in
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
                        guard let first = primary.first else { return }
                        path.move(to: CGPoint(x: inset, y: inset + chartHeight))
                        path.addLine(to: CGPoint(x: inset + first.x * chartWidth, y: inset + chartHeight * (1 - first.y)))
                        for point in primary {
                            path.addLine(to: CGPoint(x: inset + point.x * chartWidth, y: inset + chartHeight * (1 - point.y)))
                        }
                        path.addLine(to: CGPoint(x: inset + chartWidth, y: inset + chartHeight))
                        path.closeSubpath()
                    }
                    .fill(AppTheme.chartFill(colorScheme, accent: color).opacity(1))
                }

                Path { path in
                    guard let first = primary.first else { return }
                    path.move(to: CGPoint(x: inset + first.x * chartWidth, y: inset + chartHeight * (1 - first.y)))
                    for point in primary.dropFirst() {
                        path.addLine(to: CGPoint(x: inset + point.x * chartWidth, y: inset + chartHeight * (1 - point.y)))
                    }
                }
                .stroke(color, lineWidth: lineWidth)

                Path { path in
                    guard let first = secondary.first else { return }
                    path.move(to: CGPoint(x: inset + first.x * chartWidth, y: inset + chartHeight * (1 - first.y)))
                    for point in secondary.dropFirst() {
                        path.addLine(to: CGPoint(x: inset + point.x * chartWidth, y: inset + chartHeight * (1 - point.y)))
                    }
                }
                .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: lineWidth, dash: [4, 2]))
            }
            .clipShape(Rectangle())
        }
    }
}
