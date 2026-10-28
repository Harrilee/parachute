import SwiftUI

private struct FloatingGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            // Let the system adapt text contrast to the map behind the glass.
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func floatingGlass(cornerRadius: CGFloat = 20) -> some View {
        modifier(FloatingGlass(cornerRadius: cornerRadius))
    }
}
