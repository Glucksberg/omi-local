import Foundation
import GRDB

struct GoalRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?

    // Backend sync
    var backendId: String?
    var backendSynced: Bool

    // Core Goal fields (mirrors APIClient.Goal)
    var title: String
    var goalDescription: String?   // "description" is reserved in some contexts
    var goalType: String           // "boolean", "scale", "numeric"
    var targetValue: Double
    var currentValue: Double
    var minValue: Double
    var maxValue: Double
    var unit: String?
    var isActive: Bool
    var completedAt: Date?

    // Status
    var deleted: Bool

    // Timestamps
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "goals"

    // MARK: - Persistence Callbacks

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Server Conversion

extension GoalRecord {
    /// Create local record from API Goal
    static func from(_ goal: Goal) -> GoalRecord {
        GoalRecord(
            backendId: goal.id,
            backendSynced: true,
            title: goal.title,
            goalDescription: goal.description,
            goalType: goal.goalType.rawValue,
            targetValue: goal.targetValue,
            currentValue: goal.currentValue,
            minValue: goal.minValue,
            maxValue: goal.maxValue,
            unit: goal.unit,
            isActive: goal.isActive,
            completedAt: goal.completedAt,
            deleted: false,
            createdAt: goal.createdAt,
            updatedAt: goal.updatedAt
        )
    }

    /// Update existing record from API Goal (preserves local ID)
    mutating func updateFrom(_ goal: Goal) {
        backendId = goal.id
        backendSynced = true
        title = goal.title
        goalDescription = goal.description
        goalType = goal.goalType.rawValue
        targetValue = goal.targetValue
        currentValue = goal.currentValue
        minValue = goal.minValue
        maxValue = goal.maxValue
        unit = goal.unit
        isActive = goal.isActive
        completedAt = goal.completedAt
        updatedAt = goal.updatedAt
    }

    /// Convert back to API Goal for UI display
    func toGoal() -> Goal? {
        let goalId = backendId ?? "local_\(id ?? 0)"
        let type = GoalType(rawValue: goalType) ?? .boolean

        return Goal(
            id: goalId,
            title: title,
            description: goalDescription,
            goalType: type,
            targetValue: targetValue,
            currentValue: currentValue,
            minValue: minValue,
            maxValue: maxValue,
            unit: unit,
            isActive: isActive,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt
        )
    }
}

// MARK: - TableDocumented

extension GoalRecord: TableDocumented {
    static var tableDescription: String { ChatPrompts.tableAnnotations["goals"]! }
    static var columnDescriptions: [String: String] { ChatPrompts.columnAnnotations["goals"] ?? [:] }
}
