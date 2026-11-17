import Foundation
import Testing
@_spi(SimPayBridge) @testable import SimPayCheckoutCore

/// Validation, amounts, session, BLIK, polling and retry rules of the shared contract.
@Suite("Contract: policies and validation")
struct ContractPolicyTests {

    // MARK: Manifest and hygiene

    @Test("The manifest lists existing files and matches the SDK")
    func manifest() throws {
        let manifest = try Contract.object("contract")
        let version = try #require(manifest["contractVersion"] as? String)
        #expect(version.split(separator: ".").count == 3)
        #expect(manifest["bridgeFormatVersion"] as? Int == SimPayBridge.version)
        for (key, value) in manifest["files"] as? [String: String] ?? [:] {
            let path = Fixture.contractDirectory.appendingPathComponent(value).path
            #expect(FileManager.default.fileExists(atPath: path), "\(key): \(value)")
        }
    }

    /// Every JSON file of the contract, relative to `Contract/`.
    private static func allFiles() throws -> [String] {
        let root = Fixture.contractDirectory
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var names: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            names.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1).dropLast(5)))
        }
        return names.sorted()
    }

    @Test("Every contract file is valid JSON")
    func filesParse() throws {
        let files = try Self.allFiles()
        #expect(files.count >= 40)
        for name in files {
            #expect(throws: Never.self, "\(name)") { _ = try JSONSerialization.jsonObject(with: Fixture.data(named: name)) }
        }
    }

    @Test("No real tokens, e-mail addresses or IP addresses in the contract")
    func syntheticDataOnly() throws {
        for name in try Self.allFiles() {
            let text = String(decoding: try Fixture.data(named: name), as: UTF8.self)
            for token in text.matches(of: #"mobsdk_[A-Za-z0-9_]*"#) {
                #expect(token.hasPrefix("mobsdk_test_") || token == "mobsdk_", "\(name): \(token)")
            }
            #expect(!text.contains("eyJ"), "\(name): looks like a JWT")
            for email in text.matches(of: #"(?<![:/A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) {
                #expect(email.hasSuffix("example.com"), "\(name): \(email)")
            }
            for ip in text.matches(of: #"\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b"#) {
                #expect(["192.0.2.", "198.51.100.", "203.0.113."].contains { ip.hasPrefix($0) }, "\(name): \(ip)")
            }
        }
    }

    @Test("Every error code used anywhere in the contract is defined in codes.json")
    func codesAreDefined() throws {
        let defined = Set(try Contract.list("codes/codes", "errorCodes").compactMap { $0["code"] as? String })
        func check(_ code: String?, _ file: String) {
            guard let code, code != "valid" else { return }
            #expect(defined.contains(code), "\(file): \(code)")
        }
        for file in ["api/http-error-mapping", "api/transport-error-mapping"] {
            for entry in try Contract.list(file, "cases") { check(entry["code"] as? String, file) }
        }
        for entry in try Contract.list("api/status-mapping", "cases") { check(entry["errorCode"] as? String, "status-mapping") }
        for entry in try Contract.list("validation/order-validation", "cases") { check(entry["expect"] as? String, "order-validation") }
        for entry in try Contract.list("bridge/bridge-v1-examples", "presentRequests") { check(entry["expect"] as? String, "bridge") }
        for name in Contract.scenarioNames {
            let result = ((try Contract.object(name))["expect"] as? [String: Any])?["result"] as? [String: Any]
            check((result?["error"] as? [String: Any])?["code"] as? String, name)
        }
    }

    // MARK: Order validation and amounts

    @Test("Order validation follows the contract")
    func orderValidation() throws {
        let file = try Contract.object("validation/order-validation")
        let base = try #require(file["base"] as? [String: Any])
        for entry in file["cases"] as? [[String: Any]] ?? [] {
            let name = entry["name"] as? String ?? "?"
            let fields = base.merging(entry["order"] as? [String: Any] ?? [:]) { $1 }
            var order: SimPayOrder?
            var error: SimPayCheckoutError?
            do { order = try SimPayBridge.order(from: fields) } catch let thrown { error = thrown }

            #expect(Contract.error(error) == entry["expect"] as? String, "\(name)")
            if let country = entry["resolvedCountryCode"] as? String {
                #expect(order?.resolvedCountryCode == country, "\(name)")
            }
        }
    }

    @Test("Amount text follows the strict grammar")
    func amountParsing() throws {
        let file = try Contract.object("validation/amounts")
        let grammar = try #require(file["grammar"] as? String)
        for entry in file["parsing"] as? [[String: Any]] ?? [] {
            let text = try #require(entry["text"] as? String)
            let valid = try #require(entry["valid"] as? Bool)
            #expect((SimPayBridge.amount(from: text) != nil) == valid, "\(text)")
            // The grammar in the file says the same as the parser.
            #expect((text.range(of: grammar, options: .regularExpression) != nil) == valid, "grammar: \(text)")
        }
    }

    @Test("Amounts are written to JSON exactly, never through binary floating point")
    func amountSerialization() throws {
        for entry in try Contract.list("validation/amounts", "serialization") {
            let text = try #require(entry["amount"] as? String)
            let amount = try #require(SimPayBridge.amount(from: text))
            #expect(try RequestBodyFactory.numberLiteral(amount) == entry["json"] as? String, "\(text)")
        }
        // The literal also lands unchanged in the request body.
        let body = String(decoding: try RequestBodyFactory.createTransaction(Sample.createRequest(amount: "1.1")), as: UTF8.self)
        #expect(body.contains(#""amount":1.1,"#) || body.contains(#""amount":1.1}"#))
    }

    // MARK: Session

    @Test("Session timing matches the contract")
    func sessionTiming() throws {
        let expiry = try #require(try Contract.object("policy/session")["expiry"] as? [String: Any])
        #expect(SessionStore.defaultRefreshMargin == .seconds(expiry["refreshMarginSeconds"] as? Int ?? -1))
        #expect(SessionStore.minimumReuse == .seconds(expiry["minimumReuseSeconds"] as? Int ?? -1))
    }

    @Test("Sessions delivered through a bridge are decoded as the contract states")
    func bridgeSessions() throws {
        let bridge = try #require(try Contract.object("policy/session")["bridgeSession"] as? [String: Any])
        for entry in bridge["cases"] as? [[String: Any]] ?? [] {
            var error: SimPayCheckoutError?
            do { _ = try SimPayBridge.session(from: entry["session"] as? [String: Any] ?? [:]) } catch let thrown { error = thrown }
            #expect(Contract.error(error) == entry["expect"] as? String, "\(entry["name"] ?? "?")")
            // A rejected session never echoes the token.
            #expect(error?.message?.contains("mobsdk_") != true)
        }
    }

    // MARK: BLIK

    @Test("BLIK rules match the contract")
    func blik() throws {
        let file = try Contract.object("policy/blik")
        #expect(file["directChannel"] as? String == BlikLevel0.directChannel)
        let limit = try #require(file["rejectionLimit"] as? [String: Any])
        #expect(limit["maximumRejections"] as? Int == BlikLevel0.maximumRejections)

        let code = try #require(file["code"] as? [String: Any])
        for valid in code["valid"] as? [String] ?? [] { #expect(BlikCode(valid) != nil, "\(valid)") }
        for invalid in code["invalid"] as? [String] ?? [] { #expect(BlikCode(invalid) == nil, "\(invalid)") }

        let template = try #require((file["request"] as? [String: Any])?["body"] as? String)
        let body = String(decoding: try RequestBodyFactory.blikLevel0(try #require(BlikCode("482913"))), as: UTF8.self)
        #expect(body == template.replacingOccurrences(of: "<code>", with: "482913"))
    }

    // MARK: Polling

    @Test("Polling timing matches the contract")
    @MainActor
    func polling() throws {
        let file = try Contract.object("policy/polling")
        let policy = PollingPolicy.default
        #expect(policy.initialInterval == .seconds(file["initialIntervalSeconds"] as? Int ?? -1))
        #expect(policy.maximumInterval == .seconds(file["maximumIntervalSeconds"] as? Int ?? -1))
        #expect(policy.budget == .seconds(file["budgetSeconds"] as? Int ?? -1))
        #expect(StatusPoller.maximumSessionFailures == file["maximumConsecutiveSessionFailures"] as? Int)

        var interval = policy.initialInterval
        var intervals: [Duration] = []
        for _ in 0..<5 {
            intervals.append(interval)
            interval = policy.interval(after: interval)
        }
        #expect(intervals == (file["intervalsSeconds"] as? [Int] ?? []).map { .seconds($0) })
    }

    // MARK: Retry and transport errors

    private static func endpoint(_ name: String) -> APIEndpoint? {
        switch name {
        case "channels": return .channels
        case "create_transaction": return .createTransaction
        case "submit_blik_code": return .submitBlikCode(Sample.transactionID)
        case "transaction_status": return .transactionStatus(Sample.transactionID)
        default: return nil
        }
    }

    private static func kindName(_ kind: FailureKind) -> String {
        switch kind {
        case .notDelivered: return "not_delivered"
        case .rejected: return "rejected"
        case .transient: return "transient"
        case .outcomeUnknown: return "outcome_unknown"
        }
    }

    @Test("Transport failures are classified per endpoint as the contract states")
    func transportErrors() throws {
        let all = ["channels", "create_transaction", "submit_blik_code", "transaction_status"]
        for entry in try Contract.list("api/transport-error-mapping", "cases") {
            let failureName = try #require(entry["failure"] as? String)
            let endpointName = try #require(entry["endpoint"] as? String)
            for name in endpointName == "*" ? all : [endpointName] {
                let endpoint = try #require(Self.endpoint(name))
                let failure = ErrorClassifier.classify(transportError: try ScenarioTransport.transportError(failureName), endpoint: endpoint)
                #expect(failure.error.code.rawValue == entry["code"] as? String, "\(failureName) on \(name)")
                #expect(Self.kindName(failure.kind) == entry["kind"] as? String, "\(failureName) on \(name)")
            }
        }
    }

    @Test("Failure kinds mean what the retry policy says; no mutating outcome_unknown is repeatable")
    func retryKinds() throws {
        let kinds = try Contract.list("policy/retry", "kinds")
        let safe = Dictionary(uniqueKeysWithValues: kinds.compactMap { k in (k["kind"] as? String).map { ($0, k["safeToRepeat"] as? Bool ?? false) } })
        #expect(Set(safe.keys) == ["not_delivered", "rejected", "transient", "outcome_unknown"])

        for entry in try Contract.list("api/http-error-mapping", "cases") {
            let endpoint = try #require(Self.endpoint(entry["endpoint"] as? String ?? ""))
            let failure = ErrorClassifier.classify(statusCode: entry["status"] as? Int ?? 0, body: Data(), endpoint: endpoint)
            #expect((failure.kind != .outcomeUnknown) == safe[Self.kindName(failure.kind)], "\(entry["endpoint"] ?? "") \(entry["status"] ?? "")")
        }

        let mutating = try Contract.list("policy/retry", "endpoints").filter { $0["mutating"] as? Bool == true }
        #expect(Set(mutating.compactMap { $0["endpoint"] as? String }) == ["create_transaction", "submit_blik_code"])
        for entry in mutating { #expect(entry["automaticRetry"] as? String == "never") }
    }
}
