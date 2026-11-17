import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("Response decoding")
struct ResponseDecodingTests {

    // MARK: Channels

    @Test("Parses the Android example payload with the same expectations as MobileSdkResponseParserTest")
    func channelsExamplePayload() async throws {
        let json = String(decoding: try Fixture.data(named: "api/fixtures/channels-example"), as: UTF8.self)
        let channels = try await Sample.client(StubTransport(status: 200, json: json)).fetchChannels(session: Sample.session)

        try #require(channels.count == 2)
        let blik = channels[0]
        #expect(blik.id == "blik")
        #expect(blik.name == "BLIK")
        #expect(blik.type == "blik")
        #expect(blik.imageURL?.absoluteString == "https://example-host/img/blik.png")
        #expect(blik.currencies == ["PLN"])
        #expect(blik.minimumAmount == Decimal(string: "1.00"))
        #expect(blik.maximumAmount == Decimal(string: "5000.00"))

        let transfer = channels[1]
        #expect(transfer.id == "12")                       // numeric id kept as text
        #expect(transfer.imageURL == nil)
        #expect(transfer.currencies == ["PLN", "EUR"])
        #expect(transfer.minimumAmount == 2)
        #expect(transfer.maximumAmount == 100)
    }

    @Test("Parses an empty channel list")
    func emptyChannels() async throws {
        let channels = try await Sample.client(StubTransport(status: 200, json: #"{"success":true,"data":[]}"#)).fetchChannels(session: Sample.session)
        #expect(channels.isEmpty)
    }

    @Test("Tolerates missing optional fields and skips unusable entries")
    func tolerantChannels() async throws {
        let json = #"""
        {"success":true,"extra":1,"data":[
          {"id":"card","name":"Card","currencies":["PLN"]},
          {"name":"No id"},
          {"id":"  "},
          "not-an-object",
          {"id":"mbank","name":"","type":"null","img":"http://insecure/logo.png","currencies":["PLN",5,null],"amount":{"min":"1.005","max":null}},
          {"id":"decimal","amount":{"min":0.1,"max":5000.5}}
        ]}
        """#
        let channels = try await Sample.client(StubTransport(status: 200, json: json)).fetchChannels(session: Sample.session)

        #expect(channels.map(\.id) == ["card", "mbank", "decimal"])
        #expect(channels[0].minimumAmount == nil && channels[0].maximumAmount == nil && channels[0].type == nil)
        #expect(channels[1].name == "mbank")             // blank name falls back to id
        #expect(channels[1].type == nil)                 // "null" text is missing
        #expect(channels[1].imageURL == nil)             // only https logos are kept
        #expect(channels[1].currencies == ["PLN"])
        #expect(channels[1].minimumAmount == Decimal(string: "1.005"))
        #expect(channels[2].minimumAmount == Decimal(string: "0.1"))
        #expect(channels[2].maximumAmount == Decimal(string: "5000.5"))
    }

    @Test("success:false on channels maps to channels_failed, like Android")
    func channelsUnsuccessful() async {
        let failure = await apiFailure { _ = try await Sample.client(StubTransport(status: 200, json: #"{"success":false}"#)).fetchChannels(session: Sample.session) }
        #expect(failure?.error.code == .channelsFailed)
        #expect(failure?.kind == .transient)
    }

    @Test("Malformed channels body maps to invalid_response", arguments: ["not-json", "", "[]", #"{"success":true}"#, #"{"success":true,"data":{}}"#])
    func channelsMalformed(_ body: String) async {
        let failure = await apiFailure { _ = try await Sample.client(StubTransport(status: 200, json: body)).fetchChannels(session: Sample.session) }
        #expect(failure?.error.code == .invalidResponse)
        #expect(failure?.kind == .transient)
    }

    // MARK: Created transaction

    @Test("Parses a created transaction")
    func createdTransaction() async throws {
        let created = try await Sample.client(StubTransport(status: 200, json: Sample.createdJSON))
            .createTransaction(Sample.createRequest(), session: Sample.session)

        #expect(created.transactionID == Sample.transactionID)
        #expect(created.redirectURL?.absoluteString == "https://secure.simpay.pl/pay/abc")
    }

    @Test("A missing or non-https redirect keeps the created transaction", arguments: [
        #"{"success":true,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301"}}"#,
        #"{"success":true,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","redirectUrl":""}}"#,
        #"{"success":true,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","redirectUrl":"http://insecure/pay"}}"#,
        #"{"success":true,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","redirectUrl":"javascript:alert(1)"}}"#,
    ])
    func createdWithoutRedirect(_ body: String) async throws {
        let created = try await Sample.client(StubTransport(status: 201, json: body))
            .createTransaction(Sample.createRequest(), session: Sample.session)

        #expect(created.transactionID == Sample.transactionID)
        #expect(created.redirectURL == nil)
    }

    @Test("A 2xx without a valid transaction id is outcome_unknown, never a failure", arguments: [
        "",
        "not-json",
        #"{}"#,
        #"{"success":true}"#,
        #"{"success":true,"data":{}}"#,
        #"{"success":true,"data":{"redirectUrl":"https://secure.simpay.pl/pay/abc"}}"#,
        #"{"success":true,"data":{"transactionId":"not-a-uuid"}}"#,
        #"{"success":true,"data":{"transactionId":12345}}"#,
        #"{"success":false,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301"}}"#,
        #"{"success":"true","data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301"}}"#,
    ])
    func createdUnusable(_ body: String) async {
        let failure = await apiFailure {
            _ = try await Sample.client(StubTransport(status: 200, json: body)).createTransaction(Sample.createRequest(), session: Sample.session)
        }
        #expect(failure?.error.code == .outcomeUnknown)
        #expect(failure?.kind == .outcomeUnknown)
    }

    // MARK: BLIK

    @Test("BLIK accepted with 204 or an empty or successful 2xx body", arguments: [
        (204, ""), (200, ""), (200, #"{"success":true}"#), (202, "not-json"),
    ])
    func blikAccepted(_ status: Int, _ body: String) async throws {
        let transport = StubTransport(status: status, json: body)
        try await Sample.client(transport).submitBlikCode(Sample.blikCode, transactionID: Sample.transactionID, session: Sample.session)

        let request = try #require(transport.requests.first)
        #expect(request.bodyText == #"{"ticket":{"T6":"482913"}}"#)
        #expect(request.url == APIEndpoint.submitBlikCode(Sample.transactionID).url(in: Sample.environment))
    }

    @Test("A 2xx BLIK answer stating failure is outcome_unknown")
    func blikContradictoryBody() async {
        let failure = await apiFailure {
            try await Sample.client(StubTransport(status: 200, json: #"{"success":false}"#))
                .submitBlikCode(Sample.blikCode, transactionID: Sample.transactionID, session: Sample.session)
        }
        #expect(failure?.kind == .outcomeUnknown)
    }

    // MARK: Status

    @Test("Reads the status from any of the three documented keys", arguments: ["status", "transactionStatus", "transaction_status"])
    func statusKeys(_ key: String) async throws {
        let json = #"{"success":true,"data":{"\#(key)":"transaction_paid"}}"#
        let snapshot = try await Sample.client(StubTransport(status: 200, json: json)).transactionStatus(Sample.transactionID, session: Sample.session)

        #expect(snapshot.transactionID == Sample.transactionID)
        #expect(snapshot.status == .paid)
    }

    @Test("Keeps unknown statuses verbatim")
    func unknownStatus() async throws {
        let json = #"{"success":true,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","status":"transaction_something_new"}}"#
        let snapshot = try await Sample.client(StubTransport(status: 200, json: json)).transactionStatus(Sample.transactionID, session: Sample.session)
        #expect(snapshot.status.rawValue == "transaction_something_new")
        #expect(!snapshot.status.isRecognized)
    }

    @Test("Unusable status responses are invalid_response and safe to repeat", arguments: [
        "not-json",
        #"{"success":false}"#,
        #"{"success":true}"#,
        #"{"success":true,"data":{}}"#,
        #"{"success":true,"data":{"status":"  "}}"#,
        #"{"success":true,"data":{"transactionId":"11111111-2222-3333-4444-555555555555","status":"transaction_paid"}}"#,
    ])
    func statusUnusable(_ body: String) async {
        let failure = await apiFailure {
            _ = try await Sample.client(StubTransport(status: 200, json: body)).transactionStatus(Sample.transactionID, session: Sample.session)
        }
        #expect(failure?.error.code == .invalidResponse)
        #expect(failure?.kind == .transient)
    }
}
