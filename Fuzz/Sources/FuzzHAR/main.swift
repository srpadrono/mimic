import Foundation
import FuzzSupport
import SpecImport

/// A HAR capture comes from a browser or proxy session the user exported, so every field is
/// attacker-shaped as far as Mimic knows.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzHAR(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)
    runToCompletion { _ = try await HARParser.parse(data: data) }
    return 0
}
