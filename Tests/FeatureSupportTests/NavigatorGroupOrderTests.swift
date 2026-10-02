import Testing
@testable import FeatureSupport

@Suite("Navigator group order")
struct NavigatorGroupOrderTests {
    @Test("Groups keep the order they first appear in")
    func firstAppearance() {
        let tags: [String?] = ["Catalog", "Catalog", nil, "Account", "", "Payments", "Account", "Catalog"]
        #expect(NavigatorGroupOrder.names(in: tags) == ["Catalog", "Account", "Payments"])
    }

    @Test("No named groups gives no groups")
    func noGroups() {
        #expect(NavigatorGroupOrder.names(in: [nil, "", nil]).isEmpty)
    }
}
