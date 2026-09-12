import SwiftUI

struct LargeLevelMeter: View {
    let value: Float
    let tint: Color
    let primaryText: String
    let accessibilityLabelText: String
    var markerValue: Float? = nil
    /// Turns the number and the marker red.
    ///
    /// The number keeps moving while muted, because it reports the digital
    /// signal and mute acts after it. Red is still the honest colour: what the
    /// reader wants to know is whether any of this reaches their ears, and it
    /// does not. A moving red number says "signal present, nothing audible",
    /// which is the actual state.
    var isMuted = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))

                if let markerValue {
                    let markerX = min(
                        max(
                            proxy.size.width * CGFloat(min(max(markerValue, 0), 1)),
                            1.5
                        ),
                        proxy.size.width - 1.5
                    )
                    Rectangle()
                        .fill(.black.opacity(0.5))
                        .frame(width: 3, height: proxy.size.height)
                        .offset(x: markerX - 1.5)
                    Rectangle()
                        .fill(isMuted ? Color.red : Color.white)
                        .frame(width: isMuted ? 2 : 1, height: proxy.size.height)
                        .offset(x: markerX - (isMuted ? 1 : 0.5))
                }

                Text(primaryText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        isMuted
                            ? AnyShapeStyle(Color.red)
                            : AnyShapeStyle(value > 0.58 ? .white : .primary)
                    )
                    // The bar behind the number can itself be red at a high
                    // level, so the muted number gets an outline rather than
                    // disappearing into it.
                    .shadow(
                        color: isMuted ? .black.opacity(0.7) : .clear,
                        radius: 1.5
                    )
                    .padding(.horizontal, 10)
            }
        }
        .frame(height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(primaryText)
    }
}
