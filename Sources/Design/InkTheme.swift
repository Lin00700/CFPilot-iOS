import SwiftUI
import UIKit

/// 墨色配色：宣纸底、松烟墨、朱砂印。
/// 所有颜色都是动态色，浅色/深色模式各一套。
enum Ink {
    static let paperTop = dynamic((0.972, 0.957, 0.925), (0.071, 0.078, 0.090))
    static let paperBottom = dynamic((0.918, 0.894, 0.851), (0.035, 0.039, 0.047))
    static let card = dynamic((1.000, 0.996, 0.984), (0.118, 0.125, 0.141))
    static let cardStroke = dynamic((0.62, 0.60, 0.55), (0.34, 0.35, 0.37))
    static let text = dynamic((0.106, 0.114, 0.129), (0.914, 0.910, 0.894))
    static let textSecondary = dynamic((0.341, 0.353, 0.373), (0.663, 0.667, 0.678))
    static let textFaint = dynamic((0.506, 0.514, 0.522), (0.478, 0.486, 0.502))
    static let seal = dynamic((0.698, 0.227, 0.192), (0.851, 0.353, 0.302))
    static let sealSoft = dynamic((0.812, 0.475, 0.427), (0.741, 0.443, 0.396))
    static let brush = dynamic((0.169, 0.216, 0.290), (0.588, 0.678, 0.784))
    static let jade = dynamic((0.204, 0.420, 0.353), (0.451, 0.741, 0.635))
    static let ridgeFar = dynamic((0.737, 0.749, 0.749) , (0.204, 0.220, 0.243))
    static let ridgeMid = dynamic((0.639, 0.655, 0.663), (0.145, 0.157, 0.176))
    static let ridgeNear = dynamic((0.514, 0.533, 0.549), (0.098, 0.106, 0.122))
    static let mist = dynamic((0.855, 0.859, 0.855), (0.180, 0.192, 0.212))
    static let divider = dynamic((0.78, 0.76, 0.71), (0.243, 0.251, 0.267))
    static let fieldBackground = dynamic((0.984, 0.976, 0.961), (0.153, 0.161, 0.176))
}

private func dynamic(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    Color(UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1)
    })
}

/// 水墨题字用的字体族
enum InkFont {
    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
    static func body(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

/// 远山：正弦叠加出的山脊轮廓，用来做宣纸背景。
struct InkRidge: Shape {
    var amplitude: CGFloat = 0.35
    var yOffset: CGFloat = 0.7
    var frequency: CGFloat = 1.2
    var phase: CGFloat = 0
    var steps: Int = 64

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let h = rect.height
        let w = rect.width
        path.move(to: CGPoint(x: 0, y: h))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let a = sin(t * .pi * frequency + phase) * 0.5 + 0.5
            let b = sin(t * .pi * frequency * 2.3 + phase * 1.7) * 0.25
            let c = sin(t * .pi * frequency * 0.6 + phase * 0.4) * 0.18
            let y = h * (yOffset - amplitude * (a + b + c) * 0.5)
            path.addLine(to: CGPoint(x: w * t, y: y))
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        return path
    }
}

/// 全屏宣纸底 + 三重远山
struct InkBackground: View {
    var showMountains: Bool = true

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Ink.paperTop, Ink.paperBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if showMountains {
                ZStack(alignment: .bottom) {
                    InkRidge(amplitude: 0.55, yOffset: 0.58, frequency: 1.9, phase: 1.1)
                        .fill(LinearGradient(
                            colors: [Ink.ridgeFar.opacity(0.35), Ink.ridgeFar.opacity(0.06)],
                            startPoint: .bottom, endPoint: .top))
                        .frame(height: 260)
                    InkRidge(amplitude: 0.50, yOffset: 0.64, frequency: 1.35, phase: 0.25)
                        .fill(LinearGradient(
                            colors: [Ink.ridgeMid.opacity(0.40), Ink.ridgeMid.opacity(0.05)],
                            startPoint: .bottom, endPoint: .top))
                        .frame(height: 185)
                    InkRidge(amplitude: 0.44, yOffset: 0.72, frequency: 0.95, phase: 2.2)
                        .fill(LinearGradient(
                            colors: [Ink.ridgeNear.opacity(0.46), Ink.ridgeNear.opacity(0.04)],
                            startPoint: .bottom, endPoint: .top))
                        .frame(height: 120)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

/// 卡纸：半透明底 + 细墨线描边
struct InkCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Ink.card.opacity(0.86))
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Ink.cardStroke.opacity(0.28), lineWidth: 1)
            )
    }
}

/// 小标题：左侧一竖笔，右侧题字
struct InkSectionTitle: View {
    let text: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule(style: .continuous)
                .fill(Ink.seal.opacity(0.85))
                .frame(width: 3, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(InkFont.title(17))
                    .foregroundStyle(Ink.text)
                if let subtitle {
                    Text(subtitle)
                        .font(InkFont.body(12))
                        .foregroundStyle(Ink.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 朱砂印章样式的主按钮
struct SealButtonStyle: ButtonStyle {
    var tint: Color = Ink.seal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(InkFont.title(16))
            .foregroundStyle(Color.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.72 : 1))
                    .shadow(color: tint.opacity(0.28), radius: 10, x: 0, y: 4)
            )
            .opacity(configuration.isPressed ? 0.96 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 描边次级按钮
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(InkFont.title(15))
            .foregroundStyle(Ink.text)
            .padding(.vertical, 11)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Ink.fieldBackground.opacity(configuration.isPressed ? 0.9 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Ink.cardStroke.opacity(0.4), lineWidth: 1)
            )
    }
}

/// 输入框外框
struct InkField<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        content
            .font(InkFont.body(15))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Ink.fieldBackground.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Ink.cardStroke.opacity(0.30), lineWidth: 1)
            )
    }
}

/// 「标签 — 值」一行
struct InkKeyValueRow: View {
    let label: String
    let value: String
    var mono: Bool = true
    var accent: Color = Ink.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(InkFont.body(13))
                .foregroundStyle(Ink.textFaint)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(mono ? InkFont.mono(13) : InkFont.body(13))
                .foregroundStyle(accent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 状态小圆点 + 文案
struct InkStatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

/// 卷轴式的分隔线
struct InkDivider: View {
    var body: some View {
        Rectangle()
            .fill(Ink.divider.opacity(0.45))
            .frame(height: 1)
    }
}

extension View {
    /// 深色/浅色都舒服的滚动列表底色透明处理
    func inkListBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(InkBackground())
    }
}
