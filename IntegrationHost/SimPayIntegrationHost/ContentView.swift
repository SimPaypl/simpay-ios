import SwiftUI
import UIKit
@_spi(Testing) import SimPayCheckout

struct ContentView: View {

    @ObservedObject var host: HostState

    var body: some View {
        NavigationStack {
            // Not a List: List is lazy, and rows outside short windows (foldable iPhones,
            // accessibility text sizes) would be missing from the tree UI tests read.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("MOCK API: no network, no real payments", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("host.mockBanner")

                    group("Scenario") {
                        Picker("Scenario", selection: Binding(get: { host.scenario }, set: { host.select($0) })) {
                            ForEach(Scenario.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .accessibilityIdentifier("host.scenario")
                    }

                    group("Present") {
                        Button("Pay 149,99 zł (SwiftUI)") { host.isPaying = true }
                            .accessibilityIdentifier("host.pay.swiftui")
                        Button("Pay 149,99 zł (UIKit)") { presentFromUIKit() }
                            .accessibilityIdentifier("host.pay.uikit")
                    }

                    group("Results (one per payment)") {
                        Text(host.results.isEmpty ? "-" : host.results.joined(separator: ", "))
                            .accessibilityIdentifier("host.results")
                        Text("transactions created: \(host.createdTransactions.count)")
                            .accessibilityIdentifier("host.created")
                    }

                    group("Return URLs") {
                        ForEach(Array(host.returnLog.enumerated()), id: \.offset) { item in
                            Text(item.element).font(.caption.monospaced())
                        }
                        Text("count: \(host.returnLog.count)").accessibilityIdentifier("host.returns")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("SimPay Host")
            .simPayCheckout(
                isPresented: $host.isPaying,
                checkout: host.checkout,
                order: host.order,
                onTransactionCreated: { [weak host] id in host?.transactionCreated(id) },
                onCompletion: { [weak host] result in host?.finished(result) }
            )
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// The UIKit integration path, as an app without SwiftUI would use it.
    private func presentFromUIKit() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        let host = self.host
        host.checkout.present(host.order, from: root, onTransactionCreated: { id in
            host.transactionCreated(id)
        }) { result in
            host.finished(result)
        }
    }
}
