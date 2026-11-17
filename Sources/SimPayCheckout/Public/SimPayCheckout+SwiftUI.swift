#if os(iOS)
import SwiftUI
import SimPayCheckoutCore

extension View {

    /// Presents the SimPay payment sheet when `isPresented` becomes `true`.
    ///
    /// `onCompletion` receives exactly one result, after which `isPresented` is reset to
    /// `false`. Setting `isPresented` to `false` while the sheet is shown does not close
    /// it: a payment may be in progress, and only the payer or the result ends it.
    ///
    /// ```swift
    /// Button("Pay") { isPaying = true }
    ///     .simPayCheckout(isPresented: $isPaying, checkout: checkout, order: order) { result in
    ///         handle(result)
    ///     }
    /// ```
    public func simPayCheckout(
        isPresented: Binding<Bool>,
        checkout: SimPayCheckout,
        order: SimPayOrder,
        onTransactionCreated: (@MainActor @Sendable (TransactionID) -> Void)? = nil,
        onCompletion: @escaping @MainActor (SimPayCheckoutResult) -> Void
    ) -> some View {
        background(
            CheckoutPresenterHost(
                isPresented: isPresented,
                checkout: checkout,
                order: order,
                onTransactionCreated: onTransactionCreated,
                onCompletion: onCompletion
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }
}

/// Invisible controller placed in the SwiftUI hierarchy to present the sheet from.
private struct CheckoutPresenterHost: UIViewControllerRepresentable {

    @Binding var isPresented: Bool
    let checkout: SimPayCheckout
    let order: SimPayOrder
    let onTransactionCreated: (@MainActor @Sendable (TransactionID) -> Void)?
    let onCompletion: @MainActor (SimPayCheckoutResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.host = self
        guard isPresented, !coordinator.isPresenting else { return }
        coordinator.isPresenting = true
        // Present on the next turn of the main actor, once the controller is in a window.
        Task { @MainActor [weak controller] in
            guard let controller, let host = coordinator.host else { return }
            host.checkout.present(host.order, from: controller, onTransactionCreated: host.onTransactionCreated) { result in
                coordinator.isPresenting = false
                coordinator.host?.isPresented = false
                coordinator.host?.onCompletion(result)
            }
        }
    }

    @MainActor
    final class Coordinator {
        var host: CheckoutPresenterHost?
        var isPresenting = false
    }
}
#endif
