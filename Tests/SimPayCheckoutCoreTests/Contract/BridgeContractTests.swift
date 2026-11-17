import Foundation
import Testing
@_spi(SimPayBridge) @testable import SimPayCheckoutCore

/// The bridge-v1 payload format used by the Flutter and React Native adapters.
@Suite("Contract: bridge-v1 payloads")
struct BridgeContractTests {

    private func examples(_ key: String) throws -> [[String: Any]] {
        try Contract.list("bridge/bridge-v1-examples", key)
    }

    @Test("Present requests decode exactly as the examples state")
    func presentRequests() throws {
        for entry in try examples("presentRequests") {
            let name = entry["name"] as? String ?? "?"
            var request: SimPayBridge.PresentRequest?
            var error: SimPayCheckoutError?
            do { request = try SimPayBridge.presentRequest(from: entry["payload"] as? [String: Any] ?? [:]) } catch let thrown { error = thrown }

            #expect(Contract.error(error) == entry["expect"] as? String, "\(name)")
            if let decoded = entry["decoded"] as? [String: Any], let request {
                #expect(request.serviceID == decoded["serviceId"] as? String, "\(name)")
                #expect(request.merchantDisplayName == decoded["merchantDisplayName"] as? String, "\(name)")
                #expect(request.order.amount == Decimal(string: decoded["amount"] as? String ?? ""), "\(name)")
                #expect(request.order.currency == decoded["currency"] as? String, "\(name)")
            }
            // Diagnostics name the field, never echo a value.
            #expect(error?.message?.contains("payer@example.com") != true, "\(name)")
        }
    }

    /// Builds the result a payload describes, using only public API.
    private func result(from payload: [String: Any]) throws -> SimPayCheckoutResult {
        let id = (payload["transactionId"] as? String).flatMap(TransactionID.init)
        let status = (payload["status"] as? String).map(TransactionStatus.init(rawValue:))
        let error = (payload["error"] as? [String: Any]).map {
            SimPayCheckoutError(.init(rawValue: $0["code"] as? String ?? ""), message: $0["message"] as? String)
        }
        switch payload["type"] as? String {
        case "succeeded": return .succeeded(transactionID: try #require(id), status: try #require(status))
        case "pending":
            return .pending(transactionID: try #require(id), status: status,
                            reason: .init(rawValue: try #require(payload["pendingReason"] as? String)))
        case "failed": return .failed(try #require(error), transactionID: id, status: status)
        case "outcome_unknown": return .outcomeUnknown(try #require(error))
        case "cancelled": return .cancelled
        default: throw ScenarioError("unknown result type")
        }
    }

    @Test("Every result encodes to exactly the example payload")
    func results() throws {
        let entries = try examples("results")
        #expect(Set(entries.compactMap { ($0["payload"] as? [String: Any])?["type"] as? String }) == Set(SimPayBridge.ResultType.all))
        for entry in entries {
            let expected = try #require(entry["payload"] as? [String: Any])
            let encoded = SimPayBridge.payload(for: try result(from: expected))
            #expect(NSDictionary(dictionary: encoded).isEqual(to: expected), "\(entry["name"] ?? "?"): \(encoded)")
            // Payloads are plain JSON for Dart and TypeScript.
            #expect(JSONSerialization.isValidJSONObject(encoded))
        }
    }

    @Test("The transaction created event matches the example")
    func transactionCreated() throws {
        let expected = try #require(try examples("events").first?["payload"] as? [String: Any])
        let event = SimPayBridge.transactionCreatedEvent(Sample.transactionID)
        #expect(NSDictionary(dictionary: event).isEqual(to: expected))
    }

    @Test("Transaction ids from Dart or TypeScript are validated")
    func transactionIDs() throws {
        for entry in try examples("transactionIds") {
            let text = try #require(entry["text"] as? String)
            var valid = true
            do { _ = try SimPayBridge.transactionID(from: text) } catch { valid = false }
            #expect(valid == entry["valid"] as? Bool, "\(text)")
        }
    }

    @Test("No payload ever carries a session token")
    func noTokenInPayloads() throws {
        let session = try SimPayBridge.session(from: ["token": Sample.token, "payerIp": Sample.ip])
        let outputs: [[String: Any]] = [
            SimPayBridge.payload(for: .failed(SimPayCheckoutError(.sessionFailed), transactionID: nil, status: nil)),
            SimPayBridge.payload(for: .succeeded(transactionID: Sample.transactionID, status: .paid)),
            SimPayBridge.transactionCreatedEvent(Sample.transactionID),
        ]
        for output in outputs {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
            #expect(!text.contains("secret-payload") && !text.contains(Sample.ip))
        }
        #expect(!everyTextualForm(of: session).contains("secret-payload"))
    }

    @Test("The JSON Schema declares every bridge message")
    func schema() throws {
        let definitions = try #require(try Contract.object("schema/bridge-v1.schema")["$defs"] as? [String: Any])
        for name in ["presentRequest", "order", "configuration", "session", "sessionRequest", "result", "error",
                     "transactionCreatedEvent", "statusRequest", "returnUrlRequest"] {
            #expect(definitions[name] != nil, "\(name)")
        }
        let result = try #require(definitions["result"] as? [String: Any])
        let types = ((result["properties"] as? [String: Any])?["type"] as? [String: Any])?["enum"] as? [String]
        #expect(types == SimPayBridge.ResultType.all)
        let amount = try #require((definitions["amount"] as? [String: Any])?["pattern"] as? String)
        #expect(amount == (try Contract.object("validation/amounts"))["grammar"] as? String)
    }
}
