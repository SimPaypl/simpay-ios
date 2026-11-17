#if os(iOS)
import SwiftUI

/// BLIK Level 0 code entry.
///
/// Six boxes show the typed digits; a hidden text field with the number pad and one-time
/// code autofill receives the input. The model keeps the digits in memory only and clears
/// them on submission. "Pay" is active only with six digits and is disabled while the
/// code is sent, so it cannot be submitted twice.
struct BlikEntryView: View {

    @ObservedObject var model: PaymentSheetModel
    let entry: BlikEntry
    let canChangeMethod: Bool
    let strings: SheetStrings

    @FocusState private var isFieldFocused: Bool
    @ScaledMetric(relativeTo: .title) private var boxHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.text("blik.title"))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(strings.text("blik.hint"))
                    .font(.subheadline)
                    .foregroundStyle(SheetTheme.secondaryText)
            }

            codeField

            if let problem = problemText {
                Label {
                    Text(problem)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(SheetTheme.danger)
                .accessibilityIdentifier("simpay.blik.problem")
            }
            if showsNewPaymentNote {
                Text(strings.text("blik.new_payment"))
                    .font(.footnote)
                    .foregroundStyle(SheetTheme.secondaryText)
            }
            if entry.problem == .codeRejected {
                Text(strings.text("blik.attempts_left", entry.remainingAttempts))
                    .font(.footnote)
                    .foregroundStyle(SheetTheme.secondaryText)
            }

            Button {
                model.submitBlikCode()
            } label: {
                Text(strings.text("action.pay_amount", strings.amount(model.amount, currency: model.currency)))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canSubmitBlikCode)
            .accessibilityIdentifier("simpay.blik.pay")

            if canChangeMethod {
                Button(strings.text("blik.change_method")) { model.changePaymentMethod() }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("simpay.blik.change")
            }
        }
        .onAppear { isFieldFocused = true }
    }

    private var codeField: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .accessibilityHidden(true)

            TextField("", text: Binding(get: { model.blikCode }, set: { model.updateBlikCode($0) }))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFieldFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: boxHeight)
                .opacity(0.02)
                .accessibilityLabel(strings.text("blik.field_label"))
                .accessibilityValue(strings.text("blik.field_value", model.blikCode.count))
                .accessibilityIdentifier("simpay.blik.code")
        }
        .contentShape(Rectangle())
        .onTapGesture { isFieldFocused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let digits = Array(model.blikCode)
        let isCurrent = index == digits.count && isFieldFocused
        return Text(index < digits.count ? String(digits[index]) : "")
            .font(.title.weight(.semibold).monospacedDigit())
            .frame(maxWidth: .infinity, minHeight: boxHeight)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SheetTheme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor(isCurrent: isCurrent), lineWidth: isCurrent || hasProblem ? 2 : 1)
            )
    }

    private var hasProblem: Bool { entry.problem != nil && model.blikCode.isEmpty }

    private func borderColor(isCurrent: Bool) -> Color {
        if hasProblem { return SheetTheme.danger }
        return isCurrent ? SheetTheme.accent : SheetTheme.border
    }

    private var problemText: String? {
        switch entry.problem {
        case .none: return nil
        case .invalidFormat: return strings.text("blik.invalid_code")
        case .codeRejected: return strings.text("blik.rejected_code")
        case .submissionFailed(let error):
            return error.code == .rateLimited ? strings.text("error.rate_limited") : strings.text("blik.submission_failed")
        }
    }

    /// A rejected code closed its transaction: the next code starts a new payment.
    private var showsNewPaymentNote: Bool {
        entry.problem == .codeRejected && entry.transactionID == nil
    }
}

/// Icon or activity indicator with a title and an optional detail.
struct StatusView: View {

    let strings: SheetStrings
    var symbol: String?
    var symbolColor: Color = SheetTheme.secondaryText
    let title: String
    var detail: String?
    var showsProgress = false

    var body: some View {
        VStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(SheetTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
                    .tint(SheetTheme.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        // One element read as "title. detail"; the spinner adds nothing to say.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(showsProgress ? [.updatesFrequently] : [])
    }
}

/// Final result. The wording never claims more than the API reported: an unknown outcome
/// never reads as a failed payment, and pending never reads as paid.
struct ResultView: View {

    let result: SimPayCheckoutResult
    let strings: SheetStrings
    let onDone: () -> Void

    var body: some View {
        let outcome = SheetCopy.outcome(result)
        VStack(spacing: 16) {
            StatusView(
                strings: strings,
                symbol: symbol(outcome.tone),
                symbolColor: color(outcome.tone),
                title: strings.text(outcome.titleKey),
                detail: outcome.detailKey.map(strings.text)
            )
            .accessibilityIdentifier("simpay.result")
            Button(strings.text(outcome.tone == .success ? "action.done" : "action.close"), action: onDone)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("simpay.done")
        }
    }

    private func symbol(_ tone: SheetCopy.Tone) -> String {
        switch tone {
        case .success: return "checkmark.circle.fill"
        case .pending: return "clock.fill"
        case .failure: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .neutral: return "info.circle.fill"
        }
    }

    private func color(_ tone: SheetCopy.Tone) -> Color {
        switch tone {
        case .success: return SheetTheme.success
        case .pending, .unknown: return SheetTheme.pending
        case .failure: return SheetTheme.danger
        case .neutral: return SheetTheme.secondaryText
        }
    }
}
#endif
