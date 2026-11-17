#if os(iOS)
import Combine
import SwiftUI
import UIKit

/// Hosts the payment sheet as a native page sheet and enforces the dismissal rules.
///
/// - While a mutating request is in flight the sheet cannot be swiped away
///   (`isModalInPresentation` and the presentation delegate both refuse it).
/// - If the sheet disappears anyway (the host app dismisses it programmatically, or
///   dismisses a controller below it), the model is told and the engine settles the
///   request in flight before a result is reported. The outcome is never guessed.
/// - It shows and hides the payment page browser as the model asks. Each request is
///   handled once (by its attempt number), so SwiftUI updates can never open it twice.
final class PaymentSheetController: UIHostingController<PaymentSheetView>, UIAdaptivePresentationControllerDelegate {

    let model: PaymentSheetModel
    private let browser: any PaymentPageBrowser
    private var observations: Set<AnyCancellable> = []
    private var handledAttempt = 0

    init(model: PaymentSheetModel, strings: SheetStrings, browser: any PaymentPageBrowser) {
        self.model = model
        self.browser = browser
        super.init(rootView: PaymentSheetView(model: model, strings: strings))
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presentationController?.delegate = self

        model.$isDismissLocked
            .sink { [weak self] locked in self?.isModalInPresentation = locked }
            .store(in: &observations)
        // Delivered after the property changed, so the model can be updated in turn.
        model.$browser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.follow(state) }
            }
            .store(in: &observations)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A page requested before the sheet finished appearing is opened now.
        follow(model.browser)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Covers programmatic dismissal by the host app; harmless after a normal finish.
        // Presenting the payment page above the sheet is not a dismissal.
        if isBeingDismissed || presentingViewController == nil || (navigationController?.isBeingDismissed ?? false) {
            browser.close()
            model.sheetWasDismissed()
        }
    }

    private func follow(_ state: PaymentSheetModel.Browser) {
        switch state {
        case .requested(let url, let attempt):
            guard attempt > handledAttempt, model.browser == state else { return }
            guard viewIfLoaded?.window != nil else { return }   // retried in viewDidAppear
            handledAttempt = attempt
            let opened = browser.open(url, from: self) { [weak model] in model?.browserDidClose() }
            if opened { model.browserDidOpen() } else { model.browserFailedToOpen() }
        case .closed:
            if browser.isOpen { browser.close() }
        case .open:
            break
        }
    }

    // MARK: UIAdaptivePresentationControllerDelegate

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !model.isDismissLocked
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        model.sheetWasDismissed()
    }
}
#endif
