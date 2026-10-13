import SwiftUI

private enum BottleLayout {
    static let width: CGFloat = 430
    static let height: CGFloat = 430
    static let left: CGFloat = 125
    static let right: CGFloat = 300
    static let top: CGFloat = 86
    static let bottom: CGFloat = 405
    static let neckLeft: CGFloat = 177
    static let neckRight: CGFloat = 248
    static let neckTop: CGFloat = 24
    static let shoulder: CGFloat = 54
    static let center = (left + right) / 2

    static func y(for milliliters: Double) -> CGFloat {
        bottom - CGFloat(milliliters / Double(WaterRepository.bottleML)) * (bottom - top)
    }
}

private struct BottleOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: BottleLayout.neckLeft, y: BottleLayout.neckTop))
        path.addLine(to: CGPoint(x: BottleLayout.neckRight, y: BottleLayout.neckTop))
        path.addLine(to: CGPoint(x: BottleLayout.neckRight, y: BottleLayout.shoulder))
        path.addLine(to: CGPoint(x: BottleLayout.right, y: BottleLayout.top))
        path.addLine(to: CGPoint(x: BottleLayout.right, y: BottleLayout.bottom))
        path.addLine(to: CGPoint(x: BottleLayout.left, y: BottleLayout.bottom))
        path.addLine(to: CGPoint(x: BottleLayout.left, y: BottleLayout.top))
        path.addLine(to: CGPoint(x: BottleLayout.neckLeft, y: BottleLayout.shoulder))
        path.closeSubpath()
        return path
    }
}

struct BottleView: View {
    let milliliters: Double
    let pouring: Bool

    private var visibleAmount: Double {
        min(max(milliliters, 0), Double(WaterRepository.bottleML))
    }

    var body: some View {
        let surface = BottleLayout.y(for: visibleAmount)
        let waterHeight = BottleLayout.bottom - surface
        let goalY = BottleLayout.y(for: Double(WaterRepository.goalML))

        ZStack(alignment: .topLeading) {
            BottleOutline()
                .fill(Color.blue.opacity(0.06))

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.19, green: 0.71, blue: 1),
                                 Color(red: 0.04, green: 0.37, blue: 0.90)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: BottleLayout.right - BottleLayout.left, height: waterHeight)
                    .position(x: BottleLayout.center, y: BottleLayout.bottom - waterHeight / 2)

                if pouring {
                    Rectangle()
                        .fill(.blue)
                        .frame(width: 9, height: max(0, surface - BottleLayout.neckTop))
                        .position(x: BottleLayout.center, y: (surface + BottleLayout.neckTop) / 2)
                }
            }
            .frame(width: BottleLayout.width, height: BottleLayout.height)
            .mask(BottleOutline())

            BottleOutline()
                .stroke(.primary, style: StrokeStyle(lineWidth: 3, lineJoin: .round))

            ForEach(0...6, id: \.self) { step in
                let amount = step * 500
                let y = BottleLayout.y(for: Double(amount))
                Path { path in
                    path.move(to: CGPoint(x: 103, y: y))
                    path.addLine(to: CGPoint(x: BottleLayout.left, y: y))
                }
                .stroke(.secondary, lineWidth: 1)
                Text("\(amount.formatted()) ml")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 94, alignment: .trailing)
                    .position(x: 51, y: y)
            }

            Path { path in
                path.move(to: CGPoint(x: BottleLayout.left, y: goalY))
                path.addLine(to: CGPoint(x: BottleLayout.right, y: goalY))
            }
            .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            Text("GOAL 2.7 L")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
                .position(x: 361, y: goalY)
        }
        .frame(width: BottleLayout.width, height: BottleLayout.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Water bottle, \(Int(milliliters)) of 3,000 milliliters shown")
    }
}
