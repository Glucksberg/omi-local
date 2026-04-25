import Foundation

/// Loads TomMemory bootstrap files using the same small, boring pattern that
/// OpenClaw uses for workspace context: recognized root files only, stable
/// ordering, per-file and total prompt budgets, and explicit file metadata.
///
/// This intentionally does not implement retrieval/search. It only makes the
/// current canonical TomMemory bootstrap visible when a chat session is created.
struct TomMemoryBootstrapService {
    static let shared = TomMemoryBootstrapService()

    private let fileManager = FileManager.default
    private let maxCharsPerFile = 12_000
    private let maxTotalChars = 60_000
    private let minimumFileBudget = 64

    private enum BootstrapKind: String {
        case agents = "AGENTS.md"
        case soul = "SOUL.md"
        case identity = "IDENTITY.md"
        case user = "USER.md"
        case tools = "TOOLS.md"
        case bootstrap = "BOOTSTRAP.md"
        case memory = "MEMORY.md"
        case heartbeat = "HEARTBEAT.md"
    }

    private struct BootstrapFile {
        let kind: BootstrapKind
        let path: String
        let content: String
    }

    private let orderedFiles: [BootstrapKind] = [
        .agents,
        .soul,
        .identity,
        .user,
        .tools,
        .bootstrap,
        .memory,
        .heartbeat,
    ]

    private init() {}

    func buildPromptSection() -> String {
        let root = resolveRootPath()
        guard fileManager.fileExists(atPath: root) else { return "" }

        let files = loadBootstrapFiles(root: root)
        guard !files.isEmpty else { return "" }

        var remaining = maxTotalChars
        var renderedBlocks: [String] = []

        for file in files {
            guard remaining >= minimumFileBudget else { break }
            let budget = min(maxCharsPerFile, remaining)
            let trimmed = trim(content: file.content, fileName: file.kind.rawValue, maxChars: budget)
            guard !trimmed.content.isEmpty else { continue }
            remaining -= trimmed.content.count
            renderedBlocks.append(render(file: file, content: trimmed.content, originalLength: file.content.count, limit: budget))
        }

        guard !renderedBlocks.isEmpty else { return "" }

        return """
        <tom_memory_bootstrap>
        The following TomMemory bootstrap files have been loaded from \(root).
        Follow AGENTS.md for operating rules. If SOUL.md is present, embody its voice and stance unless higher-priority instructions override it.
        Treat USER.md as the compact human profile, MEMORY.md as current canon, HEARTBEAT.md as current operating state, and BOOTSTRAP.md as startup guidance.
        Daily notes and archive files are not injected here; use tools to read them when relevant.

        \(renderedBlocks.joined(separator: "\n\n"))
        </tom_memory_bootstrap>
        """
    }

    private func resolveRootPath() -> String {
        if let configured = ProcessInfo.processInfo.environment["TOM_MEMORY_ROOT"], !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return expandHome(configured.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let defaultsValue = UserDefaults.standard.string(forKey: "tomMemoryRootPath")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let defaultsValue, !defaultsValue.isEmpty {
            return expandHome(defaultsValue)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Omi")
            .appendingPathComponent("TomMemory")
            .path
    }

    private func expandHome(_ path: String) -> String {
        if path == "~" { return fileManager.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private func loadBootstrapFiles(root: String) -> [BootstrapFile] {
        orderedFiles.compactMap { kind in
            let path = URL(fileURLWithPath: root).appendingPathComponent(kind.rawValue).path
            guard fileManager.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8)
            else { return nil }
            return BootstrapFile(kind: kind, path: path, content: content)
        }
    }

    private func tagName(for kind: BootstrapKind) -> String {
        switch kind {
        case .agents: return "operating_rules"
        case .soul: return "self"
        case .identity: return "identity"
        case .user: return "human"
        case .tools: return "tool_notes"
        case .bootstrap: return "bootstrap"
        case .memory: return "core_memory"
        case .heartbeat: return "heartbeat"
        }
    }

    private func description(for kind: BootstrapKind) -> String {
        switch kind {
        case .agents: return "Operating rules and memory protocol."
        case .soul: return "Tom's voice, stance, tone, and boundaries."
        case .identity: return "Short identity card for Tom."
        case .user: return "Compact profile of Markus."
        case .tools: return "Local tool usage notes and safety discipline."
        case .bootstrap: return "Startup ritual until an automatic loader replaces it."
        case .memory: return "Current canonical memory."
        case .heartbeat: return "Current operating state and next moves."
        }
    }

    private func render(file: BootstrapFile, content: String, originalLength: Int, limit: Int) -> String {
        let tag = tagName(for: file.kind)
        return """
        <\(tag)>
        <projection>\(file.path)</projection>
        <description>\(description(for: file.kind))</description>
        <metadata>
        - filename=\(file.kind.rawValue)
        - chars_current=\(originalLength)
        - chars_injected=\(content.count)
        - chars_limit=\(limit)
        </metadata>
        <value>
        \(content)
        </value>
        </\(tag)>
        """
    }

    private func trim(content: String, fileName: String, maxChars: Int) -> (content: String, truncated: Bool) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return (trimmed, false) }
        guard maxChars > 32 else { return (String(trimmed.prefix(maxChars)), true) }

        let marker = "\n[...truncated, read \(fileName) for full content...]\n"
        let available = max(0, maxChars - marker.count)
        let headCount = Int(Double(available) * 0.75)
        let tailCount = max(0, available - headCount)
        let head = String(trimmed.prefix(headCount))
        let tail = String(trimmed.suffix(tailCount))
        let result = head + marker + tail
        if result.count <= maxChars { return (result, true) }
        return (String(result.prefix(maxChars)), true)
    }
}
