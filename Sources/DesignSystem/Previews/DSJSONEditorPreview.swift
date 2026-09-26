import SwiftUI

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
                .foregroundStyle(isValid ? DSColors.successText : DSColors.destructiveText)
        }
    }
    .padding()
    .frame(width: 500, height: 300)
}
#endif
