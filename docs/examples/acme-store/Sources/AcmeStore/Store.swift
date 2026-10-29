import Foundation
import Observation

/// Everything the window shows, and the checkout rules.
@MainActor
@Observable
final class Store {
    enum Screen: Equatable {
        case signIn
        case shop
        case receipt(Order)
    }

    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case failed(String)
    }

    /// The message across the top of the shop. `tone` picks its colour.
    struct Banner: Equatable {
        enum Tone { case info, warning, error, success }
        let tone: Tone
        let text: String
    }

    struct CartLine: Identifiable, Equatable {
        var id: String { product.id }
        let product: Product
        var quantity: Int
    }

    struct Card: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let cards = [
        Card(id: "card_visa_4242", label: "Visa •••• 4242"),
        Card(id: "card_mastercard_5555", label: "Mastercard •••• 5555"),
    ]

    var screen: Screen = .signIn
    var email = "sam@acme.test"
    var password = "mimic"
    var userName: String?
    var products: [Product] = []
    var catalog: CatalogState = .idle
    var cart: [CartLine] = []
    var cardID = Store.cards[0].id
    var banner: Banner?
    var isBusy = false
    var isCartOpen = false
    var network: [NetworkEvent] = []
    /// Every banner shown since sign-in, in order. Autoplay prints it so a script can check a run.
    private(set) var bannerHistory: [String] = []

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var api: APIClient!

    init() {
        api = APIClient { [weak self] event in self?.record(event) }
    }

    var cartCount: Int { cart.reduce(0) { $0 + $1.quantity } }
    var cartTotal: Double { cart.reduce(0) { $0 + $1.product.price * Double($1.quantity) } }

    // MARK: Sign in

    func signIn() async {
        isBusy = true
        defer { isBusy = false }
        struct Credentials: Encodable { let email: String; let password: String }
        do {
            let reply = try await api.send(.auth, "POST", "/auth/login",
                                           body: Credentials(email: email, password: password))
            guard reply.status == 200, let session = try? reply.decode(Session.self) else {
                show(.error, reply.errorBody?.message ?? "Those details didn't work.")
                return
            }
            self.session = session
            userName = session.user.name
            bannerHistory = []
            banner = nil
            screen = .shop
            await loadCatalog()
        } catch {
            show(.error, "Can't reach Acme. Check your connection.")
        }
    }

    func signOut() {
        session = nil
        userName = nil
        cart = []
        products = []
        catalog = .idle
        isCartOpen = false
        screen = .signIn
    }

    // MARK: Catalog

    func loadCatalog() async {
        catalog = .loading
        do {
            let reply = try await api.send(.catalog, "GET", "/products", token: session?.token)
            guard reply.status == 200, let list = try? reply.decode(ProductList.self) else {
                catalog = .failed(reply.errorBody?.message ?? "The catalog is unavailable (\(reply.status)).")
                return
            }
            products = list.products
            catalog = .loaded
        } catch {
            catalog = .offline
        }
    }

    func add(_ product: Product) {
        if let index = cart.firstIndex(where: { $0.product.id == product.id }) {
            cart[index].quantity += 1
        } else {
            cart.append(CartLine(product: product, quantity: 1))
        }
    }

    // MARK: Checkout

    /// How many times checkout tries `POST /orders` while Payments answers 503. The Payments spec
    /// asks clients for three attempts, honouring `Retry-After`.
    let maxPaymentAttempts = 3

    func checkout() async {
        guard !cart.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        banner = nil

        var attempt = 1
        var refreshed = false
        while true {
            let order = OrderRequest(
                items: cart.map { OrderLine(productId: $0.product.id, quantity: $0.quantity) },
                paymentMethod: cardID
            )
            let reply: HTTPReply
            do {
                reply = try await api.send(.payments, "POST", "/orders", body: order, token: session?.token)
            } catch {
                show(.error, "Payment didn't go through: no connection. You have not been charged.")
                return
            }

            switch reply.status {
            case 200, 201:
                guard let placed = try? reply.decode(Order.self) else {
                    show(.error, "Payment went through but the receipt didn't load.")
                    return
                }
                cart = []
                isCartOpen = false
                show(.success, "Paid \(Self.money(placed.total, placed.currency))")
                screen = .receipt(placed)
                return

            case 401 where !refreshed:
                refreshed = true
                guard await refreshSession() else {
                    show(.error, "Your session expired. Sign in again.")
                    signOut()
                    return
                }
                show(.info, "Session refreshed")
                continue

            case 402:
                show(.error, reply.errorBody?.message ?? "Your card was declined. Try another card.")
                return

            case 409 where reply.errorBody?.error == "out_of_stock":
                let soldOut = reply.errorBody?.productId
                let name = cart.first { $0.product.id == soldOut }?.product.name ?? "An item"
                cart.removeAll { $0.product.id == soldOut }
                show(.warning, "\(name) just sold out and was removed from your cart.")
                return

            case 503:
                if attempt < maxPaymentAttempts - 1 {
                    attempt += 1
                    show(.warning, "Payments is busy. Retrying (\(attempt) of \(maxPaymentAttempts))…")
                    let wait = Double(reply.headers["retry-after"] ?? "1") ?? 1
                    try? await Task.sleep(for: .seconds(min(wait, 5)))
                    continue
                }
                show(.error, "Payments is unavailable. Try again in a minute.")
                return

            default:
                show(.error, reply.errorBody?.message ?? "Something went wrong (\(reply.status)).")
                return
            }
        }
    }

    private func refreshSession() async -> Bool {
        guard let session else { return false }
        struct Refresh: Encodable { let refreshToken: String }
        guard let reply = try? await api.send(.auth, "POST", "/auth/refresh",
                                              body: Refresh(refreshToken: session.refreshToken)),
              reply.status == 200,
              let fresh = try? reply.decode(RefreshedToken.self) else { return false }
        self.session = Session(token: fresh.token, refreshToken: session.refreshToken, user: session.user)
        return true
    }

    func startOver() {
        banner = nil
        screen = .shop
    }

    // MARK: Helpers

    private func show(_ tone: Banner.Tone, _ text: String) {
        banner = Banner(tone: tone, text: text)
        bannerHistory.append(text)
    }

    private func record(_ event: NetworkEvent) {
        if let index = network.firstIndex(where: { $0.id == event.id }) {
            network[index] = event
        } else {
            network.append(event)
            if network.count > 40 { network.removeFirst(network.count - 40) }
        }
    }

    static func money(_ amount: Double, _ currency: String = "USD") -> String {
        amount.formatted(.currency(code: currency))
    }
}
