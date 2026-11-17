import Foundation

/// Client of the four mobile SDK endpoints.
///
/// Every method performs exactly one transport call and never retries. Failures are
/// thrown as ``APIFailure`` (classified for the endpoint), or as `CancellationError`
/// when a read-only request is cancelled or a mutating one is cancelled before sending.
///
/// A mutating request that has been handed to the transport is always awaited to
/// completion, even if the calling task is cancelled: abandoning it would turn a known
/// outcome into an unknown one.
package struct SimPayAPIClient: Sendable {

    package let environment: APIEnvironment
    private let transport: any HTTPTransport

    package init(environment: APIEnvironment, transport: any HTTPTransport = URLSessionTransport()) {
        self.environment = environment
        self.transport = transport
    }

    /// Sent with every request. Identifies the SDK, contains no device or user data.
    package static let userAgent = "\(SDKInfo.name)/\(SDKInfo.version)"

    // MARK: Endpoints

    /// `GET /payment/{serviceId}/mobile-sdk/channels`
    package func fetchChannels(session: SimPaySession) async throws -> [PaymentChannel] {
        let endpoint = APIEndpoint.channels
        let response = try await send(endpoint, session: session, body: nil)

        let envelope = try successfulEnvelope(LossyDTO<[LossyDTO<ChannelDTO>]>.self, from: response, endpoint: endpoint, failureCode: .channelsFailed)
        guard let list = envelope.data?.value else {
            throw ErrorClassifier.unusableSuccessBody(statusCode: response.statusCode, endpoint: endpoint, reason: "Channels response is missing the data list")
        }
        return list.compactMap { $0.value?.toDomain() }
    }

    /// `POST /payment/{serviceId}/transactions`
    ///
    /// Any 2xx answer without a valid `transactionId` is `outcomeUnknown`: the server
    /// signalled success, so a transaction may exist.
    package func createTransaction(_ request: CreateTransactionRequest, session: SimPaySession) async throws -> CreatedTransaction {
        let endpoint = APIEndpoint.createTransaction
        let body = try encodedBody(endpoint) { () throws(SimPayCheckoutError) in try RequestBodyFactory.createTransaction(request) }
        let response = try await send(endpoint, session: session, body: body)

        let envelope = try successfulEnvelope(CreatedTransactionDTO.self, from: response, endpoint: endpoint)
        guard let rawID = envelope.data?.transactionId?.value, let transactionID = TransactionID(rawID) else {
            throw ErrorClassifier.unusableSuccessBody(statusCode: response.statusCode, endpoint: endpoint, reason: "Transaction response is missing a valid transactionId")
        }

        // A missing or non-https redirect does not undo the transaction; the caller
        // tracks it by id and decides how to continue.
        let redirectURL = envelope.data?.redirectUrl?.value
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }

        return CreatedTransaction(transactionID: transactionID, redirectURL: redirectURL)
    }

    /// `POST /payment/{serviceId}/blik/level0/{transactionId}`
    ///
    /// Success means only that a confirmation request was pushed to the banking app.
    /// It never means the transaction was paid.
    package func submitBlikCode(_ code: BlikCode, transactionID: TransactionID, session: SimPaySession) async throws {
        let endpoint = APIEndpoint.submitBlikCode(transactionID)
        let body = try encodedBody(endpoint) { () throws(SimPayCheckoutError) in try RequestBodyFactory.blikLevel0(code) }
        let response = try await send(endpoint, session: session, body: body)

        // The API answers 204. A body explicitly stating failure contradicts the status,
        // so the submission state is unknown rather than accepted.
        if !response.body.isEmpty,
           let envelope = try? JSONDecoder().decode(EnvelopeDTO<LossyDTO<String>>.self, from: response.body),
           envelope.success == false {
            throw ErrorClassifier.unusableSuccessBody(statusCode: response.statusCode, endpoint: endpoint, reason: "API reported an unsuccessful response with a 2xx status")
        }
    }

    /// `GET /payment/{serviceId}/mobile-sdk/transactions/{transactionId}`
    package func transactionStatus(_ transactionID: TransactionID, session: SimPaySession) async throws -> TransactionSnapshot {
        let endpoint = APIEndpoint.transactionStatus(transactionID)
        let response = try await send(endpoint, session: session, body: nil)

        let envelope = try successfulEnvelope(TransactionStatusDTO.self, from: response, endpoint: endpoint)
        guard let data = envelope.data, let raw = data.rawStatus else {
            throw ErrorClassifier.unusableSuccessBody(statusCode: response.statusCode, endpoint: endpoint, reason: "Status response is missing the status")
        }
        // A status reported for a different transaction must never be applied to this one.
        if let reported = data.transactionId?.value.flatMap(TransactionID.init), reported != transactionID {
            throw ErrorClassifier.unusableSuccessBody(statusCode: response.statusCode, endpoint: endpoint, reason: "Status response refers to a different transaction")
        }
        return TransactionSnapshot(transactionID: transactionID, status: TransactionStatus(rawValue: raw))
    }

    // MARK: Request execution

    package func makeRequest(_ endpoint: APIEndpoint, session: SimPaySession, body: Data?) -> URLRequest {
        var request = URLRequest(
            url: endpoint.url(in: environment),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: URLSessionTransport.requestTimeout
        )
        request.httpMethod = endpoint.method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(session.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Performs one call and returns a 2xx response, or throws.
    private func send(_ endpoint: APIEndpoint, session: SimPaySession, body: Data?) async throws -> HTTPResponse {
        // Nothing has been sent yet, so cancelling here is always safe.
        try Task.checkCancellation()

        let request = makeRequest(endpoint, session: session, body: body)
        let response: HTTPResponse

        if endpoint.isMutating {
            // Detached from the caller's cancellation: once handed to the transport the
            // request is awaited to the end, so its outcome is never lost.
            let transport = self.transport
            do {
                response = try await Task { try await transport.send(request) }.value
            } catch {
                throw ErrorClassifier.classify(transportError: error, endpoint: endpoint)
            }
        } else {
            do {
                response = try await transport.send(request)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw ErrorClassifier.classify(transportError: error, endpoint: endpoint)
            }
        }

        guard (200...299).contains(response.statusCode) else {
            throw ErrorClassifier.classify(statusCode: response.statusCode, body: response.body, headers: response.headers, endpoint: endpoint)
        }
        return response
    }

    /// Decodes a 2xx envelope that must report `success: true`.
    ///
    /// - Parameter failureCode: code of a read-only endpoint reporting `success: false`.
    private func successfulEnvelope<Payload: Decodable>(
        _ payload: Payload.Type,
        from response: HTTPResponse,
        endpoint: APIEndpoint,
        failureCode: SimPayCheckoutError.Code = .invalidResponse
    ) throws(APIFailure) -> EnvelopeDTO<Payload> {
        guard let envelope = try? JSONDecoder().decode(EnvelopeDTO<Payload>.self, from: response.body) else {
            throw ErrorClassifier.unusableSuccessBody(statusCode: response.statusCode, endpoint: endpoint, reason: "Malformed response")
        }
        guard envelope.success == true else {
            throw ErrorClassifier.unusableSuccessBody(
                statusCode: response.statusCode, endpoint: endpoint, readCode: failureCode,
                reason: "API reported an unsuccessful response with a 2xx status"
            )
        }
        return envelope
    }

    /// Body encoding happens before sending, so its failure is `notDelivered`.
    private func encodedBody(_ endpoint: APIEndpoint, _ make: () throws(SimPayCheckoutError) -> Data) throws(APIFailure) -> Data {
        do {
            return try make()
        } catch {
            throw APIFailure(error.code, kind: .notDelivered, endpoint: endpoint, message: error.message)
        }
    }
}
