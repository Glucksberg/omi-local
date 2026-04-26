import Foundation

@MainActor
final class HeartbeatScheduler {
  static let shared = HeartbeatScheduler()

  private weak var chatProvider: ChatProvider?
  private var loopTask: Task<Void, Never>?
  private var runningTurn = false
  private var lastRunAt: Date?
  private var lastAlertHash: Int?
  private var lastAlertAt: Date?

  private init() {}

  func configure(chatProvider: ChatProvider) {
    self.chatProvider = chatProvider
    reconcile(reason: "configure")
  }

  func reconcile(reason: String) {
    if HeartbeatSettings.shared.isEnabled {
      start(reason: reason)
    } else {
      stop(reason: reason)
    }
  }

  func start(reason: String) {
    guard loopTask == nil else { return }
    log("HeartbeatScheduler: starting (reason=\(reason), interval=\(HeartbeatSettings.shared.intervalMinutes)m)")
    loopTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.runIfDue(reason: "loop")
        let sleepSeconds = min(max(30, HeartbeatSettings.shared.intervalSeconds / 4), 300)
        try? await Task.sleep(for: .seconds(sleepSeconds))
      }
    }
  }

  func stop(reason: String) {
    guard loopTask != nil else { return }
    log("HeartbeatScheduler: stopping (reason=\(reason))")
    loopTask?.cancel()
    loopTask = nil
  }

  func runNow() {
    Task { await runTurn(reason: "manual") }
  }

  private func runIfDue(reason: String) async {
    guard HeartbeatSettings.shared.isEnabled else {
      stop(reason: "disabled")
      return
    }
    if let lastRunAt, Date().timeIntervalSince(lastRunAt) < HeartbeatSettings.shared.intervalSeconds {
      return
    }
    await runTurn(reason: reason)
  }

  private func runTurn(reason: String) async {
    guard HeartbeatSettings.shared.isEnabled else { return }
    guard !runningTurn else {
      log("HeartbeatScheduler: skipping; previous turn still running")
      return
    }
    guard let chatProvider else {
      log("HeartbeatScheduler: skipping; no ChatProvider configured")
      return
    }

    runningTurn = true
    defer { runningTurn = false }
    lastRunAt = Date()

    do {
      let response = try await chatProvider.runHeartbeatTurn()
      let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        log("HeartbeatScheduler: empty heartbeat response")
        return
      }

      if isOk(trimmed) {
        log("HeartbeatScheduler: HEARTBEAT_OK")
        return
      }

      if shouldSuppressDuplicateAlert(trimmed) {
        log("HeartbeatScheduler: duplicate alert suppressed")
        return
      }

      lastAlertHash = trimmed.hashValue
      lastAlertAt = Date()
      NotificationService.shared.sendNotification(
        title: "Tom heartbeat",
        message: trimmed,
        assistantId: "tom-heartbeat",
        deliverSystemBanner: true
      )
      log("HeartbeatScheduler: delivered alert (reason=\(reason))")
    } catch {
      logError("HeartbeatScheduler: heartbeat turn failed", error: error)
    }
  }

  private func isOk(_ text: String) -> Bool {
    let upper = text.uppercased()
    if upper == "HEARTBEAT_OK" { return true }
    if upper.hasPrefix("HEARTBEAT_OK") && text.count <= 300 { return true }
    if upper.hasSuffix("HEARTBEAT_OK") && text.count <= 300 { return true }
    return false
  }

  private func shouldSuppressDuplicateAlert(_ text: String) -> Bool {
    guard let lastAlertHash, let lastAlertAt else { return false }
    return lastAlertHash == text.hashValue && Date().timeIntervalSince(lastAlertAt) < 6 * 60 * 60
  }
}
