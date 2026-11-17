import Foundation
import Testing
@testable import SimPayCheckoutCore

@MainActor
@Suite("StatusPoller")
struct StatusPollerTests {

    private let id = Sample.transactionID

    // MARK: Schedule

    @Test("Reads at once, then every 2 s doubling up to 5 s, like the Android SDK")
    func schedule() async {
        let harness = PollerHarness()
        harness.reader.script(.status("transaction_new"))
        harness.poller.start()

        for _ in 0..<4 {
            #expect(await harness.settle())
            harness.clock.advanceToNextDeadline()
        }
        #expect(await harness.settle())
        #expect(harness.clock.sleepRequests == [.seconds(2), .seconds(4), .seconds(5), .seconds(5), .seconds(5)])
        #expect(harness.reader.calls == 5)
        #expect(harness.statuses.value.count == 5)
        harness.poller.stop()
    }

    @Test("Policy values match the contract")
    func policyDefaults() {
        let policy = PollingPolicy.default
        #expect(policy.initialInterval == .seconds(2))
        #expect(policy.maximumInterval == .seconds(5))
        #expect(policy.budget == .seconds(120))
    }

    // MARK: Status mapping

    @Test("transaction_paid ends polling with success")
    func paid() async {
        let harness = PollerHarness()
        harness.reader.script(.status("transaction_new"), .status("transaction_paid"))
        harness.poller.start()
        await harness.runToEnd()

        #expect(harness.outcomes.value == [.resolved(.succeeded(transactionID: id, status: .paid))])
        #expect(harness.reader.calls == 2)
        #expect(harness.poller.phase == .finished)
        #expect(harness.clock.pendingSleeps == 0)
    }

    @Test("Definitive failures end polling as failed",
          arguments: ["transaction_failure", "transaction_fraud", "transaction_expired", "transaction_refunded"])
    func definitiveFailure(_ raw: String) async {
        let harness = PollerHarness()
        harness.reader.script(.status(raw))
        harness.poller.start()
        await harness.runToEnd()

        guard case .resolved(.failed(let error, let transactionID, let status)) = harness.outcomes.value.first else {
            Issue.record("unexpected outcome \(harness.outcomes.value)")
            return
        }
        #expect(error.code == .transactionFailed)
        #expect(transactionID == id)
        #expect(status?.rawValue == raw)
        #expect(harness.reader.calls == 1)
    }

    @Test("Processing statuses keep polling", arguments: ["transaction_new", "transaction_generated", "transaction_confirmed"])
    func processing(_ raw: String) async {
        let harness = PollerHarness()
        harness.reader.script(.status(raw))
        harness.poller.start()
        #expect(await harness.settle())

        #expect(harness.outcomes.value.isEmpty)
        #expect(harness.statuses.value == [TransactionStatus(rawValue: raw)])
        #expect(harness.poller.phase == .running)
        harness.poller.stop()
    }

