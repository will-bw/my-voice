import XCTest
@testable import VoiceInk

final class ScreenCapturePermissionTests: XCTestCase {
    @MainActor
    func testSuccessfulScreenCaptureKitAccessIsAuthoritative() async {
        var calls = 0
        let available = await ScreenCapturePermissionProbe.isAvailable {
            calls += 1
        }
        XCTAssertTrue(available)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testActualScreenCaptureKitDenialIsNotReportedAsGranted() async {
        let available = await ScreenCapturePermissionProbe.isAvailable {
            throw NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        }
        XCTAssertFalse(available)
    }

    @MainActor
    func testPermissionCanRefreshAfterSystemSettingsChangesWithoutRestart() async {
        var denied = true
        let check: () async throws -> Void = {
            if denied { throw NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801) }
        }
        let before = await ScreenCapturePermissionProbe.isAvailable(check: check)
        denied = false
        let after = await ScreenCapturePermissionProbe.isAvailable(check: check)
        XCTAssertFalse(before)
        XCTAssertTrue(after)
    }
}
