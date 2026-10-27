import XCTest
import ApplicationServices
@testable import StripKit

/// Tests for the self-induced-activation suppression (perf 1.1): when Strip's own `apply()` moves
/// keyboard focus, the activation/focus notifications it generates must not trigger a redundant
/// reconcile — but a genuine third-party activation still must. The time source is injected so these
/// run headless, with no AX connection or real notifications.
final class WindowObserverTests: XCTestCase {
    func testStampedActivationIsSuppressedWithinGrace() {
        let obs = WindowObserver()
        obs.ignoreActivation(of: 42, now: 1000)
        // Same pid, just after the stamp and within the 0.2s grace → ours, ignore it.
        XCTAssertTrue(obs.isSelfInducedActivation(pid: 42, now: 1000.0))
        XCTAssertTrue(obs.isSelfInducedActivation(pid: 42, now: 1000.1))
    }

    func testActivationIsLiveAgainAfterGraceExpires() {
        let obs = WindowObserver()
        obs.ignoreActivation(of: 42, now: 1000)
        // Past the 0.2s grace → a real activation; must reconcile (re-center) again.
        XCTAssertFalse(obs.isSelfInducedActivation(pid: 42, now: 1000.2))
        XCTAssertFalse(obs.isSelfInducedActivation(pid: 42, now: 1000.5))
    }

    func testDifferentAppIsNeverSuppressed() {
        let obs = WindowObserver()
        obs.ignoreActivation(of: 42, now: 1000)
        // A genuine Cmd-Tab to another app (different pid) must always reconcile (Guardrail 01).
        XCTAssertFalse(obs.isSelfInducedActivation(pid: 99, now: 1000.05))
    }

    func testNothingSuppressedWithoutAStamp() {
        // Fresh observer: every activation is real until Strip says otherwise.
        XCTAssertFalse(WindowObserver().isSelfInducedActivation(pid: 42, now: 1000))
    }

    func testReStampingExtendsToTheNewActivation() {
        let obs = WindowObserver()
        obs.ignoreActivation(of: 42, now: 1000)
        obs.ignoreActivation(of: 7, now: 2000) // a later focus command activates a different app
        XCTAssertFalse(obs.isSelfInducedActivation(pid: 42, now: 2000.05)) // old pid no longer ours
        XCTAssertTrue(obs.isSelfInducedActivation(pid: 7, now: 2000.05))   // new pid is
    }

    // MARK: - Event classification (perf 1.1 second half)

    /// Only focused/main-window-changed are membership-preserving → lightweight; every other
    /// notification keeps the full re-enumeration path.
    func testReconcileKindRoutesPureFocusEventsLightweight() {
        XCTAssertEqual(WindowObserver.reconcileKind(for: kAXFocusedWindowChangedNotification), .lightweight)
        XCTAssertEqual(WindowObserver.reconcileKind(for: kAXMainWindowChangedNotification), .lightweight)
    }

    func testReconcileKindRoutesMembershipEventsFull() {
        for n in [kAXUIElementDestroyedNotification,
                  kAXWindowMiniaturizedNotification,
                  kAXWindowDeminiaturizedNotification,
                  kAXWindowCreatedNotification,
                  "SomeUnknownNotification"] {
            XCTAssertEqual(WindowObserver.reconcileKind(for: n), .full, "\(n) must stay on the full path")
        }
    }

    /// A window counts as watched only if its close notification registered — a failed add must stay
    /// unwatched so the next focus retries it (else its close never reconciles).
    func testOnlyARegisteredNotificationCountsAsWatched() {
        XCTAssertTrue(WindowObserver.isRegistered(.success))
        XCTAssertTrue(WindowObserver.isRegistered(.notificationAlreadyRegistered))
        for err: AXError in [.failure, .cannotComplete, .invalidUIElement, .notificationUnsupported,
                             .invalidUIElementObserver] {
            XCTAssertFalse(WindowObserver.isRegistered(err), "\(err.rawValue)")
        }
    }

    // MARK: - Debounce-batch decision (membership wins over focus)

    /// Any membership event in the debounce window forces a full reconcile, even if a pure focus event
    /// arrives afterward — so a Cmd-Tab landing last in a burst can't swallow a real window change.
    func testBatchActionMembershipWinsOverFocus() {
        XCTAssertEqual(WindowObserver.batchAction(sawMembership: true, focusPID: 42), .full)
        XCTAssertEqual(WindowObserver.batchAction(sawMembership: true, focusPID: nil), .full)
    }

    func testBatchActionPureFocusTakesLightweightPath() {
        XCTAssertEqual(WindowObserver.batchAction(sawMembership: false, focusPID: 42), .lightweight(42))
    }

    func testBatchActionEmptyWindowDoesNothing() {
        XCTAssertEqual(WindowObserver.batchAction(sawMembership: false, focusPID: nil), .none)
    }
}
