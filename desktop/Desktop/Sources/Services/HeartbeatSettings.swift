import Foundation
import Combine

@MainActor
final class HeartbeatSettings: ObservableObject {
  static let shared = HeartbeatSettings()

  private enum Keys {
    static let enabled = "tomHeartbeatEnabled"
    static let intervalMinutes = "tomHeartbeatIntervalMinutes"
  }

  static let allowedIntervalsMinutes = [5, 15, 30, 60, 120, 240]

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

  var intervalSeconds: TimeInterval {
    TimeInterval(max(1, intervalMinutes) * 60)
  }

  private init() {
    isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? false
    let storedInterval = UserDefaults.standard.integer(forKey: Keys.intervalMinutes)
    intervalMinutes = Self.allowedIntervalsMinutes.contains(storedInterval) ? storedInterval : 30
  }
}
