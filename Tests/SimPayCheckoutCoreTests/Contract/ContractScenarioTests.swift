import Foundation
import Testing
@_spi(SimPayBridge) @testable import SimPayCheckoutCore

/// Plays every scenario of `Contract/scenarios/` against the real checkout engine.
/// The Android SDK is expected to run the same files (see Contract/README.md).
@MainActor
@Suite("Contract: conformance scenarios")
struct ContractScenarioTests {

    @Test("Scenarios exist and follow the scenario format")
    func scenariosAreWellFormed() throws {
        #expect(Contract.scenarioNames.count >= 25)
        let actions: Set = ["load_channels", "select_channel", "submit_blik_code", "back_to_channels", "run_polling", "lifecycle", "close"]
        let endpoints = Set(ScenarioTransport.Endpoint.allCases.map(\.rawValue))
        for name in Contract.scenarioNames {
            let scenario = try Contract.object(name)
            #expect(scenario["id"] as? String == name.replacingOccurrences(of: "scenarios/", with: ""), "\(name)")
            #expect((scenario["covers"] as? [String])?.isEmpty == false, "\(name)")
            #expect(Set((scenario["api"] as? [String: Any] ?? [:]).keys).isSubset(of: endpoints), "\(name)")
            for step in scenario["steps"] as? [[String: Any]] ?? [] {
                #expect(actions.contains(step["action"] as? String ?? ""), "\(name)")
            }
            let expect = scenario["expect"] as? [String: Any] ?? [:]
            let requests = expect["requests"] as? [String: Int] ?? [:]
            // The number of mutating requests is mandatory in every scenario.
            #expect(requests["create_transaction"] != nil && requests["submit_blik_code"] != nil, "\(name)")
            #expect(SimPayBridge.ResultType.all.contains((expect["result"] as? [String: Any])?["type"] as? String ?? ""), "\(name)")
        }
    }

    @Test("The scenarios cover every required behaviour")
    func coverage() throws {
        let covered = Set(try Contract.scenarioNames.flatMap { try Contract.object($0)["covers"] as? [String] ?? [] })
        let required: Set = [
            "results", "validation", "no_false_success", "deep_link", "no_unsafe_post_retry",
            "blik", "outcome_unknown", "timeouts", "cancellation", "polling", "session", "redirect", "lifecycle",
        ]
        #expect(required.isSubset(of: covered), "missing: \(required.subtracting(covered).sorted())")
    }

    @Test("Scenario outcome matches the contract", arguments: Contract.scenarioNames)
    func scenario(_ name: String) async throws {
        let scenario = try Contract.object(name)
        let expect = try #require(scenario["expect"] as? [String: Any])
        let run = try await ScenarioRunner.run(scenario)

        #expect(run.stepMismatches.isEmpty, "\(run.stepMismatches)")

        // Exactly one final result, in its bridge form.
        let result = try #require(run.result, "the checkout did not finish")
        let actual = SimPayBridge.payload(for: result)
        let expected = try #require(expect["result"] as? [String: Any])
        for key in ["type", "transactionId", "status", "pendingReason"] {
            #expect(Contract.equal(actual[key], expected[key]), "\(key): \(String(describing: actual[key])) != \(String(describing: expected[key]))")
        }
        let actualCode = (actual["error"] as? [String: Any])?["code"] as? String
        let expectedCode = (expected["error"] as? [String: Any])?["code"] as? String
        #expect(actualCode == expectedCode, "error.code")

        // Request counts: mutating requests are always checked.
        for (endpoint, count) in expect["requests"] as? [String: Int] ?? [:] {
            #expect(run.requests[endpoint] == count, "\(endpoint): \(run.requests[endpoint] ?? -1) calls, contract says \(count)")
        }
        if let events = expect["transactionCreatedEvents"] as? Int {
            #expect(run.transactionCreatedEvents == events, "onTransactionCreated")
        }
        if let sessions = expect["sessionRequests"] as? Int {
            #expect(run.sessionRequests == sessions, "session provider calls")
        }

        // Invariants that hold for every scenario.
        #expect(run.requests["create_transaction", default: 0] >= run.transactionCreatedEvents)
        if case .outcomeUnknown = result { #expect(result.transactionID == nil) }
        if case .cancelled = result {
            #expect(run.requests["create_transaction"] == 0 && run.requests["submit_blik_code"] == 0)
        }
    }

    @Test("Every scenario referenced by the unknown outcome policy exists and agrees with it")
    func outcomeUnknownPolicy() throws {
        for situation in try Contract.list("policy/outcome-unknown", "situations") {
            let id = try #require(situation["scenario"] as? String)
            let scenario = try Contract.object("scenarios/" + id)
            let type = ((scenario["expect"] as? [String: Any])?["result"] as? [String: Any])?["type"] as? String
            if situation["result"] as? String == "outcome_unknown" {
                #expect(type == "outcome_unknown", "\(id)")
            } else {
                #expect(type != "outcome_unknown" && type != "failed", "\(id): a known transaction never ends as \(type ?? "nil")")
            }
        }
    }
}
