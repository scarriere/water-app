import Foundation
import XCTest

@MainActor
final class GoogleHealthSyncTests: XCTestCase {
    func testOAuthRequiresHealthWriteScopeWhenGoogleReturnsGrantedScopes() {
        XCTAssertFalse(GoogleHealthAuth.scopeWasGranted("email https://www.googleapis.com/auth/userinfo.email openid"))
        XCTAssertTrue(GoogleHealthAuth.scopeWasGranted("openid email \(GoogleHealthAuth.healthScope)"))
        XCTAssertTrue(GoogleHealthAuth.scopeWasGranted(nil))
        XCTAssertTrue(GoogleHealthAuth.scopeIsPresent(GoogleHealthAuth.readScope,
            in: "openid \(GoogleHealthAuth.readScope) \(GoogleHealthAuth.healthScope)"))
        XCTAssertFalse(GoogleHealthAuth.scopeIsPresent(GoogleHealthAuth.readScope,
            in: "openid \(GoogleHealthAuth.healthScope)"))
    }

    func testOldCredentialsWithoutReadScopeStillDecode() throws {
        let json = Data(#"{"accessToken":"test","refreshToken":"test","expiresAt":0,"subject":"test","email":"test@example.com"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(GoogleHealthAuth.Credentials.self, from: json).scopes)
    }

    func testTokenFormIncludesClientSecretAndEncodesSpecialCharacters() throws {
        let form = GoogleHealthAuth.tokenForm(
            ["grant_type": "authorization_code", "code": "4/test+code", "code_verifier": "unit"],
            clientSecret: "fake+secret")
        XCTAssertEqual(form["client_secret"], "fake+secret")
        let body = try XCTUnwrap(GoogleHealthAuth.formEncodedBody(form))
        let encoded = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(encoded.contains("client_secret=fake%2Bsecret"))
        XCTAssertTrue(encoded.contains("code=4%2Ftest%2Bcode"))
        XCTAssertTrue(encoded.contains("code_verifier=unit"))
        let refresh = GoogleHealthAuth.tokenForm(["grant_type": "refresh_token"], clientSecret: "fake+secret")
        XCTAssertEqual(refresh["client_secret"], form["client_secret"])
    }

    func testTokenErrorDetailsNeverExposeCodesOrTokens() {
        XCTAssertEqual(GoogleHealthAuth.safeGoogleErrorDetail("Missing required parameter: client_secret."),
                       "Missing required parameter: client_secret.")
        XCTAssertNil(GoogleHealthAuth.safeGoogleErrorDetail("Bad code=4/0AXlqoi7LongValue"))
        XCTAssertNil(GoogleHealthAuth.safeGoogleErrorDetail("See https://accounts.google.com/error"))
        XCTAssertNil(GoogleHealthAuth.safeGoogleErrorDetail(String(repeating: "a", count: 32)))
    }

    func testOAuthLoopbackAcceptsOneCallbackAndRejectsOtherPaths() async throws {
        let server = try LoopbackCallback()
        defer { server.cancel() }
        let invalid = URL(string: "http://127.0.0.1:\(server.port)/not-a-callback")!
        let (_, rejected) = try await URLSession.shared.data(from: invalid)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 404)

        let waiting = Task { try await server.waitForCallback() }
        let callback = URL(string: "http://127.0.0.1:\(server.port)/callback?state=unit-state&code=unit-code")!
        let (_, accepted) = try await URLSession.shared.data(from: callback)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let params = try await waiting.value
        XCTAssertEqual(params["state"], "unit-state")
        XCTAssertEqual(params["code"], "unit-code")
    }

