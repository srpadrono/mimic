import SwiftUI

extension Service {
    var tint: Color {
        switch self {
        case .auth: return .purple
        case .catalog: return .teal
        case .payments: return .orange
        }
    }
}

struct RootView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(spacing: 0) {
            Header(store: store)
            Divider()
            Group {
                switch store.screen {
                case .signIn: SignInView(store: store)
                case .shop: ShopView(store: store)
                case .receipt(let order): ReceiptView(store: store, order: order)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            NetworkStrip(events: store.network)
        }
        .frame(minWidth: 440, idealWidth: 460, minHeight: 720, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct Header: View {
    let store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bag.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(.indigo.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text("Acme Store").font(.headline)
                Text(store.userName.map { "Signed in as \($0)" } ?? "Not signed in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.screen != .signIn {
                Label("\(store.cartCount)", systemImage: "cart.fill")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityIdentifier("cart-count")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: Sign in

private struct SignInView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("🛍️").font(.system(size: 64))
            Text("Welcome back").font(.title.bold())
            VStack(spacing: 10) {
                TextField("Email", text: $store.email)
                    .accessibilityIdentifier("email")
                SecureField("Password", text: $store.password)
                    .accessibilityIdentifier("password")
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
            Button {
                Task { await store.signIn() }
            } label: {
                Group {
                    if store.isBusy { ProgressView().controlSize(.small) } else { Text("Sign in") }
                }
                .frame(width: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sign-in")
            if let banner = store.banner { BannerView(banner: banner).frame(maxWidth: 320) }
            Spacer()
        }
        .padding(24)
    }
}

// MARK: Shop

private struct ShopView: View {
    @Bindable var store: Store
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            if let banner = store.banner {
                BannerView(banner: banner)
                    .padding([.horizontal, .top], 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ScrollView {
                switch store.catalog {
                case .idle, .loading:
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in SkeletonCard() }
                    }
                    .padding(14)
                    .accessibilityIdentifier("catalog-loading")
                case .offline:
                    OfflineView { Task { await store.loadCatalog() } }
                case .failed(let message):
                    OfflineView(title: "Catalog unavailable", message: message) {
                        Task { await store.loadCatalog() }
                    }
                case .loaded:
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.products) { product in
                            ProductCard(product: product) { store.add(product) }
                        }
                    }
                    .padding(14)
                }
            }
            if store.isCartOpen {
                CartPanel(store: store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !store.cart.isEmpty {
                CartBar(store: store)
            }
        }
        .animation(.snappy, value: store.banner)
        .animation(.snappy, value: store.isCartOpen)
    }
}

private struct ProductCard: View {
    let product: Product
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(product.emoji)
                .font(.system(size: 44))
                .frame(maxWidth: .infinity, minHeight: 74)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
            Text(product.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack {
                Text(Store.money(product.price, product.currency))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add", action: add)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(product.stock == 0)
                    .accessibilityIdentifier("add-\(product.id)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

private struct SkeletonCard: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10).frame(height: 74)
            RoundedRectangle(cornerRadius: 4).frame(width: 110, height: 12)
            RoundedRectangle(cornerRadius: 4).frame(width: 60, height: 12)
        }
        .foregroundStyle(.quaternary)
        .opacity(dim ? 0.45 : 1)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever()) { dim = true }
        }
    }
}

private struct OfflineView: View {
    var title = "You're offline"
    var message = "Acme can't reach the catalog right now."
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("retry-catalog")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
        .padding(.horizontal, 30)
        .accessibilityIdentifier("catalog-offline")
    }
}

private struct CartBar: View {
    let store: Store

    var body: some View {
        HStack {
            Text("\(store.cartCount) items · \(Store.money(store.cartTotal))")
                .font(.callout.weight(.medium).monospacedDigit())
            Spacer()
            Button("Checkout") { store.isCartOpen = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("open-cart")
        }
        .padding(14)
        .background(.bar)
    }
}

private struct CartPanel: View {
    @Bindable var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your cart").font(.headline)
                Spacer()
                Button("Close") { store.isCartOpen = false }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy)
            }
            ForEach(store.cart) { line in
                HStack {
                    Text(line.product.emoji)
                    Text(line.product.name)
                    Text("× \(line.quantity)").foregroundStyle(.secondary)
                    Spacer()
                    Text(Store.money(line.product.price * Double(line.quantity))).monospacedDigit()
                }
                .font(.callout)
            }
            Picker("Pay with", selection: $store.cardID) {
                ForEach(Store.cards) { card in Text(card.label).tag(card.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("card-picker")
            Button {
                Task { await store.checkout() }
            } label: {
                Group {
                    if store.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Pay \(Store.money(store.cartTotal))")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.cart.isEmpty || store.isBusy)
            .accessibilityIdentifier("pay")
        }
        .padding(16)
        .background(.bar)
    }
}

// MARK: Receipt

private struct ReceiptView: View {
    let store: Store
    let order: Order

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: order.orderId)
            Text("Order placed").font(.title.bold())
            Text(order.orderId).font(.title3.monospaced()).foregroundStyle(.secondary)
            Text(Store.money(order.total, order.currency)).font(.title2.monospacedDigit())
            if let banner = store.banner, banner.tone != .success {
                BannerView(banner: banner).frame(maxWidth: 320)
            }
            Button("Keep shopping") { store.startOver() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("keep-shopping")
            Spacer()
        }
        .accessibilityIdentifier("receipt")
    }
}

// MARK: Shared

private struct BannerView: View {
    let banner: Store.Banner

    private var tint: Color {
        switch banner.tone {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    private var symbol: String {
        switch banner.tone {
        case .info: return "info.circle.fill"
        case .warning: return "arrow.clockwise.circle.fill"
        case .error: return "exclamationmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(banner.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout.weight(.medium))
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
        .accessibilityIdentifier("banner")
    }
}

/// The last few calls, newest at the bottom: which service, the route, and how it answered.
struct NetworkStrip: View {
    let events: [NetworkEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("NETWORK").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                ForEach(Service.allCases, id: \.self) { service in
                    HStack(spacing: 4) {
                        Circle().fill(service.tint).frame(width: 7, height: 7)
                        Text(service.rawValue)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(events.suffix(6)) { event in
                HStack(spacing: 8) {
                    Circle().fill(event.service.tint).frame(width: 7, height: 7)
                    Text(event.method).frame(width: 40, alignment: .leading).foregroundStyle(.secondary)
                    Text(event.path).lineLimit(1)
                    Spacer()
                    StatusPill(event: event)
                    Text(event.milliseconds.map { "\($0) ms" } ?? "")
                        .frame(width: 58, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption, design: .monospaced))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.black.opacity(0.82))
        .environment(\.colorScheme, .dark)
        .animation(.snappy, value: events.map(\.id))
        .accessibilityIdentifier("network-strip")
    }
}

private struct StatusPill: View {
    let event: NetworkEvent

    private var text: String {
        if let failure = event.failure { return failure }
        if let status = event.status { return String(status) }
        return "…"
    }

    private var tint: Color {
        if event.failure != nil { return .red }
        guard let status = event.status else { return .gray }
        switch status {
        case 200..<300: return .green
        case 400..<500: return .orange
        default: return .red
        }
    }

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.25)))
            .foregroundStyle(tint)
    }
}
