import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("Mutating request safety")
struct MutatingSafetyTests {

    /// Every way a create call can end, used to prove it is never repeated.
    static let createOutcomes: [(String, StubTransport.Reply)] = [
        ("201 created", .response(HTTPResponse(statusCode: 201, body: Data(Sample.createdJSON.utf8)))),
        ("timeout", .failure(URLError(.timedOut))),
        ("connection lost", .failure(URLError(.networkConnectionLost))),
        ("TLS failure", .failure(URLError(.secureConnectionFailed))),
        ("no internet", .failure(URLError(.notConnectedToInternet))),
        ("HTTP 401", .response(HTTPResponse(statusCode: 401))),
        ("HTTP 429", .response(HTTPResponse(statusCode: 429))),
        ("HTTP 500", .response(HTTPResponse(statusCode: 500))),
        ("HTTP 503", .response(HTTPResponse(statusCode: 503))),
        ("2xx empty body", .response(HTTPResponse(statusCode: 200))),
        ("2xx malformed body", .response(HTTPResponse(statusCode: 200, body: Data("{".utf8)))),
        ("2xx without transaction id", .response(HTTPResponse(statusCode: 200, body: Data(#"{"success":true,"data":{}}"#.utf8)))),
    ]

    @Test("One createTransaction call makes at most one transport call", arguments: createOutcomes.map(\.0))
    func createIsNeverRepeated(_ name: String) async throws {
        let reply = try #require(Self.createOutcomes.first { $0.0 == name }?.1)
        let transport = StubTransport(reply)

        _ = try? await Sample.client(transport).createTransaction(Sample.createRequest(), session: Sample.session)

        #expect(transport.callCount == 1)
    }

    static let blikOutcomes: [StubTransport.Reply] = [
        .failure(URLError(.timedOut)),
        .failure(URLError(.networkConnectionLost)),
        .response(HTTPResponse(statusCode: 500)),
        .response(HTTPResponse(statusCode: 409)),
        .response(HTTPResponse(statusCode: 204)),
    ]

    @Test("One submitBlikCode call makes at most one transport call", arguments: blikOutcomes.indices)
    func blikIsNeverRepeated(_ index: Int) async {
        let transport = StubTransport(Self.blikOutcomes[index])

        try? await Sample.client(transport).submitBlikCode(Sample.blikCode, transactionID: Sample.transactionID, session: Sample.session)

        #expect(transport.callCount == 1)
    }

    @Test("Read requests are not retried by the client either")
    func readsAreNotRetried() async {
        let transport = StubTransport(.failure(URLError(.timedOut)))
        _ = try? await Sample.client(transport).fetchChannels(session: Sample.session)
        #expect(transport.callCount == 1)
    }

    @Test("A task cancelled before sending sends nothing")
    func cancelledBeforeSending() async {
        let transport = StubTransport(status: 201, json: Sample.createdJSON)
        let client = Sample.client(transport)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.createTransaction(Sample.createRequest(), session: Sample.session)
        }
        let result = await task.result

        #expect(transport.callCount == 0)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("Cancelling the caller does not abandon a POST already handed to the transport")
    func cancelledWhileSending() async throws {
        let transport = StubTransport(.response(HTTPResponse(statusCode: 201, body: Data(Sample.createdJSON.utf8))), delay: .milliseconds(200))
        let client = Sample.client(transport)

        let task = Task { try await client.createTransaction(Sample.createRequest(), session: Sample.session) }
        try await waitUntil { transport.callCount == 1 }
        task.cancel()

        // The real outcome is still delivered instead of being lost.
        let created = try await task.value
        #expect(created.transactionID == Sample.transactionID)
        #expect(transport.callCount == 1)
    }

    @Test("Cancelling a read request surfaces CancellationError, not a network failure")
    func cancelledRead() async throws {
        let transport = StubTransport(.response(HTTPResponse(statusCode: 200, body: Data(#"{"success":true,"data":[]}"#.utf8))), delay: .seconds(5))
        let client = Sample.client(transport)

        let task = Task { try await client.fetchChannels(session: Sample.session) }
        try await waitUntil { transport.callCount == 1 }
        task.cancel()

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
