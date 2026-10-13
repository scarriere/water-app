import Combine
import Foundation

@MainActor
final class WaterStore: ObservableObject {
    @Published private(set) var totalML = 0
    @Published private(set) var dayKey = ""
    @Published var errorMessage: String?

    private let repository: WaterRepository

    init(repository: WaterRepository = WaterRepository()) {
        self.repository = repository
        refresh()
    }

    func refresh() {
        let now = Date()
        do {
            let total = try repository.load(on: now)
            totalML = total
            dayKey = repository.dayKey(for: now)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Returns the persisted total, or nil if saving failed. Never animates an unsaved drink.
    @discardableResult
    func addGlass() -> Int? {
        let now = Date()
        do {
            let total = try repository.addGlass(on: now)
            totalML = total
            dayKey = repository.dayKey(for: now)
            errorMessage = nil
            return total
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Returns nil without altering the daily file when no 355 ml glass remains.
    @discardableResult
    func removeGlass() -> Int? {
        let now = Date()
        do {
            guard let total = try repository.removeGlass(on: now) else {
                errorMessage = "No 355 ml glass to remove today."
                return nil
            }
            totalML = total
            dayKey = repository.dayKey(for: now)
            errorMessage = nil
            return total
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