    @Test("Fraud possibility is pending verification; an unknown status is pending, never success")
    func pendingStatuses() async {
        let verification = PollerHarness()
        verification.reader.script(.status("transaction_fraud_possibility"))
        verification.poller.start()
        await verification.runToEnd()
        #expect(verification.outcomes.value == [.resolved(.pending(transactionID: id, status: .fraudPossibility, reason: .verificationRequired))])

        let unknown = PollerHarness()
        unknown.reader.script(.status("transaction_paid_maybe"))
        unknown.poller.start()
        await unknown.runToEnd()
        #expect(unknown.outcomes.value == [.resolved(.pending(
            transactionID: id, status: TransactionStatus(rawValue: "transaction_paid_maybe"), reason: .unrecognizedStatus
        ))])
    }

    // MARK: Budget

    @Test("The budget ends polling with the last status; a final read happens at the deadline")
    func budgetExhausted() async {
        let harness = PollerHarness(policy: Polling.shortPolicy)
        harness.reader.script(.status("transaction_new"))
        harness.poller.start()
        await harness.runToEnd()

        #expect(harness.outcomes.value == [.budgetExhausted(lastStatus: .new)])
        #expect(harness.reader.calls == 4)                       // 0, 2, 6, 10 s
        #expect(harness.clock.now == .seconds(10))
        #expect(harness.poller.remainingBudget == .zero)
    }

    @Test("Only failures until the budget ends: no status, never failed")
    func budgetWithErrorsOnly() async {
        let harness = PollerHarness(policy: Polling.shortPolicy)
        harness.reader.script(.failure(Polling.offline), .failure(Polling.timeout), .failure(Polling.serverError))
        harness.poller.start()
        await harness.runToEnd()

        #expect(harness.outcomes.value == [.budgetExhausted(lastStatus: nil)])
        #expect(harness.reader.calls == 4)                       // 0, 2, 6, 10 s, all failed
    }

    // MARK: Failures

    @Test("Temporary failures never end polling", arguments: [Polling.offline, Polling.timeout, Polling.serverError, Polling.unreadable])
    func temporaryFailures(_ failure: APIFailure) async {
        let harness = PollerHarness()
        harness.reader.script(.failure(failure), .failure(failure), .status("transaction_paid"))
        harness.poller.start()
        await harness.runToEnd()

        #expect(harness.outcomes.value == [.resolved(.succeeded(transactionID: id, status: .paid))])
        #expect(harness.reader.calls == 3)
    }

    @Test("HTTP 429 waits for Retry-After instead of the interval")
    func retryAfter() async {
        let harness = PollerHarness()
        harness.reader.script(.failure(Polling.rateLimited(retryAfter: .seconds(30))), .status("transaction_paid"))
        harness.poller.start()
        #expect(await harness.settle())

        #expect(harness.clock.sleepRequests == [.seconds(30)])
        harness.poller.wake()                                    // a wake does not cut the server's delay
        harness.clock.advance(by: .seconds(29))
        #expect(harness.reader.calls == 1)
        harness.clock.advance(by: .seconds(1))
        await harness.runToEnd()
        #expect(harness.reader.calls == 2)
        #expect(harness.outcomes.value == [.resolved(.succeeded(transactionID: id, status: .paid))])
    }

    @Test("HTTP 429 without Retry-After uses the normal interval")
    func rateLimitedWithoutHeader() async {
        let harness = PollerHarness()
        harness.reader.script(.failure(Polling.rateLimited(retryAfter: nil)))
        harness.poller.start()
        #expect(await harness.settle())
        #expect(harness.clock.sleepRequests == [.seconds(2)])
        harness.poller.stop()
    }

    @Test("A Retry-After beyond the budget ends polling without another read")
    func retryAfterBeyondBudget() async {
        let harness = PollerHarness(policy: Polling.shortPolicy)
        harness.reader.script(.status("transaction_new"), .failure(Polling.rateLimited(retryAfter: .seconds(60))))
        harness.poller.start()
        await harness.runToEnd()

        #expect(harness.outcomes.value == [.budgetExhausted(lastStatus: .new)])
        #expect(harness.reader.calls == 2)
    }

    @Test("A status that cannot be read any more ends polling as unavailable", arguments: [Polling.unauthorized, Polling.notFound])
    func finalReadFailure(_ failure: APIFailure) async {
        let harness = PollerHarness()
        harness.reader.script(.status("transaction_new"), .failure(failure))
        harness.poller.start()
        await harness.runToEnd()

        #expect(harness.outcomes.value == [.statusUnavailable(failure.error, lastStatus: .new)])
        #expect(harness.reader.calls == 2)
    }

    @Test("Repeated session failures stop polling; an intermediate success resets the count")
    func sessionFailures() async {
        let harness = PollerHarness()
        harness.reader.script(
            .failure(Polling.sessionFailed), .failure(Polling.sessionFailed), .status("transaction_new"),
            .failure(Polling.sessionFailed), .failure(Polling.sessionFailed), .failure(Polling.sessionFailed)
        )
        harness.poller.start()
        await harness.runToEnd()

        #expect(harness.reader.calls == 6)
        #expect(harness.outcomes.value == [.statusUnavailable(Polling.sessionFailed.error, lastStatus: .new)])
    }

    @Test("A provider failure with its own error code also counts as a session failure")
    func providerFailureWithOwnCode() async {
        let harness = PollerHarness()
        harness.reader.script(.failure(Polling.providerOffline), .failure(Polling.providerOffline), .failure(Polling.providerOffline))
        harness.poller.start()
        await harness.runToEnd()

        #expect(harness.reader.calls == 3)
        #expect(harness.outcomes.value == [.statusUnavailable(Polling.providerOffline.error, lastStatus: nil)])
    }

    // MARK: Pause, resume, stop

    @Test("Pause stops reading and keeps the budget; time while paused is not counted")
    func pauseKeepsBudget() async {
        let harness = PollerHarness(policy: Polling.shortPolicy)
        harness.reader.script(.status("transaction_new"))
        harness.poller.start()
        #expect(await harness.settle())

        harness.clock.advance(by: .seconds(1))
        harness.poller.pause()
        #expect(harness.poller.phase == .paused)
        #expect(harness.poller.remainingBudget == .seconds(9))

        harness.clock.advance(by: .seconds(600))                 // the payer is in the bank
        #expect(harness.reader.calls == 1)
        #expect(harness.poller.remainingBudget == .seconds(9))

        #expect(harness.poller.start())                          // resume: immediate read
        #expect(await eventually { harness.reader.calls == 2 })
        await harness.runToEnd()
        #expect(harness.outcomes.value == [.budgetExhausted(lastStatus: .new)])
        #expect(harness.clock.now == .seconds(601 + 9))          // exactly the budget that was left
    }

    @Test("A late answer from a paused run is discarded")
    func staleAnswerAfterPause() async {
        let harness = PollerHarness()
        let gate = Gate()
        harness.reader.hold(with: gate)
        harness.reader.script(.status("transaction_paid"), .status("transaction_new"))
        harness.poller.start()
        #expect(await eventually { harness.reader.readsInFlight == 1 })

        harness.poller.pause()
        await gate.open()
        #expect(await eventually { harness.reader.readsInFlight == 0 })
        try? await Task.sleep(for: .milliseconds(20))

        #expect(harness.outcomes.value.isEmpty)                  // "paid" belonged to the abandoned run
        #expect(harness.poller.phase == .paused)
        #expect(harness.poller.lastStatus == nil)
    }

    @Test("A resumed run waits for the abandoned request: never two reads in flight")
    func noOverlap() async {
        let harness = PollerHarness()
        let gate = Gate()
        harness.reader.hold(with: gate)
        harness.reader.script(.status("transaction_new"))
        harness.poller.start()
        #expect(await eventually { harness.reader.readsInFlight == 1 })

        harness.poller.pause()
        harness.poller.start()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(harness.reader.calls == 1)

        await gate.open()
        #expect(await eventually { harness.reader.calls == 2 })
        #expect(harness.reader.maximumConcurrentReads == 1)
        harness.poller.stop()
    }

    @Test("Start while running is ignored: one poller, one loop")
    func singleRun() async {
        let harness = PollerHarness()
        harness.reader.script(.status("transaction_new"))
        #expect(harness.poller.start())
        #expect(harness.poller.start() == false)
        #expect(await harness.settle())
        #expect(harness.reader.calls == 1)
        #expect(harness.clock.pendingSleeps == 1)
        harness.poller.stop()
    }

    @Test("Stop reports nothing and cannot be undone")
    func stop() async {
        let harness = PollerHarness()
        harness.reader.script(.status("transaction_new"), .status("transaction_paid"))
        harness.poller.start()
        #expect(await harness.settle())

        harness.poller.stop()
        harness.clock.advance(by: .seconds(60))
        #expect(harness.poller.start() == false)
        #expect(await harness.poller.checkNow() == false)
        #expect(harness.outcomes.value.isEmpty)
        #expect(harness.reader.calls == 1)
    }

    @Test("The outcome is reported once")
    func outcomeOnce() async {
        let harness = PollerHarness()
        harness.reader.script(.status("transaction_paid"))
        harness.poller.start()
        await harness.runToEnd()
        harness.poller.stop()
        #expect(harness.poller.start() == false)
        #expect(harness.outcomes.value.count == 1)
    }

    // MARK: Read now

    @Test("Concurrent read requests share one request")
    func concurrentCheckNow() async {
        let harness = PollerHarness()
        harness.reader.script(.status("transaction_new"))
        harness.poller.start()
        #expect(await harness.settle())

        let poller = harness.poller
        async let first = poller.checkNow()
        async let second = poller.checkNow()
        async let third = poller.checkNow()
        let answers = await [first, second, third]

        #expect(answers == [true, true, true])
        #expect(harness.reader.calls == 2)
        poller.stop()
    }

    @Test("A wake during the interval reads at once")
    func wake() async {
        let harness = PollerHarness()
        harness.reader.script(.status("transaction_new"))
        harness.poller.start()
        #expect(await harness.settle())

        harness.poller.wake()
        #expect(await eventually { harness.reader.calls == 2 })
        #expect(harness.clock.now == .zero)
        harness.poller.stop()
    }

    @Test("A failed read is reported to the waiting caller")
    func checkNowFailure() async {
        let harness = PollerHarness()
        harness.reader.script(.failure(Polling.serverError))
        #expect(await harness.poller.checkNow() == false)        // starts the poller too
        #expect(harness.poller.phase == .running)
        harness.poller.stop()
    }
}
