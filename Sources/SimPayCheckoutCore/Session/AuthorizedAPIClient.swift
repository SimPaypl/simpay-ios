/// The mobile SDK API with session handling.
///
/// Every call obtains a valid session from ``SessionStore`` first. HTTP 401 rules:
/// - Read-only requests: the session is replaced once and the request repeated once.
///   A second 401 is final. No other failure is repeated here.
/// - Mutating requests: never repeated. After a 401 the rejected session is dropped so
///   that the next operation starts with a new one.
///
/// Every failure is thrown as ``APIFailure``; a session that cannot be obtained becomes
/// `notDelivered`, because no request was sent. `CancellationError` passes through.
package struct AuthorizedAPIClient: Sendable {

    package let client: SimPayAPIClient
    package let sessions: SessionStore

    package init(client: SimPayAPIClient, sessions: SessionStore) {
        self.client = client
        self.sessions = sessions
    }

    // MARK: Read-only

    package func fetchChannels() async throws -> [PaymentChannel] {
        try await read(.channels) { session in try await client.fetchChannels(session: session) }
    }

    package func transactionStatus(_ transactionID: TransactionID) async throws -> TransactionSnapshot {
        try await read(.transactionStatus(transactionID)) { session in
            try await client.transactionStatus(transactionID, session: session)
        }
    }

    // MARK: Mutating

    /// Creates a direct-channel transaction.
    ///
    /// The payer IP is taken from the very session used to send the request, falling back
    /// to `order.payerIPOverride`; it is never invented.
    package func createTransaction(order: SimPayOrder, directChannel: String, userAgent: String) async throws -> CreatedTransaction {
        let endpoint = APIEndpoint.createTransaction
        let lease = try await lease(for: endpoint)

        let request: CreateTransactionRequest
        do {
            request = try CreateTransactionRequest(
                order: order,
                directChannel: directChannel,
                payerIP: lease.session.payerIP ?? order.payerIPOverride,
                userAgent: userAgent
            )
        } catch {
            throw APIFailure(error.code, kind: .notDelivered, endpoint: endpoint, message: error.message)
        }

        return try await mutate(endpoint, lease: lease) { session in
            try await client.createTransaction(request, session: session)
        }
    }

    /// Submits a BLIK Level 0 code. Success only means the bank was asked to confirm.
    package func submitBlikCode(_ code: BlikCode, transactionID: TransactionID) async throws {
        let endpoint = APIEndpoint.submitBlikCode(transactionID)
        let lease = try await lease(for: endpoint)
        try await mutate(endpoint, lease: lease) { session in
            try await client.submitBlikCode(code, transactionID: transactionID, session: session)
        }
    }

    // MARK: Policies

    private func read<T>(_ endpoint: APIEndpoint, _ call: (SimPaySession) async throws -> T) async throws -> T {
        let first = try await lease(for: endpoint)
        do {
            return try await call(first.session)
        } catch let failure as APIFailure where Self.isUnauthorized(failure) {
            // Exactly one replacement and one repetition; reads change nothing on the server.
            let second = try await lease(for: endpoint, replacing: first)
            do {
                return try await call(second.session)
            } catch let failure as APIFailure where Self.isUnauthorized(failure) {
                await sessions.invalidate(second)
                throw failure
            }
        }
    }

    private func mutate<T>(_ endpoint: APIEndpoint, lease: SessionLease, _ call: (SimPaySession) async throws -> T) async throws -> T {
        do {
            return try await call(lease.session)
        } catch let failure as APIFailure where Self.isUnauthorized(failure) {
            // Not repeated: the API has not confirmed that a 401 guarantees no side effect.
            // The next operation will fetch a new session instead.
            await sessions.invalidate(lease)
            throw failure
        }
    }

    private static func isUnauthorized(_ failure: APIFailure) -> Bool {
        failure.httpStatus == 401
    }

    /// A valid session, or a new one replacing `rejected`.
    private func lease(for endpoint: APIEndpoint, replacing rejected: SessionLease? = nil) async throws -> SessionLease {
        do {
            if let rejected { return try await sessions.sessionReplacing(rejected) }
            return try await sessions.validSession()
        } catch let error as SimPayCheckoutError {
            throw APIFailure(error.code, kind: .notDelivered, endpoint: endpoint, message: error.message, isSessionFailure: true)
        }
    }
}
