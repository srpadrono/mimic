import SwiftUI

/// The settings switch: a 32 × 18 pt track, accent when on, with a 14 pt knob. It is drawn rather
/// than native so it keeps the design's size and colour whether or not its window is in front.
///
/// It stays a toggle to assistive technology, and Space flips it under keyboard navigation.
public struct DSSwitchToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DSSwitchRow(configuration: configuration)
    }
}

private struct DSSwitchRow: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            configuration.label
            DSSwitchTrack(isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: flip)
        .focusable(isEnabled, interactions: .activate)
        .onKeyPress(.space) {
            flip()
            return .handled
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func flip() {
        guard isEnabled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: DSAnimation.fast)) {
            configuration.isOn.toggle()
        }
    }
}

/// The track and knob alone.
struct DSSwitchTrack: View {
    static let size = CGSize(width: 32, height: 18)
    static let knob: CGFloat = 14

    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? DSColors.accent : DSColors.switchTrack)
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(DSColors.switchKnob)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding((Self.size.height - Self.knob) / 2)
            }
            .accessibilityHidden(true)
    }
}
