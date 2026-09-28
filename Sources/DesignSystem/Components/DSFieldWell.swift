import SwiftUI

/// Field chrome for a bare `TextField` whose focus the well tracks itself.
public struct DSFieldWell: ViewModifier {
    private let width: CGFloat?
    private let maxWidth: CGFloat?
    private let isInvalid: Bool
    private let height: CGFloat
    @FocusState private var isFocused: Bool

    public init(width: CGFloat? = nil, maxWidth: CGFloat? = nil, isInvalid: Bool = false,
                height: CGFloat = DSControlHeight.regular) {
        self.width = width
        self.maxWidth = maxWidth
        self.isInvalid = isInvalid
        self.height = height
    }

    public func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .dsFieldChrome(height: height, isFocused: isFocused, isInvalid: isInvalid)
            .frame(width: width)
            .frame(maxWidth: maxWidth)
    }
}

public extension View {
    func dsFieldWell(width: CGFloat? = nil, maxWidth: CGFloat? = nil, isInvalid: Bool = false,
                     height: CGFloat = DSControlHeight.regular) -> some View {
        modifier(DSFieldWell(width: width, maxWidth: maxWidth, isInvalid: isInvalid, height: height))
    }
}
