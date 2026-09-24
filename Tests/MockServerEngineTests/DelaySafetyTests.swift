import Testing
@testable import Domain
@testable import MockServerEngine

struct DelaySafetyTests {
    @Test("Timeout hold includes the configured delay")
    func timeoutAddsDelay() {
        #expect(VaporConfigurator.holdMilliseconds(for: .timeout(holdMs: 250), delayMs: 100) == 350)
        #expect(VaporConfigurator.holdMilliseconds(for: .connectionDrop, delayMs: 100) == 100)
    }

    @Test("Negative delay inputs cannot shorten the hold below zero")
    func negativeInputsAreClamped() {
        #expect(VaporConfigurator.holdMilliseconds(for: .timeout(holdMs: 250), delayMs: -100) == 250)
        #expect(VaporConfigurator.holdMilliseconds(for: .timeout(holdMs: -250), delayMs: 100) == 100)
        #expect(VaporConfigurator.holdMilliseconds(for: .timeout(holdMs: -250), delayMs: -100) == 0)
        #expect(VaporConfigurator.holdMilliseconds(for: .connectionDrop, delayMs: -100) == 0)
    }

    @Test("A timeout hold that exceeds Int.max saturates instead of trapping")
    func timeoutAdditionSaturates() {
        // The previous unchecked addition trapped on the smallest overflowing pair.
        #expect(VaporConfigurator.holdMilliseconds(for: .timeout(holdMs: 1), delayMs: Int.max) == Int.max)
        #expect(VaporConfigurator.holdMilliseconds(for: .timeout(holdMs: Int.max), delayMs: 1) == Int.max)
        #expect(VaporConfigurator.holdMilliseconds(for: .timeout(holdMs: 1), delayMs: Int.max - 1) == Int.max)
    }
}
