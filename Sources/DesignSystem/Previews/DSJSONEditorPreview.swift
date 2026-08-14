import SwiftUI

// Guarded so previews do not ship.
//
// `#Preview` expands to a `PreviewRegistry` conformance, which is compiled into whatever
// configuration builds the file — and nothing here was gated, so 386 lines of preview scaffolding
// went into the Release binary. Every `#Preview` elsewhere in this project is already inside
// `#if DEBUG`; the design system's were the exception.
#if DEBUG
#Preview("DSJSONEditor") {
    @Previewable @State var json = """
    {
      "id": 1,
      "name": "Test User",
      "active": true
    }
    """
    @Previewable @State var isValid = true

    VStack(alignment: .leading, spacing: DSSpacing.md) {
        Text("JSON editor")
            .font(DSTypography.heading)

        DSJSONEditor(text: $json, identifier: "preview") { valid in
            isValid = valid
        }
        .frame(height: 200)

        HStack {
            Text(isValid ? "Valid JSON" : "Invalid JSON")
                .font(DSTypography.label)
                .foregroundStyle(isValid ? .green : .red)
        }
    }
    .padding()
    .frame(width: 500, height: 300)
}
#endif
