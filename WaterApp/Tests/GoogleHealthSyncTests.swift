import Foundation
import XCTest

@MainActor
final class GoogleHealthSyncTests: XCTestCase {
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
