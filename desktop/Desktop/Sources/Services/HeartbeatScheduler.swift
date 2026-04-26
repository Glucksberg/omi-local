import Foundation

enum HeartbeatRunStatus {
  case disabled
  case idle
  case running
  case ok
  case alert
  case skipped
  case error
}

@MainActor
final class HeartbeatScheduler: ObservableObject {
  static let shared = HeartbeatScheduler()

  private weak var chatProvider: ChatProvider?
  private var loopTask: Task<Void, Never>?
  private var runningTurn = false
  private var lastRunAt: Date?
  private var lastAlertHash: Int?
  private var lastAlertAt: Date?

  @Published private(set) var status: HeartbeatRunStatus = .idle
  @Published private(set) var statusText = "Not run yet"
  @Published private(set) var detailText = "Waiting for configuration"
  @Published private(set) var isRunningTurn = false
  @Published private(set) var lastStartedAt: Date?
  @Published private(set) var lastCompletedAt: Date?
  @Published private(set) var lastAlertText: String?

  var nextRunAt: Date? {
    guard HeartbeatSettings.shared.isEnabled else { return nil }
    guard !isRunningTurn else { return nil }
    guard let lastRunAt else { return Date() }
    return lastRunAt.addingTimeInterval(HeartbeatSettings.shared.intervalSeconds)
  }

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
    status = .idle
    statusText = "Enabled"
    detailText = "Waiting for the next heartbeat turn"
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
    status = .disabled
    statusText = "Disabled"
    detailText = "Scheduled heartbeat turns are off"
  }

  func runNow() {
    if runningTurn {
      status = .skipped
      statusText = "Already running"
      detailText = "A heartbeat turn is still in progress"
      return
    }
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
      status = .skipped
      statusText = "Skipped"
      detailText = "Previous heartbeat turn is still running"
      return
    }
    guard let chatProvider else {
      log("HeartbeatScheduler: skipping; no ChatProvider configured")
      status = .skipped
      statusText = "Skipped"
      detailText = "Chat provider is not ready yet"
      return
    }

    runningTurn = true
    isRunningTurn = true
    lastRunAt = Date()
    lastStartedAt = lastRunAt
    lastCompletedAt = nil
    let startedAt = lastRunAt ?? Date()
    var runResult: HeartbeatTurnResult?
    var runOutcome = "unknown"
    var runResponseText: String?
    var runError: Error?
    status = .running
    statusText = "Running"
    detailText = reason == "manual" ? "Manual heartbeat turn in progress" : "Scheduled heartbeat turn in progress"

    defer {
      runningTurn = false
      isRunningTurn = false
      let completedAt = Date()
      lastCompletedAt = completedAt
      HeartbeatRunLogger.append(
        startedAt: startedAt,
        completedAt: completedAt,
        reason: reason,
        outcome: runOutcome,
        result: runResult,
        responseText: runResponseText,
        error: runError
      )
    }

    do {
      let result = try await chatProvider.runHeartbeatTurn()
      runResult = result
      let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      runResponseText = trimmed
      guard !trimmed.isEmpty else {
        log("HeartbeatScheduler: empty heartbeat response")
        runOutcome = "empty_response"
        status = .ok
        statusText = "Completed"
        detailText = "Heartbeat returned no alert"
        return
      }

      if isOk(trimmed) {
        log("HeartbeatScheduler: HEARTBEAT_OK")
        runOutcome = "ok"
        status = .ok
        statusText = "OK"
        detailText = "No alert needed"
        return
      }

      if shouldSuppressDuplicateAlert(trimmed) {
        log("HeartbeatScheduler: duplicate alert suppressed")
        runOutcome = "duplicate_suppressed"
        status = .skipped
        statusText = "Duplicate suppressed"
        detailText = "Same alert was already delivered recently"
        return
      }

      lastAlertHash = trimmed.hashValue
      lastAlertAt = Date()
      lastAlertText = trimmed
      runOutcome = "alert_delivered"
      NotificationService.shared.sendNotification(
        title: "Tom heartbeat",
        message: trimmed,
        assistantId: "tom-heartbeat",
        deliverSystemBanner: true
      )
      status = .alert
      statusText = "Alert delivered"
      detailText = "Shown in the floating bar; macOS banner depends on notification permission"
      log("HeartbeatScheduler: delivered alert (reason=\(reason))")
    } catch {
      runOutcome = "error"
      runError = error
      status = .error
      statusText = "Error"
      detailText = error.localizedDescription
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
