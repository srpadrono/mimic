import SwiftUI

// Legacy name for `DSMethodLabel`, kept until every screen moves. Delete with DSLegacyTokens.swift.
public enum DSMethodBadgeSize {
    case standard
    case compact
}

public struct DSMethodBadge: View {
    private let method: String
    private let identifier: String

    public init(method: String, size: DSMethodBadgeSize = .standard, identifier: String) {
        self.method = method
        self.identifier = identifier
    }

    public var body: some View {
        DSMethodLabel(method, identifier: identifier)
    }
}
