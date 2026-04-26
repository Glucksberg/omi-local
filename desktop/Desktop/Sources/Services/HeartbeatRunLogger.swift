import Foundation

enum HeartbeatRunLogger {
  private struct SettingsSnapshot {
    let memoryDirectory: String
    let runLogFilePath: String
    let allowMemoryWrites: Bool

    @MainActor
    init(_ settings: HeartbeatSettings) {
      memoryDirectory = settings.memoryDirectory
      runLogFilePath = settings.runLogFilePath
      allowMemoryWrites = settings.allowMemoryWrites
    }
  }

  @MainActor
  static func append(
    startedAt: Date,
    completedAt: Date,
    reason: String,
    outcome: String,
    result: HeartbeatTurnResult?,
    responseText: String?,
    error: Error?
  ) {
    let settings = SettingsSnapshot(HeartbeatSettings.shared)
    let directoryURL = URL(fileURLWithPath: settings.memoryDirectory, isDirectory: true)
    let logURL = URL(fileURLWithPath: settings.runLogFilePath)

    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

      if !FileManager.default.fileExists(atPath: logURL.path) {
        let header = """
        # HEARTBEAT_LOG

        Local audit trail for Omi Local heartbeat runs. This file is written by the app after each heartbeat turn.

        """
        try header.write(to: logURL, atomically: true, encoding: .utf8)
      }

      let entry = makeEntry(
        startedAt: startedAt,
        completedAt: completedAt,
        reason: reason,
        outcome: outcome,
        settings: settings,
        result: result,
        responseText: responseText,
        error: error
      )

      let handle = try FileHandle(forWritingTo: logURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      if let data = entry.data(using: .utf8) {
        try handle.write(contentsOf: data)
      }
      log("HeartbeatRunLogger: appended run summary to \(logURL.path)")
    } catch {
      logError("HeartbeatRunLogger: failed to append run summary", error: error)
    }
  }

  private static func makeEntry(
    startedAt: Date,
    completedAt: Date,
    reason: String,
    outcome: String,
    settings: SettingsSnapshot,
    result: HeartbeatTurnResult?,
    responseText: String?,
    error: Error?
  ) -> String {
    var lines: [String] = []
    lines.append("\n## \(isoString(completedAt))")
    lines.append("- Started: \(isoString(startedAt))")
    lines.append("- Completed: \(isoString(completedAt))")
    lines.append("- Duration: \(String(format: "%.1f", completedAt.timeIntervalSince(startedAt)))s")
    lines.append("- Trigger: \(inlineCode(reason))")
    lines.append("- Outcome: \(inlineCode(outcome))")
    lines.append("- Memory writes: \(settings.allowMemoryWrites ? "enabled" : "disabled")")
    lines.append("- Write scope: \(inlineCode(settings.memoryDirectory))")

    if let result {
      lines.append("- Tokens: input \(result.inputTokens), output \(result.outputTokens)")
      if result.costUsd > 0 {
        lines.append("- Cost: \(String(format: "$%.6f", result.costUsd))")
      }
    }

    if let error {
      lines.append("- Error: \(inlineCode(error.localizedDescription))")
    } else if let responseText {
      lines.append("- Response: \(inlineCode(truncate(responseText, max: 500)))")
    }

    lines.append("")
    lines.append("### Useful Work")
    lines.append(contentsOf: usefulWorkLines(from: result?.toolActivities ?? []))
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private static func usefulWorkLines(from activities: [HeartbeatToolActivity]) -> [String] {
    guard !activities.isEmpty else {
      return ["- No tool activity recorded."]
    }

    let hasTerminalActivities = activities.contains { activity in
      isTerminalStatus(activity.status)
    }

    var seen = Set<String>()
    var lastInputSummaryByTool: [String: String] = [:]
    var lines: [String] = []
    for activity in activities {
      if let inputSummary = activity.inputSummary {
        lastInputSummaryByTool[activity.name] = inputSummary
      }

      if hasTerminalActivities && !isTerminalStatus(activity.status) {
        continue
      }

      let summary = activity.inputSummary ?? lastInputSummaryByTool[activity.name] ?? ""
      let key = "\(activity.name)|\(activity.status)|\(summary)"
      guard !seen.contains(key) else { continue }
      seen.insert(key)

      if summary.isEmpty {
        lines.append("- \(inlineCode(activity.name)) \(activity.status)")
      } else {
        lines.append("- \(inlineCode(activity.name)) \(activity.status): \(inlineCode(summary))")
      }

      if lines.count >= 30 {
        lines.append("- Additional tool activity truncated.")
        break
      }
    }

    return lines.isEmpty ? ["- No useful tool activity recorded."] : lines
  }

  private static func isTerminalStatus(_ status: String) -> Bool {
    let normalized = status.lowercased()
    return normalized.contains("complete") || normalized.contains("deny") || normalized.contains("error")
  }

  private static func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func inlineCode(_ text: String) -> String {
    "`\(text.replacingOccurrences(of: "`", with: "'"))`"
  }

  private static func truncate(_ text: String, max: Int) -> String {
    let normalized = text
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > max else { return normalized }
    return String(normalized.prefix(max - 1)) + "…"
  }
}
