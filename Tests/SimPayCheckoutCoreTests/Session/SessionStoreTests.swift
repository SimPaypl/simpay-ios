import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("SessionStore")
struct SessionStoreTests {

    private func store(_ provider: ScriptedProvider, clock: ManualClock = ManualClock()) -> SessionStore {
        SessionStore(provider: provider, clock: clock.sessionClock)
    }

    // MARK: Basic lifecycle

    @Test("The first call fetches a session")
    func firstFetch() async throws {
        let provider = ScriptedProvider()
        let lease = try await store(provider).validSession()

        #expect(provider.calls == 1)
        #expect(lease.session.token == ScriptedProvider.token(1))
        #expect(lease.generation == 1)
    }

    @Test("A valid session is reused")
    func reuse() async throws {
        let provider = ScriptedProvider()
        let store = store(provider)

        let first = try await store.validSession()
        let second = try await store.validSession()

        #expect(provider.calls == 1)
        #expect(first.generation == second.generation)
    }

    @Test("Without expiresAt the session is kept until a 401")
    func noExpiry() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(clock: clock, lifetime: nil)
        let store = store(provider, clock: clock)

        _ = try await store.validSession()
        clock.advance(by: .seconds(10 * 3600))
        _ = try await store.validSession()

        #expect(provider.calls == 1)
    }

    @Test("A session is replaced 60 seconds before it expires")
    func proactiveRefresh() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(clock: clock, lifetime: 15 * 60)
        let store = store(provider, clock: clock)

        _ = try await store.validSession()
        clock.advance(by: .seconds(13 * 60 + 59))       // 61 s left: still fresh
        #expect(try await store.validSession().generation == 1)

        clock.advance(by: .seconds(1))                  // 60 s left: replaced
        let refreshed = try await store.validSession()
        #expect(refreshed.generation == 2)
        #expect(refreshed.session.token == ScriptedProvider.token(2))
        #expect(provider.calls == 2)
    }

    @Test("An expired session is replaced")
    func expiredSession() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(clock: clock, lifetime: 15 * 60)
        let store = store(provider, clock: clock)

        _ = try await store.validSession()
        clock.advance(by: .seconds(3600))

        #expect(try await store.validSession().generation == 2)
    }

    @Test("A session already expired on the device clock is still reused briefly, never refetched on every call")
    func skewedExpiry() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(clock: clock, lifetime: -300)
        let store = store(provider, clock: clock)

        _ = try await store.validSession()
        _ = try await store.validSession()
        _ = try await store.validSession()
        #expect(provider.calls == 1)

        clock.advance(by: SessionStore.minimumReuse)
        _ = try await store.validSession()
        #expect(provider.calls == 2)
    }

    @Test("Changing the system clock does not change the lifetime of a held session")
    func systemClockChange() async throws {
        let clock = ManualClock()
        let provider = ScriptedProvider(clock: clock, lifetime: 15 * 60)
        let store = store(provider, clock: clock)
        _ = try await store.validSession()

        clock.setWallClock(clock.now.addingTimeInterval(2 * 3600))   // jump forward
        #expect(try await store.validSession().generation == 1)
        clock.setWallClock(clock.now.addingTimeInterval(-4 * 3600))  // jump backward
        #expect(try await store.validSession().generation == 1)

        clock.advance(by: .seconds(14 * 60))                         // real time passes
        #expect(try await store.validSession().generation == 2)
    }

    // MARK: Failures

    @Test("A provider failure becomes session_failed without leaking the error text, and is not cached")
    func providerFailure() async throws {
        let provider = ScriptedProvider()
        provider.fail(call: 1, with: ProviderBoom())
        let store = store(provider)

        do {
            _ = try await store.validSession()
            Issue.record("expected a failure")
        } catch let error as SimPayCheckoutError {
            #expect(error.code == .sessionFailed)
            #expect(!everyTextualForm(of: error).contains(Sample.token))
            #expect(!everyTextualForm(of: error).contains("backend said"))
        }

        #expect(try await store.validSession().session.token == ScriptedProvider.token(2))
        #expect(provider.calls == 2)
    }

    @Test("A SimPayCheckoutError thrown by the provider keeps its code")
    func providerTypedError() async {
        let provider = ScriptedProvider()
        provider.fail(call: 1, with: SimPayCheckoutError(.noInternet))

        await #expect(throws: SimPayCheckoutError(.noInternet)) { try await store(provider).validSession() }
    }

    @Test("A task cancelled before asking never calls the provider")
    func cancelledBeforeAsking() async {
        let provider = ScriptedProvider()
        let store = store(provider)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.validSession()
        }
        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(provider.calls == 0)
    }

    // MARK: Single flight

    @Test("Concurrent callers share one provider call and one session")
    func singleFlight() async throws {
        let gate = Gate()
        let provider = ScriptedProvider(gate: gate)
        let store = store(provider)

        let tasks = (0..<8).map { _ in Task { try await store.validSession() } }
        #expect(await eventually { await store.waitingCallers == 8 })
        #expect(provider.calls == 1)

        await gate.open()
        let leases = try await tasks.asyncMap { try await $0.value }

        #expect(provider.calls == 1)
        #expect(Set(leases.map(\.generation)) == [1])
        #expect(Set(leases.map(\.session.token)) == [ScriptedProvider.token(1)])
    }

    @Test("A provider failure is delivered to every waiting caller")
    func singleFlightFailure() async {
        let gate = Gate()
        let provider = ScriptedProvider(gate: gate)
        provider.fail(call: 1, with: ProviderBoom())
        let store = store(provider)

        let tasks = (0..<3).map { _ in Task { try await store.validSession() } }
        #expect(await eventually { await store.waitingCallers == 3 })
        await gate.open()

        for task in tasks {
            let result = await task.result
            #expect(throws: SimPayCheckoutError.self) { try result.get() }
        }
        #expect(provider.calls == 1)
    }

    @Test("Cancelling one waiting caller does not affect the others or the fetch")
    func cancelOneWaiter() async throws {
        let gate = Gate()
        let provider = ScriptedProvider(gate: gate)
        let store = store(provider)

        let kept1 = Task { try await store.validSession() }
        let cancelled = Task { try await store.validSession() }
        let kept2 = Task { try await store.validSession() }
        #expect(await eventually { await store.waitingCallers == 3 })

        cancelled.cancel()
        let cancelledResult = await cancelled.result
        #expect(throws: CancellationError.self) { try cancelledResult.get() }
        #expect(await store.waitingCallers == 2)

        await gate.open()
        #expect(try await kept1.value.generation == 1)
        #expect(try await kept2.value.generation == 1)
        #expect(provider.calls == 1)
        #expect(await store.hasSession)
    }

    // MARK: Replacement after 401

    @Test("A 401 replaces the session; a late 401 for an old session reuses the newer one")
    func staleUnauthorized() async throws {
        let provider = ScriptedProvider()
        let store = store(provider)

        let first = try await store.validSession()
        let second = try await store.sessionReplacing(first)
        #expect(second.generation == 2)

        // A request made with the first session fails later: no new fetch, no loss.
        let again = try await store.sessionReplacing(first)
        #expect(again.generation == 2)
        await store.invalidate(first)
        #expect(await store.hasSession)
        #expect(try await store.validSession().generation == 2)
        #expect(provider.calls == 2)
    }

    @Test("Concurrent 401s for the same session cause a single refresh")
    func concurrentUnauthorized() async throws {
        let gate = Gate()
        let base = ScriptedProvider()
        let store = SessionStore(provider: GatedAfterFirst(base: base, gate: gate), clock: ManualClock().sessionClock)

        let rejected = try await store.validSession()
        let tasks = (0..<5).map { _ in Task { try await store.sessionReplacing(rejected) } }
        #expect(await eventually { await store.waitingCallers == 5 })
        await gate.open()

        let leases = try await tasks.asyncMap { try await $0.value }
        #expect(Set(leases.map(\.generation)) == [2])
        #expect(base.calls == 2)
    }

    @Test("Invalidating while a refresh is running keeps the newer session")
    func invalidateDuringRefresh() async throws {
        let gate = Gate()
        let base = ScriptedProvider()
        let store = SessionStore(provider: GatedAfterFirst(base: base, gate: gate), clock: ManualClock().sessionClock)

        let first = try await store.validSession()
        let refreshing = Task { try await store.sessionReplacing(first) }
        #expect(await eventually { await store.waitingCallers == 1 })

        await store.invalidate(first)        // concurrent invalidation of the old session
        await gate.open()

        #expect(try await refreshing.value.generation == 2)
        #expect(await store.hasSession)
        #expect(try await store.validSession().generation == 2)
    }

    @Test("Clearing while a refresh is running answers the waiter but keeps nothing")
    func clearDuringRefresh() async throws {
        let gate = Gate()
        let store = SessionStore(provider: ScriptedProvider(gate: gate), clock: ManualClock().sessionClock)

        let task = Task { try await store.validSession() }
        #expect(await eventually { await store.waitingCallers == 1 })
        await store.clear()
        await gate.open()

        #expect(try await task.value.generation == 1)
        #expect(await store.hasSession == false)
    }
}

/// Passes the first call straight through and gates every later one.
private final class GatedAfterFirst: SimPaySessionProvider, @unchecked Sendable {
    private let base: ScriptedProvider
    private let gate: Gate
    init(base: ScriptedProvider, gate: Gate) { self.base = base; self.gate = gate }

    func provideSession() async throws -> SimPaySession {
        if base.calls >= 1 { await gate.wait() }
        return try await base.provideSession()
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
