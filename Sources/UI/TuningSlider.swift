import SwiftUI

struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueFormat: String

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.77))
                Spacer()
                Text(String(format: valueFormat, value))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.mint)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
                .tint(Color.mint)
        }
    }
}

private struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .padding(.vertical, 12)
            .background(Color.mint, in: RoundedRectangle(cornerRadius: 13))
            .foregroundStyle(Color.black)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
