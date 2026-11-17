/// Reads the status of an existing transaction, outside of a checkout.
///
/// Use it to recover after the checkout was interrupted, for example when the app was
/// terminated while the payer was in the bank: store the id received through
/// `onTransactionCreated` and check it on the next launch. Nothing is persisted by the SDK.
///
/// Each call performs one status read (with one session refresh after HTTP 401); there is
/// no polling and no retry. The answer is what the API reports right now:
/// - `.succeeded` for `transaction_paid`,
/// - `.failed` for a definitive failure (failure, fraud, expired, refunded),
/// - `.pending` for everything else, with `.inProgress` while the payment is processing.
/// `.outcomeUnknown` and `.cancelled` are never returned.
///
/// The result is not proof of payment. Only the merchant backend, after verifying the
/// SimPay webhook, may release goods.
public struct SimPayTransactionStatusChecker: Sendable {

    private let api: AuthorizedAPIClient

    /// Returns `nil` when `serviceID` is not a valid service identifier.
    public init?(serviceID: String, sessionProvider: any SimPaySessionProvider) {
        guard let environment = APIEnvironment(serviceID: serviceID) else { return nil }
        self.init(api: AuthorizedAPIClient(
            client: SimPayAPIClient(environment: environment),
            sessions: SessionStore(provider: sessionProvider)
        ))
    }

    package init(api: AuthorizedAPIClient) {
        self.api = api
    }

    /// Reads the current status of `transactionID`.
    ///
    /// - Throws: ``SimPayCheckoutError`` when the status cannot be read (for example
    ///   `.noInternet`, `.timeout`, `.unauthorized`, `.transactionNotFound`,
    ///   `.sessionFailed`), or `CancellationError` when the calling task is cancelled.
    ///   A thrown error never means the payment failed.
    public func status(of transactionID: TransactionID) async throws -> SimPayCheckoutResult {
        let snapshot: TransactionSnapshot
        do {
            snapshot = try await api.transactionStatus(transactionID)
        } catch let failure as APIFailure {
            throw failure.error
        }
        return snapshot.status.finalResult(for: transactionID)
            ?? .pending(transactionID: transactionID, status: snapshot.status, reason: .init(lastStatus: snapshot.status))
    }
}
