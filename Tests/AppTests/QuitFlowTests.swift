import CoreServices
import XCTest
@testable import TaskTickApp

final class QuitFlowTests: XCTestCase {

    // MARK: - Session-end quit reasons

    /// Logout / restart / shutdown quit events must bypass the quit dialog —
    /// cancelling (or blocking on a modal) aborts the user's whole logout.
    func testSessionEndReasonsRecognized() {
        let reasons = [
            kAELogOut, kAEReallyLogOut,
            kAEShowRestartDialog, kAERestart,
            kAEShowShutdownDialog, kAEShutDown,
        ]
        for reason in reasons {
            XCTAssertTrue(
                AppDelegate.isSessionEndQuitReason(OSType(reason)),
                "reason \(reason) should be treated as session end"
            )
        }
    }

    /// A plain user quit carries no session-end reason — it must fall through
    /// to the confirmation dialog path.
    func testNonSessionEndReasonsRejected() {
        XCTAssertFalse(AppDelegate.isSessionEndQuitReason(0))
        XCTAssertFalse(AppDelegate.isSessionEndQuitReason(OSType(kAEQuitApplication)))
    }

}
