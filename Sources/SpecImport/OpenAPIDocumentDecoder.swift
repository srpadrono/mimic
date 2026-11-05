import Foundation
import OpenAPIKit
import OpenAPIKit30
import OpenAPIKitCompat

/// Decodes any OpenAPI 3 document into OpenAPIKit's 3.1 model, the one the importer reads.
///
/// OpenAPIKit keeps 3.0 and 3.1 in separate modules with separate types, and its 3.0 decoder
/// refuses a `3.1.0` document outright. 3.1 is what FastAPI and most current generators emit, so
/// reading only 3.0 refused a large share of real specs before looking at a single path. A 3.0
/// document is decoded by the 3.0 module and converted with the library's own compatibility layer,
/// so both versions reach the importer as one type and nothing downstream is written twice.
///
/// This is the only file that imports both modules; each declares an `OpenAPI` namespace, so the
/// names here are qualified.
enum OpenAPIDocumentDecoder {
    static func decode(_ data: Data, declaredVersion: String?) throws -> OpenAPIKit.OpenAPI.Document {
        if declaredVersion?.hasPrefix("3.0") == true {
            return try JSONDecoder()
                .decode(OpenAPIKit30.OpenAPI.Document.self, from: data)
                .convert(to: .v3_1_1)
        }
        return try JSONDecoder().decode(OpenAPIKit.OpenAPI.Document.self, from: data)
    }
}
