import Domain
import Foundation

/// Project exports are shared between people, and control API payloads arrive over a socket. Both
/// decode through `ControlCoding`, the same decoder `mimic project import` and the control server use.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzProjectDocument(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)
    if MockProject.namesProjectDocument(data) {
        _ = try? ControlCoding.decode(MockProject.self, from: data)
    }
    _ = try? ControlCoding.decode(ControlCommand.self, from: data)
    _ = try? ControlCoding.decode(Journey.self, from: data)
    return 0
}
