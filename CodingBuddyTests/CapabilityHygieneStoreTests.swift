//
//  CapabilityHygieneStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Deterministic continuation gate for out-of-order capability scan completion.
private actor CapabilityScanGate {
    /// Suspended requests keyed by invocation order.
    private var continuations: [Int: CheckedContinuation<CapabilityScanResult, Never>] = [:]
    /// Number assigned to the next request.
    private var requestCount = 0

    /// Suspends until the test publishes an immutable scanner result.
    func scan() async -> CapabilityScanResult {
        let request = requestCount
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }

    /// Waits until an expected number of requests reached the asynchronous boundary.
    func waitForRequestCount(_ expected: Int) async {
        for _ in 0..<5_000 {
            if requestCount >= expected { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected capability scan request did not reach the gate")
    }

    /// Completes one selected generation, even if its parent task was cancelled.
    func resume(request: Int, with result: CapabilityScanResult) {
        continuations.removeValue(forKey: request)?.resume(returning: result)
    }
}

/// State-transition coverage for the asynchronous, read-only capability store.
@MainActor
@Suite(.serialized)
struct CapabilityHygieneStoreTests {
    /// Creates a value-free scanner result with one complete occurrence.
    private func result(identity: String, sourcePath: String) -> CapabilityScanResult {
        let item = CapabilityInventoryItem(
            kind: .skill,
            consumer: .codex,
            runtimeIdentity: identity,
            sourcePath: sourcePath,
            effectiveScope: "user",
            registrationState: .installed,
            activationState: .enabled,
            sourceStatus: .complete,
            canonicalFingerprint: CapabilityFingerprint.publicContent(
                schemaVersion: "test-public-v1",
                data: Data(identity.utf8)
            )
        )
        return CapabilityScanResult(
            items: [item],
            sources: [.init(sourcePath: sourcePath, kind: .skill, status: .complete)],
            notices: [],
            precedenceEvidence: []
        )
    }

    /// Waits for one store phase without coupling the test to scheduler timing.
    private func waitForPhase(
        _ expected: CapabilityHygienePhase,
        in store: CapabilityHygieneStore
    ) async {
        for _ in 0..<5_000 {
            if store.phase == expected { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected capability hygiene phase was not published")
    }

    /// Verifies refresh preserves trusted data and stale generations cannot publish.
    @Test func refreshRetainsSnapshotAndRejectsOutOfOrderCompletion() async {
        let gate = CapabilityScanGate()
        let store = CapabilityHygieneStore(scan: { await gate.scan() })
        let initial = result(identity: "initial", sourcePath: "/initial/SKILL.md")
        let stale = result(identity: "stale", sourcePath: "/stale/SKILL.md")
        let newest = result(identity: "newest", sourcePath: "/newest/SKILL.md")

        store.reload()
        await gate.waitForRequestCount(1)
        await gate.resume(request: 0, with: initial)
        await waitForPhase(.loaded, in: store)
        #expect(store.snapshot == initial)

        store.reload()
        await gate.waitForRequestCount(2)
        #expect(store.phase == .scanning)
        #expect(store.snapshot == initial)

        store.reload()
        await gate.waitForRequestCount(3)
        await gate.resume(request: 2, with: newest)
        await waitForPhase(.loaded, in: store)
        #expect(store.snapshot == newest)

        await gate.resume(request: 1, with: stale)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(store.phase == .loaded)
        #expect(store.snapshot == newest)
    }
}
