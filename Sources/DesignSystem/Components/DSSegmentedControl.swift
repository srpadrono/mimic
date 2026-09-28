import SwiftUI

/// A segmented control with a neutral selected segment, so it never competes with list selection.
/// Segments can carry a count in their own colour, like "Unmatched 3".
public struct DSSegmentedControl<Selection: Hashable>: View {
    public struct Segment: Identifiable {
        public let id: Selection
        public let title: String
        public let count: Int?
        public let countColor: Color?
        public let help: String?
        public let identifier: String

        public init(_ title: String, value: Selection, count: Int? = nil, countColor: Color? = nil,
                    help: String? = nil, identifier: String) {
            self.id = value
            self.title = title
            self.count = count
            self.countColor = countColor
            self.help = help
            self.identifier = identifier
        }
    }

    private let segments: [Segment]
    @Binding private var selection: Selection
    private let fillsWidth: Bool
    private let label: String
    private let identifier: String

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ label: String, segments: [Segment], selection: Binding<Selection>,
                fillsWidth: Bool = false, identifier: String) {
        self.label = label
        self.segments = segments
        self._selection = selection
        self.fillsWidth = fillsWidth
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                SegmentButton(segment: segment, isSelected: segment.id == selection,
                              fillsWidth: fillsWidth, namespace: namespace) {
                    if reduceMotion {
                        selection = segment.id
                    } else {
                        withAnimation(.spring(duration: DSAnimation.normal, bounce: 0)) { selection = segment.id }
                    }
                }
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.segment).fill(DSColors.field)
        }
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private struct SegmentButton: View {
        let segment: Segment
        let isSelected: Bool
        let fillsWidth: Bool
        let namespace: Namespace.ID
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(segment.title)
                        .foregroundStyle(isSelected || isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
                    if let count = segment.count {
                        Text("\(count)")
                            .monospacedDigit()
                            .foregroundStyle(segment.countColor ?? DSColors.labelTertiary)
                    }
                }
                .font(DSTypography.calloutMedium)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: 20)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DSColors.segmentSelected)
                            .shadow(color: .black.opacity(0.2), radius: 0.75, y: 0.5)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(segment.help ?? segment.title)
            .accessibilityLabel(segment.count.map { "\(segment.title), \($0)" } ?? segment.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(segment.identifier)
        }
    }
}
