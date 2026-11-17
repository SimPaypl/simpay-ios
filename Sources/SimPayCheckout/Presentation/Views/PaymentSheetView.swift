#if os(iOS)
import SwiftUI

/// Root view of the payment sheet: brand bar, payment summary, the current screen and the
/// security note. Renders ``PaymentSheetModel/screen`` and forwards taps to the model.
struct PaymentSheetView: View {

    @ObservedObject var model: PaymentSheetModel
    let strings: SheetStrings

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SummaryCard(model: model, strings: strings)
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SecureNote(strings: strings)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(SheetTheme.background.ignoresSafeArea())
        .tint(SheetTheme.accent)
        .onChange(of: model.screen) { _ in
            // VoiceOver users hear that the content changed (progress, result, error).
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// Opens the page of the existing transaction again; never creates a new one.
    @ViewBuilder
    private var reopenButton: some View {
        if model.canReopenPaymentPage {
            Button(strings.text("redirect.reopen")) { model.reopenPaymentPage() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("simpay.redirect.reopen")
        }
    }

    private var topBar: some View {
        HStack {
            SimPayBrand(strings: strings)
            Spacer()
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SheetTheme.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(model.isDismissLocked)
            .accessibilityLabel(strings.text("sheet.close"))
            .accessibilityHint(model.isDismissLocked ? strings.text("sheet.processing_hint") : "")
            .accessibilityIdentifier("simpay.close")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .loadingChannels:
            StatusView(strings: strings, title: strings.text("channels.loading"), showsProgress: true)

        case .channels(let list):
            ChannelListView(list: list, strings: strings) { model.selectChannel(id: $0) }

        case .emptyChannels:
            VStack(spacing: 16) {
                StatusView(strings: strings, symbol: "creditcard.trianglebadge.exclamationmark", title: strings.text("channels.empty"))
                Button(strings.text("action.close")) { model.close() }
                    .buttonStyle(SecondaryButtonStyle())
            }

        case .blikEntry(let entry, let canChangeMethod):
            BlikEntryView(model: model, entry: entry, canChangeMethod: canChangeMethod, strings: strings)

        case .progress(let progress):
            switch progress {
            case .preparingPayment:
                StatusView(strings: strings, title: strings.text("progress.preparing"), showsProgress: true)
            case .sendingCode:
                StatusView(strings: strings, title: strings.text("progress.sending_code"), showsProgress: true)
            case .checkingStatus:
                VStack(spacing: 16) {
                    StatusView(
                        strings: strings,
                        title: strings.text("progress.checking_status"),
                        detail: strings.text("progress.checking_status_detail"),
                        showsProgress: true
                    )
                    .accessibilityIdentifier("simpay.checking")
                    reopenButton
                }
            }

        case .awaitingBank:
            StatusView(
                strings: strings,
                symbol: "iphone.radiowaves.left.and.right",
                symbolColor: SheetTheme.accent,
                title: strings.text("progress.awaiting_bank"),
                detail: strings.text("progress.awaiting_bank_detail"),
                showsProgress: true
            )
            .accessibilityIdentifier("simpay.awaiting")

        case .redirecting:
            VStack(spacing: 16) {
                StatusView(
                    strings: strings,
                    symbol: "safari",
                    symbolColor: SheetTheme.accent,
                    title: strings.text("redirect.opening"),
                    detail: strings.text("redirect.detail"),
                    showsProgress: !model.canReopenPaymentPage
                )
                reopenButton
            }

        case .failure(let error, let canRetry):
            VStack(spacing: 16) {
                StatusView(
                    strings: strings,
                    symbol: "exclamationmark.triangle.fill",
                    symbolColor: SheetTheme.danger,
                    title: strings.text("result.failure_title"),
                    detail: strings.text(SheetCopy.errorKey(error.code))
                )
                if canRetry {
                    Button(strings.text("action.try_again")) { model.retry() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("simpay.retry")
                }
                Button(strings.text("action.close")) { model.close() }
                    .buttonStyle(SecondaryButtonStyle())
            }

        case .result(let result):
            ResultView(result: result, strings: strings) { model.close() }
        }
    }
}

/// Recipient on the left, amount due on the right, like the SimPay gateway. Stacks
/// vertically when large text does not fit on one line.
struct SummaryCard: View {
    @ObservedObject var model: PaymentSheetModel
    let strings: SheetStrings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: 12) {
                    recipient
                    amount(alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    recipient
                    Spacer(minLength: 8)
                    amount(alignment: .trailing)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SheetTheme.cornerRadius, style: .continuous).fill(SheetTheme.surface))
        .overlay(alignment: .bottom) {
            // Accent bar, as on the Android sheet and the web gateway.
            Capsule().fill(SheetTheme.accent).frame(height: 3).padding(.horizontal, 16)
        }
        .accessibilityElement(children: .combine)
    }

    private var recipient: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(strings.text("sheet.recipient"))
                .font(.caption)
                .foregroundStyle(SheetTheme.secondaryText)
            Text(model.merchantName)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func amount(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(strings.text("sheet.amount_due"))
                .font(.caption)
                .foregroundStyle(SheetTheme.secondaryText)
            Text(strings.amount(model.amount, currency: model.currency))
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .accessibilityIdentifier("simpay.amount")
        }
    }
}

struct SecureNote: View {
    let strings: SheetStrings

    var body: some View {
        Label {
            Text(strings.text("sheet.secure_note")).foregroundStyle(SheetTheme.secondaryText)
        } icon: {
            Image(systemName: "lock").foregroundStyle(SheetTheme.secondaryText)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}
#endif
