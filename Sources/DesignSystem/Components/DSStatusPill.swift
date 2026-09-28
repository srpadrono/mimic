import SwiftUI

// Legacy name for `DSStatusLabel`, kept until every screen moves. Delete with DSLegacyTokens.swift.
public struct DSStatusPill: View {
    private let label: DSStatusLabel

    public init(statusCode: Int?) {
        label = DSStatusLabel(statusCode: statusCode, reason: statusCode == nil ? "\u{2014}" : nil)
    }

    public init(statusCode: Int, detail: String) {
        label = DSStatusLabel(statusCode: statusCode, reason: detail)
    }

    public init(failureLabel: String) {
        label = DSStatusLabel(statusCode: nil, reason: failureLabel)
    }

    public var body: some View { label }
}