    func testGoogleListShowsOnlyMatchedWaterRecordsAndFlagsUnverifiedMatches() throws {
        func point(_ id: String, at: String, ml: Any) -> [String: Any] {
            ["name": "users/me/dataTypes/hydration-log/dataPoints/\(id)",
             "hydrationLog": ["interval": ["startTime": at],
                              "amountConsumed": ["milliliters": ml]]]
        }
        let first = "2026-10-01T12:00:00Z"
        let second = "2026-10-01T13:00:00.000Z"
        let page = try GoogleHealthRemote.page([
            "dataPoints": [point("known-id", at: first, ml: 355),
                           point("possible-id", at: second, ml: "355"),
                           point("other-app-id", at: "2026-10-01T15:00:00Z", ml: 200)],
            "nextPageToken": "next"])
        XCTAssertEqual(page.records.count, 3)
        XCTAssertEqual(page.nextPageToken, "next")
        var confirmed = GoogleHealthSync.Entry(at: first, ml: 355)
        confirmed.remoteName = "users/12345/dataTypes/hydration-log/dataPoints/known-id"
        var uncertain = GoogleHealthSync.Entry(at: "2026-10-01T13:00:00Z", ml: 355)
        uncertain.uncertain = true
        let matches = GoogleHealthRemote.matchingWaterDrinks(page.records, entries: [confirmed, uncertain])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].id, "users/me/dataTypes/hydration-log/dataPoints/possible-id")
        XCTAssertEqual(matches[0].confidence, .possible)
        XCTAssertEqual(matches[1].confidence, .confirmed)
    }

    func testUnparseableGoogleListIsNotReportedAsEmpty() {
        XCTAssertThrowsError(try GoogleHealthRemote.page(["dataPoints": [["name": "unexpected"]]]))
    }

    func testHydrationPayloadUsesActualVolumeAndOneSecondUTCInterval() throws {
        let entry = GoogleHealthSync.Entry(at: "2026-10-01T12:00:00Z", ml: 355)
        let payload = try GoogleHealthSync.hydrationPayload(for: entry)
        let log = try XCTUnwrap(payload["hydrationLog"] as? [String: Any])
        let interval = try XCTUnwrap(log["interval"] as? [String: String])
        let volume = try XCTUnwrap(log["amountConsumed"] as? [String: Int])
        XCTAssertEqual(interval["startTime"], "2026-10-01T12:00:00Z")
        XCTAssertEqual(interval["endTime"], "2026-10-01T12:00:01Z")
        XCTAssertEqual(volume["milliliters"], 355)
    }

    func testOperationRequiresServerAssignedDataPointName() {
        let name = "users/me/dataTypes/hydration-log/dataPoints/server-1234"
        let operation: [String: Any] = ["response": ["dataPoint": ["name": name]]]
        XCTAssertEqual(GoogleHealthSync.dataPointName(in: operation), name)
        XCTAssertNil(GoogleHealthSync.dataPointName(in: ["name": "users/me/operations/1234"]))
    }

    func testDefiniteHTTPRejectionsAreSeparatedFromAmbiguousResults() throws {
        XCTAssertTrue(GoogleHealthSync.isDefinitiveRejection(400))
        XCTAssertTrue(GoogleHealthSync.isDefinitiveRejection(401))
        XCTAssertTrue(GoogleHealthSync.isDefinitiveRejection(403))
        XCTAssertTrue(GoogleHealthSync.isDefinitiveRejection(404))
        XCTAssertTrue(GoogleHealthSync.isDefinitiveRejection(405))
        XCTAssertFalse(GoogleHealthSync.isDefinitiveRejection(408))
        XCTAssertFalse(GoogleHealthSync.isDefinitiveRejection(429))
        XCTAssertFalse(GoogleHealthSync.isDefinitiveRejection(500))
        var entry = GoogleHealthSync.Entry(at: "2026-10-01T12:00:00Z", ml: 355)
        entry.rejectedStatus = 403
        let decoded = try JSONDecoder().decode(GoogleHealthSync.Entry.self,
                                                from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.rejectedStatus, 403)
        XCTAssertFalse(decoded.uncertain)
        let old = Data(#"{"at":"2026-10-01T12:00:00Z","ml":355,"uncertain":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(GoogleHealthSync.Entry.self, from: old).rejectedStatus)
        XCTAssertNil(try JSONDecoder().decode(GoogleHealthSync.Entry.self, from: old).lastFailure)
    }

    func testReviewStatusShowsSafePersistedFailure() {
        var entry = GoogleHealthSync.Entry(at: "2026-10-01T12:00:00Z", ml: 355)
        entry.uncertain = true
        entry.lastFailure = "Google Health returned HTTP 429."
        XCTAssertTrue(GoogleHealthSync.reviewStatus(for: [entry]).contains("HTTP 429"))
        entry.lastFailure = nil
        XCTAssertTrue(GoogleHealthSync.reviewStatus(for: [entry]).contains("no error saved"))
    }

    func testLedgerPreservesPendingOperationsAndCutoff() throws {
        var ledger = GoogleHealthSync.Ledger(cutoff: Date(timeIntervalSince1970: 1_780_000_000))
        var entry = GoogleHealthSync.Entry(at: "2026-10-01T12:00:00Z", ml: 355)
        entry.operationName = "users/me/operations/1234"
        entry.operationType = "create"
        ledger.entries["drink-1"] = entry
        let restored = try JSONDecoder().decode(GoogleHealthSync.Ledger.self,
                                                 from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.cutoff, ledger.cutoff)
        XCTAssertEqual(restored.entries["drink-1"]?.operationName, entry.operationName)
        XCTAssertNil(restored.entries["drink-1"]?.remoteName)
    }
}
