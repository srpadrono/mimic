import Foundation
import Testing
import Domain
import FeatureSupport
import SpecImport
@testable import ImportFeature

@Suite("Import review model")
@MainActor
struct ImportReviewModelTests {
    private func candidate(
        _ method: HTTPMethod = .get,
        _ path: String = "/products",
        host: String? = "api.acme.shop",
        status: Int = 200,
        selected: Bool = true,
        duplicate: Bool = false,
        binary: Bool = false,
        overLimit: Bool = false,
        unavailable: Bool = false
    ) -> ImportCandidate {
        ImportCandidate(
            isSelected: selected,
            method: method,
            path: path,
            host: host,
            suggestedName: path,
            suggestedGroupTag: nil,
            statusCode: status,
            responseHeaders: [:],
            responseBody: binary || overLimit || unavailable ? nil : "{}",
            responseContentType: .json,
            bodySizeBytes: 2,
            bodySizeExceedsLimit: overLimit,
            bodyIsBinary: binary,
            bodyIsUnavailable: unavailable,
            isDuplicate: duplicate
        )
    }

    @Test("Hosts are listed busiest first, then by name")
    func hostsBusiestFirst() {
        let candidates = [
            candidate(host: "pay.acme.shop"),
            candidate(host: "api.acme.shop"),
            candidate(host: "api.acme.shop"),
            candidate(host: "cdn.acme.shop"),
            candidate(host: nil),
        ]
        #expect(ImportHostFilter.hosts(in: candidates) == [
            .init(name: "api.acme.shop", count: 2),
            .init(name: "cdn.acme.shop", count: 1),
            .init(name: "pay.acme.shop", count: 1),
        ])
    }

    @Test("Hiding a host deselects its rows, and showing it again restores what each row was")
    func hidingAHostHoldsItsSelection() {
        var candidates = [
            candidate(host: "api.acme.shop", selected: true),
            candidate(.post, "/track", host: "events.segment.io", selected: true),
            candidate(.get, "/pixel", host: "events.segment.io", selected: false),
        ]
        var hidden: Set<String> = []
        var held: [UUID: Bool] = [:]

        ImportHostFilter.setHost("events.segment.io", shown: false, candidates: &candidates,
                                 hiddenHosts: &hidden, heldSelection: &held)
        #expect(hidden == ["events.segment.io"])
        #expect(candidates.map(\.isSelected) == [true, false, false])
        #expect(ImportHostFilter.isHidden(candidates[1], hiddenHosts: hidden))
        #expect(!ImportHostFilter.isHidden(candidates[0], hiddenHosts: hidden))

        // Hiding twice must not overwrite what was held with the hidden state.
        ImportHostFilter.setHost("events.segment.io", shown: false, candidates: &candidates,
                                 hiddenHosts: &hidden, heldSelection: &held)

        ImportHostFilter.setHost("events.segment.io", shown: true, candidates: &candidates,
                                 hiddenHosts: &hidden, heldSelection: &held)
        #expect(hidden.isEmpty)
        #expect(held.isEmpty)
        #expect(candidates.map(\.isSelected) == [true, true, false])
    }

    @Test("The host menu names the busiest host shown and counts the other shown hosts")
    func hostMenuTitle() {
        let hosts: [ImportHostFilter.Host] = [
            .init(name: "api.acme.shop", count: 180),
            .init(name: "pay.acme.shop", count: 20),
            .init(name: "events.segment.io", count: 14),
        ]
        func title(hiding hidden: Set<String>) -> String {
            let title = ImportHostFilter.title(hosts: hosts, hiddenHosts: hidden)
            return [title.primary, title.more].compactMap { $0 }.joined(separator: " ")
        }
        #expect(title(hiding: ["events.segment.io"]) == "api.acme.shop +1 host")
        #expect(title(hiding: []) == "api.acme.shop +2 hosts")
        #expect(title(hiding: ["api.acme.shop", "pay.acme.shop"]) == "events.segment.io")
        #expect(title(hiding: Set(hosts.map(\.name))) == "No hosts")
    }

    @Test("A duplicate names the earlier row it repeats; one the project already has names none")
    func duplicatesNameTheirRow() {
        let candidates = [
            candidate(.get, "/products"),
            candidate(.post, "/cart", status: 201),
            candidate(.post, "/cart", status: 409, selected: false, duplicate: true),
            candidate(.get, "/session", selected: false, duplicate: true),
        ]
        #expect(ImportRow.repeatedRows(in: candidates) == [2: 2])
    }

    @Test("The footer explains orange rows first, then refusals, then repeats, else how bodies are saved")
    func footerNotePriority() {
        let orange = "Rows marked in orange are unselected. Select one to import it without its body."
        #expect(ImportRow.footerNote(for: [candidate(binary: true), candidate(status: 206)]) == orange)
        #expect(ImportRow.footerNote(for: [candidate(overLimit: true)]) == orange)
        #expect(ImportRow.footerNote(for: [candidate(unavailable: true)]) == orange)
        #expect(ImportRow.footerNote(for: [candidate(status: 0), candidate(duplicate: true)])
            == "Rows marked Cannot import are refused even when selected. Hover one to see why.")
        #expect(ImportRow.footerNote(for: [candidate(duplicate: true)])
            == "Repeated routes start unselected. Select one to import it as well.")
        #expect(ImportRow.footerNote(for: [candidate()])
            == "Text bodies are saved as captured. Hover a row and use the eye button to preview one.")
    }

    @Test("The subtitle names the file, then the count, and the hosts when there are several")
    func subtitle() {
        let twoHosts = [candidate(host: "api.acme.shop"), candidate(host: "pay.acme.shop")]
        #expect(ImportWorkflowScreen.subtitle(kind: .har, fileName: "checkout-session.har", candidates: twoHosts)
            == "checkout-session.har \u{00B7} 2 requests from 2 hosts")
        #expect(ImportWorkflowScreen.subtitle(kind: .har, fileName: nil, candidates: [candidate()]) == "1 request")
        #expect(ImportWorkflowScreen.subtitle(kind: .openAPI, fileName: "petstore.json", candidates: [candidate(host: nil)])
            == "petstore.json \u{00B7} 1 operation")
    }

    @Test("The sheet opens at the design's height and gives way on a short screen")
    func sheetHeight() {
        #expect(ImportView.preferredHeight(visibleScreenHeight: 1000) == 696)
        #expect(ImportView.preferredHeight(visibleScreenHeight: 700) == 580)
        #expect(ImportView.preferredHeight(visibleScreenHeight: 300) == 360)
    }

    @Test("Starting a new parse switches every host back on")
    func newParseClearsHiddenHosts() {
        let workflow = ImportWorkflow(kind: .har, state: ImportWorkflowState(
            candidates: [candidate()], sourceFileName: "a.har", hiddenHosts: ["api.acme.shop"]
        ))
        #expect(workflow.hiddenHosts == ["api.acme.shop"])
        #expect(workflow.sourceFileName == "a.har")
        workflow.beginParsing()
        #expect(workflow.hiddenHosts.isEmpty)
    }
}
