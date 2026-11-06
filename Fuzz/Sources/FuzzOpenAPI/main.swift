import Foundation
import FuzzSupport
import SpecImport

/// OpenAPI 3.x and Swagger 2 specs are usually downloaded from a third party's documentation, then
/// parsed, walked for every operation, and turned into example responses from their schemas.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOpenAPI(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)
    runToCompletion { _ = try await OpenAPIParser.parse(data: data) }
    return 0
}
