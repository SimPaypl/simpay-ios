/// Supplies a mobile SDK access session, normally obtained from the merchant backend.
///
/// The backend calls `POST /payment/{serviceId}/mobile-sdk/session` with the merchant API
/// key and returns the token, its expiry and the payer IP it observed. The API key must
/// never be shipped in the app; the SDK deliberately offers no provider that accepts one.
///
/// The SDK calls this method when it has no session, when the current one is about to
/// expire, or after the API rejected the token with HTTP 401. Calls are never concurrent
/// for one checkout. Implementations should always return a fresh session.
///
/// Throw a ``SimPayCheckoutError`` to report a specific code (for example
/// `.noInternet`); any other error is reported as `.sessionFailed`. Error descriptions are
/// never forwarded, so they may safely contain backend details.
public protocol SimPaySessionProvider: Sendable {
    func provideSession() async throws -> SimPaySession
}
