import SwiftUI
import SimPayCheckout

/// A one-product shop whose Pay button opens the SDK payment sheet.
struct DemoStoreView: View {
    @ObservedObject var state: DemoState

    private let indigo = Color(red: 0.16, green: 0.23, blue: 0.54)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    productCard
                    payButton
                    if let text = state.resultText { result(text) }
                    #if DEBUG
                    settings
                    #endif
                }
                .padding(18)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("SimPay Demo")
            .navigationBarTitleDisplayMode(.inline)
            .simPayCheckout(isPresented: $state.isPresenting, checkout: state.checkout, order: state.order) { [weak state] result in
                state?.paymentFinished(result)
            }
        }
    }

    private var productCard: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [indigo.opacity(0.95), Color(red: 0.27, green: 0.45, blue: 0.83)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "headphones")
                    .font(.system(size: 90, weight: .ultraLight))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(height: 190)

            HStack(alignment: .firstTextBaseline) {
                Text("Słuchawki bezprzewodowe")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(state.order.amount.formatted(.currency(code: state.order.currency)))
                    .font(.title3.weight(.bold))
            }
            .padding(18)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var payButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: state.pay) {
                Label("Zapłać przez SimPay", systemImage: "lock.shield")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .foregroundStyle(.white)
                    .background(indigo, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(state.isPresenting)
            .accessibilityIdentifier("demo.pay")

            if let message = state.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func result(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: resultIcon).foregroundStyle(resultColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.subheadline.weight(.medium))
                if let detail = state.resultDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("demo.result")
    }

    #if DEBUG
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tryb", selection: Binding(get: { state.mode }, set: { state.changeMode($0) })) {
                ForEach(DemoMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch state.mode {
            case .fake:
                Picker("Scenariusz", selection: Binding(get: { state.scenario }, set: { state.changeScenario($0) })) {
                    ForEach(DemoScenario.allCases) { Text($0.title).tag($0) }
                }
                Text(state.scenario.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .apiKey:
                TextField("Service ID", text: $state.serviceID)
                SecureField("Klucz API (testowy)", text: $state.apiKey)
                TextField("IP płatnika", text: $state.payerIP)
                    .keyboardType(.numbersAndPunctuation)
                Text("Prawdziwe API SimPay. Tylko klucz testowy — klucza nie umieszcza się w aplikacji produkcyjnej.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .disabled(state.isPresenting)
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
    #endif

    private var resultIcon: String {
        switch state.outcome {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        case nil: "info.circle.fill"
        }
    }

    private var resultColor: Color {
        switch state.outcome {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        case nil: .secondary
        }
    }
}
