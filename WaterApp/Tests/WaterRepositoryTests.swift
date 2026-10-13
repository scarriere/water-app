import Foundation
import XCTest

final class WaterRepositoryTests: XCTestCase {
    private var directory: URL!
    private var repository: WaterRepository!
    private let today = Date(timeIntervalSince1970: 1_766_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        repository = WaterRepository(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddGlassCreatesDatedJSONAndAccumulates() throws {
        XCTAssertEqual(try repository.load(on: today), 0)
        XCTAssertEqual(try repository.addGlass(on: today), 355)
        XCTAssertEqual(try repository.addGlass(on: today), 710)
        let data = try Data(contentsOf: repository.fileURL(for: today))
        let record = try JSONDecoder().decode(WaterRepository.DayRecord.self, from: data)
        XCTAssertEqual(record.date, repository.dayKey(for: today))
        XCTAssertEqual(record.ml, 710)
        XCTAssertEqual(record.drinks.count, 2)
        XCTAssertEqual(record.drinks.map(\.ml), [355, 355])
    }

    func testEachDayGetsItsOwnFile() throws {
        let tomorrow = today.addingTimeInterval(86_400)
        try repository.addGlass(on: today)
        XCTAssertEqual(try repository.load(on: tomorrow), 0)
        try repository.addGlass(on: tomorrow)
        XCTAssertEqual(try repository.load(on: today), 355)
        XCTAssertEqual(try repository.load(on: tomorrow), 355)
        XCTAssertNotEqual(repository.fileURL(for: today), repository.fileURL(for: tomorrow))
    }

    func testReadsCLIFileBeforeAdding() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = repository.fileURL(for: today)
        try Data("{\"date\":\"\(repository.dayKey(for: today))\",\"ml\":1065}".utf8)
            .write(to: file)
        XCTAssertEqual(try repository.addGlass(on: today), 1420)
        XCTAssertEqual(try repository.loadRecord(on: today).drinks.count, 1)
    }

    func testRemoveGlassUpdatesTotalAndReminderHistory() throws {
        XCTAssertNil(try repository.removeGlass(on: today))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.fileURL(for: today).path))
        try repository.addGlass(on: today)
        try repository.addGlass(on: today)
        XCTAssertEqual(try repository.removeGlass(on: today), 355)
        XCTAssertEqual(try repository.loadRecord(on: today).drinks.count, 1)
        XCTAssertFalse(try repository.needsReminder(at: today.addingTimeInterval(1_800)))
        XCTAssertEqual(try repository.removeGlass(on: today), 0)
        XCTAssertEqual(try repository.loadRecord(on: today).drinks, [])
        XCTAssertTrue(try repository.needsReminder(at: today.addingTimeInterval(1_800)))
        XCTAssertNil(try repository.removeGlass(on: today))
    }

    func testRemoveGlassPreservesOtherDrinksAndLegacyWater() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let at = ISO8601DateFormatter().string(from: today)
        let drinks: [WaterRepository.Drink] = [
            .init(at: at, ml: 355), .init(at: at, ml: 200), .init(at: at, ml: 355)
        ]
        let record = WaterRepository.DayRecord(date: repository.dayKey(for: today),
                                               ml: 1_265, drinks: drinks)
        try JSONEncoder().encode(record).write(to: repository.fileURL(for: today))
        XCTAssertEqual(try repository.removeGlass(on: today), 910)
        XCTAssertEqual(try repository.loadRecord(on: today).drinks, Array(drinks.prefix(2)))
        XCTAssertEqual(try repository.removeGlass(on: today), 555)
        XCTAssertEqual(try repository.loadRecord(on: today).drinks, [drinks[1]])
        XCTAssertEqual(try repository.removeGlass(on: today), 200) // Untimed legacy 355 ml.
        let unchanged = try Data(contentsOf: repository.fileURL(for: today))
        XCTAssertNil(try repository.removeGlass(on: today))
        XCTAssertEqual(try Data(contentsOf: repository.fileURL(for: today)), unchanged)
    }

    func testReminderChecksThePreviousHourAt250MLThreshold() throws {
        let checkedAt = today.addingTimeInterval(1_800)
        XCTAssertTrue(try repository.needsReminder(at: checkedAt))
        try repository.addGlass(on: today)
        XCTAssertFalse(try repository.needsReminder(at: checkedAt))
        XCTAssertTrue(try repository.needsReminder(at: today.addingTimeInterval(3_601)))
    }

    func testExactly250MLDoesNotRemindBut249MLDoes() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let at = ISO8601DateFormatter().string(from: today)
        let file = repository.fileURL(for: today)
        let key = repository.dayKey(for: today)
        let less = WaterRepository.DayRecord(date: key, ml: 249,
                                              drinks: [.init(at: at, ml: 249)])
        try JSONEncoder().encode(less).write(to: file)
        XCTAssertTrue(try repository.needsReminder(at: today.addingTimeInterval(1_800)))

        let enough = WaterRepository.DayRecord(date: key, ml: 250,
                                                drinks: [.init(at: at, ml: 250)])
        try JSONEncoder().encode(enough).write(to: file)
        XCTAssertFalse(try repository.needsReminder(at: today.addingTimeInterval(1_800)))
    }

    func testReminderIncludesDrinksAcrossMidnight() throws {
        let midnight = Calendar.current.startOfDay(for: today.addingTimeInterval(86_400))
        let before = midnight.addingTimeInterval(-1_200)
        let after = midnight.addingTimeInterval(600)
        try repository.addGlass(on: before)
        XCTAssertFalse(try repository.needsReminder(at: midnight.addingTimeInterval(600)))
        try repository.addGlass(on: after)
        XCTAssertEqual(try repository.consumed(from: midnight.addingTimeInterval(-1_800),
                                               to: midnight.addingTimeInterval(1_800)), 710)
    }

    func testIDsSurviveReloadAndLegacyMigrationOnlyWhenEligible() throws {
        let older = today.addingTimeInterval(-600)
        let recent = today.addingTimeInterval(600)
        let legacy = WaterRepository.DayRecord(date: repository.dayKey(for: today), ml: 710,
            drinks: [.init(at: ISO8601DateFormatter().string(from: older), ml: 355),
                     .init(at: ISO8601DateFormatter().string(from: recent), ml: 355)])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: repository.fileURL(for: today))
        try repository.assignDrinkIDs(since: today)
        let drinks = try repository.loadRecord(on: today).drinks
        XCTAssertNil(drinks[0].id)
        XCTAssertNotNil(drinks[1].id)
        XCTAssertEqual(try repository.exportableDrinks(since: today), [drinks[1]])
        try repository.assignDrinkIDs(since: today)
        XCTAssertEqual(try repository.loadRecord(on: today).drinks, drinks)
        try repository.addGlass(on: recent)
        XCTAssertEqual(try repository.loadRecord(on: today).drinks[1].id, drinks[1].id)
    }

    func testNewGlassesHaveDistinctIDs() throws {
        try repository.addGlass(on: today)
        try repository.addGlass(on: today)
        let drinks = try repository.loadRecord(on: today).drinks
        XCTAssertEqual(Set(drinks.compactMap(\.id)).count, 2)
    }

    func testInvalidJSONIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = repository.fileURL(for: today)
        let original = Data("{broken json".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try repository.addGlass(on: today))
        XCTAssertThrowsError(try repository.removeGlass(on: today))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
