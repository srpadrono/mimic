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
            .font(DSTypography.headline)

        DSJSONEditor(text: $json, identifier: "preview") { valid in
            isValid = valid
        }
        .frame(height: 200)

        HStack {
            Text(isValid ? "Valid JSON" : "Invalid JSON")
                .font(DSTypography.body)
                .foregroundStyle(isValid ? DSColors.success : DSColors.error)
        }
    }
    .padding()
    .frame(width: 500, height: 300)
}
#endif
