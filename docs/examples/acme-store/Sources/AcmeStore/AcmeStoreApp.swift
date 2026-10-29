import AppKit
import SwiftUI

@main
struct AcmeStoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()

    var body: some Scene {
        Window("Acme Store", id: "store") {
            RootView(store: store)
                .task {
                    guard let autoplay = Autoplay(arguments: CommandLine.arguments) else { return }
                    await autoplay.run(store)
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.leading)
    }
}

/// `swift run` starts a plain executable, which macOS would leave in the background with no Dock
/// icon. This makes it a regular app that comes to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `--autoplay` walks the checkout the way a person would, at a pace a screen recording can follow:
/// sign in, add two products, open the cart, pay. It reacts to what the backend does: Retry when
/// the catalog is offline, the other card after a decline, pay again when an item sold out.
///
/// When it finishes it prints one line, `ACME_RESULT {json}`, so a script (or an agent) can check
/// the outcome without reading the screen. `--quit-after N` quits N seconds after that.
struct Autoplay {
    var step: Duration = .milliseconds(1100)
    var quitAfter: Int?

    init?(arguments: [String]) {
        guard arguments.contains("--autoplay") else { return nil }
        if let index = arguments.firstIndex(of: "--quit-after"), index + 1 < arguments.count {
            quitAfter = Int(arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--step-ms"), index + 1 < arguments.count,
           let milliseconds = Int(arguments[index + 1]) {
            step = .milliseconds(milliseconds)
        }
    }

    @MainActor
    func run(_ store: Store) async {
        try? await Task.sleep(for: step)
        await store.signIn()

        var catalogRetries = 0
        while store.catalog == .offline || store.catalog.isFailure, catalogRetries < 2 {
            catalogRetries += 1
            try? await Task.sleep(for: step * 2)
            await store.loadCatalog()
        }

        for product in store.products.filter({ $0.stock > 0 }).prefix(2) {
            try? await Task.sleep(for: step)
            store.add(product)
        }

        if !store.cart.isEmpty {
            try? await Task.sleep(for: step)
            store.isCartOpen = true
            var payments = 0
            while store.screen == .shop, !store.cart.isEmpty, payments < 3 {
                payments += 1
                try? await Task.sleep(for: step)
                await store.checkout()
                guard store.screen == .shop, let banner = store.banner else { break }
                if banner.text.localizedCaseInsensitiveContains("declined") {
                    try? await Task.sleep(for: step)
                    store.cardID = Store.cards[1].id
                } else if !banner.text.localizedCaseInsensitiveContains("sold out") {
                    break
                }
            }
        }

        report(store)
        if let quitAfter {
            try? await Task.sleep(for: .seconds(quitAfter))
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func report(_ store: Store) {
        var result: [String: Any] = [
            "banners": store.bannerHistory,
            "requests": store.network.map { event in
                "\(event.method) \(event.path) \(event.failure ?? event.status.map { String($0) } ?? "pending")"
            },
        ]
        switch store.screen {
        case .receipt(let order):
            result["outcome"] = "paid"
            result["orderId"] = order.orderId
        case .shop:
            result["outcome"] = store.catalog == .loaded ? "not paid" : "catalog unavailable"
        case .signIn:
            result["outcome"] = "signed out"
        }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
        print("ACME_RESULT " + (String(data: data, encoding: .utf8) ?? "{}"))
        fflush(stdout)
    }
}

private extension Store.CatalogState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
