import Foundation
import Combine

@MainActor
final class HeartbeatSettings: ObservableObject {
  static let shared = HeartbeatSettings()

  private enum Keys {
    static let enabled = "tomHeartbeatEnabled"
    static let intervalMinutes = "tomHeartbeatIntervalMinutes"
    static let allowMemoryWrites = "tomHeartbeatAllowMemoryWrites"
    static let memoryDirectory = "tomHeartbeatMemoryDirectory"
  }

  static let allowedIntervalsMinutes = [5, 15, 30, 60, 120, 240]
  static let defaultMemoryDirectory = "\(NSHomeDirectory())/Documents/Omi/TomMemory"

  @Published var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
  }

  @Published var intervalMinutes: Int {
    didSet {
      let normalized = Self.allowedIntervalsMinutes.contains(intervalMinutes) ? intervalMinutes : 30
      if normalized != intervalMinutes {
        intervalMinutes = normalized
        return
      }
      UserDefaults.standard.set(intervalMinutes, forKey: Keys.intervalMinutes)
    }
  }

  @Published var allowMemoryWrites: Bool {
    didSet { UserDefaults.standard.set(allowMemoryWrites, forKey: Keys.allowMemoryWrites) }
  }

  @Published var memoryDirectory: String {
    didSet {
      let trimmed = memoryDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed != memoryDirectory {
        memoryDirectory = trimmed.isEmpty ? Self.defaultMemoryDirectory : trimmed
        return
      }
      UserDefaults.standard.set(memoryDirectory, forKey: Keys.memoryDirectory)
    }
  }

  var intervalSeconds: TimeInterval {
    TimeInterval(max(1, intervalMinutes) * 60)
  }

  var heartbeatFilePath: String {
    URL(fileURLWithPath: memoryDirectory).appendingPathComponent("HEARTBEAT.md").path
  }

  var runLogFilePath: String {
    URL(fileURLWithPath: memoryDirectory).appendingPathComponent("HEARTBEAT_LOG.md").path
  }

  private init() {
    isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? false
    let storedInterval = UserDefaults.standard.integer(forKey: Keys.intervalMinutes)
    intervalMinutes = Self.allowedIntervalsMinutes.contains(storedInterval) ? storedInterval : 30
    allowMemoryWrites = UserDefaults.standard.object(forKey: Keys.allowMemoryWrites) as? Bool ?? true
    let storedMemoryDirectory = UserDefaults.standard.string(forKey: Keys.memoryDirectory)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    memoryDirectory = storedMemoryDirectory?.isEmpty == false
      ? storedMemoryDirectory!
      : Self.defaultMemoryDirectory
  }
}
