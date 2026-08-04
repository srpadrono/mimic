import Testing
import Foundation
@testable import Domain

@Suite("EndpointValidation")
struct EndpointValidationTests {

    // MARK: - Path Validation

    @Test func validPathStartingWithSlash() throws {
        try EndpointValidator.validatePath("/")
    }

    @Test func validPathWithSegments() throws {
        try EndpointValidator.validatePath("/users/123")
    }

    @Test func invalidPathMissingLeadingSlash() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePath("users/123")
        }
    }

    @Test func invalidPathWithDoubleSlashes() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePath("//users")
        }
    }

    @Test func invalidPathWithLeadingWhitespace() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePath(" /users")
        }
    }

    @Test func invalidPathWithTrailingWhitespace() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePath("/users ")
        }
    }

    // MARK: - Status Code Validation

    @Test func validStatusCode200() throws {
        try EndpointValidator.validateStatusCode(200)
    }

    @Test func validStatusCodeBoundaryLow() throws {
        try EndpointValidator.validateStatusCode(200)
    }

    @Test func validStatusCodeBoundaryHigh() throws {
        try EndpointValidator.validateStatusCode(599)
    }

    @Test func invalidStatusCode600() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(600)
        }
    }

    @Test func invalidStatusCode99() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(99)
        }
    }

    /// 1xx used to be accepted, and serving one crashed the app.
    ///
    /// NIO's server pipeline treats an informational head as "an interim response, more to follow"
    /// and does not advance its state machine; the body that follows then fails an assertion. There
    /// is nothing lost by refusing them — a client never sees a 1xx as the answer to its request.
    @Test func informationalStatusCodesAreRejected() {
        for code in [100, 101, 102, 199] {
            #expect(throws: ValidationError.self) {
                try EndpointValidator.validateStatusCode(code)
            }
        }
    }

    @Test func negativeStatusCodeIsRejected() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(-1)
        }
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validateStatusCode(Int.min)
        }
    }

    // MARK: - Port Validation

    @Test func validPort8080() throws {
        try EndpointValidator.validatePort(8080)
    }

    @Test func validPortBoundaryLow() throws {
        try EndpointValidator.validatePort(1)
    }

    @Test func validPortBoundaryHigh() throws {
        try EndpointValidator.validatePort(65535)
    }

    @Test func invalidPortZero() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePort(0)
        }
    }

    @Test func invalidPortNegative() {
        #expect(throws: ValidationError.self) {
            try EndpointValidator.validatePort(-1)
        }
    }

    // MARK: - LocalizedError

    @Test func validationErrorProvidesLocalizedDescription() {
        let pathError = ValidationError.invalidPath("test")
        #expect(pathError.localizedDescription.contains("test"))

        let statusError = ValidationError.invalidStatusCode(999)
        #expect(statusError.localizedDescription.contains("999"))

        let portError = ValidationError.invalidPort(-5)
        #expect(portError.localizedDescription.contains("-5"))
    }

// Legacy testing block eliminated
}
