import Foundation

/// omi-local mode disables vendor auth/config bootstrapping and uses a
/// deterministic local user so the desktop app can run without Google services.
enum LocalMode {
  static let userId = "local-user"
  static let email = "local@omi.local"
  static let token = "omi-local-dev-token"
  static let refreshToken = "omi-local-dev-refresh-token"
  static let tokenLifetimeSeconds = 365 * 24 * 60 * 60
  static let defaultLocalAPIURL = "http://127.0.0.1:10201/"
  static let openAIAPIProvider = "openai"
  static let openAICodexProvider = "openai-codex"
  static let defaultRemoteLLMModel = "gpt-5.5"

  static var isEnabled: Bool {
    CommandLine.arguments.contains("--local-mode")
      || envFlag("OMI_LOCAL_MODE")
      || Bundle.main.bundleIdentifier == "com.omi.omi-local"
  }

  static var isAgentBridgeEnabled: Bool {
    envFlag("OMI_LOCAL_AGENT_BRIDGE") || isRemoteLLMEnabled || getenv("OMI_LOCAL_LLM_BASE_URL") != nil
  }

  static var isAIProxyEnabled: Bool {
    envFlag("OMI_LOCAL_AI_ENABLED") || getenv("OMI_LOCAL_AI_PROXY_URL") != nil
  }

  static var isTranscriptionEnabled: Bool {
    envFlag("OMI_LOCAL_TRANSCRIPTION_ENABLED") || getenv("OMI_LOCAL_TRANSCRIPTION_URL") != nil
  }

  static var isTTSEnabled: Bool {
    envFlag("OMI_LOCAL_TTS_ENABLED") || getenv("OMI_LOCAL_TTS_URL") != nil
  }

  static var remoteLLMProvider: String? {
    guard let raw = getenv("OMI_REMOTE_LLM_PROVIDER").flatMap({ String(validatingUTF8: $0) }) else {
      return nil
    }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
  }

  static var isRemoteLLMEnabled: Bool {
    guard isEnabled, let provider = remoteLLMProvider else { return false }
    if provider == openAICodexProvider {
      return hasPiAuthCredential(provider: openAICodexProvider, type: "oauth")
    }
    if provider == openAIAPIProvider {
      return openAIAPIKey != nil
    }
    return envFlag("OMI_REMOTE_LLM_ENABLED")
  }

  static var isOpenAIRemoteLLMEnabled: Bool {
    guard isRemoteLLMEnabled else { return false }
    return remoteLLMProvider == openAIAPIProvider || remoteLLMProvider == openAICodexProvider
  }

  static var remoteLLMModel: String {
    if let raw = getenv("OMI_REMOTE_LLM_MODEL").flatMap({ String(validatingUTF8: $0) }),
      !raw.isEmpty
    {
      return raw
    }
    return defaultRemoteLLMModel
  }

  static var openAIAPIKey: String? {
    guard let raw = getenv("OPENAI_API_KEY").flatMap({ String(validatingUTF8: $0) }) else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static var piAuthPath: String {
    let agentDir: String
    if let raw = getenv("PI_CODING_AGENT_DIR").flatMap({ String(validatingUTF8: $0) }),
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "~" {
        agentDir = FileManager.default.homeDirectoryForCurrentUser.path
      } else if trimmed.hasPrefix("~/") {
        agentDir = FileManager.default.homeDirectoryForCurrentUser.path + String(trimmed.dropFirst())
      } else {
        agentDir = trimmed
      }
    } else {
      agentDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi")
        .appendingPathComponent("agent")
        .path
    }
    return (agentDir as NSString).appendingPathComponent("auth.json")
  }

  static func hasPiAuthCredential(provider: String, type expectedType: String? = nil) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: piAuthPath)),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let credential = json[provider] as? [String: Any]
    else {
      return false
    }
    guard let expectedType else { return true }
    return (credential["type"] as? String) == expectedType
  }

  static var localAPIURL: String {
    if let raw = getenv("OMI_API_URL").flatMap({ String(validatingUTF8: $0) }), isLoopbackURL(raw) {
      return raw.hasSuffix("/") ? raw : raw + "/"
    }
    if let raw = getenv("OMI_DESKTOP_API_URL").flatMap({ String(validatingUTF8: $0) }), isLoopbackURL(raw) {
      return raw.hasSuffix("/") ? raw : raw + "/"
    }
    return defaultLocalAPIURL
  }

  private static func isLoopbackURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw), let host = url.host?.lowercased() else {
      return false
    }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  static var localAIProxyURL: String? {
    guard isAIProxyEnabled else { return nil }
    if let raw = getenv("OMI_LOCAL_AI_PROXY_URL").flatMap({ String(validatingUTF8: $0) }), !raw.isEmpty {
      return raw.hasSuffix("/") ? raw : raw + "/"
    }
    return localAPIURL
  }

  static var localTTSURL: String? {
    guard isTTSEnabled else { return nil }
    if let raw = getenv("OMI_LOCAL_TTS_URL").flatMap({ String(validatingUTF8: $0) }), !raw.isEmpty {
      return raw.hasSuffix("/") ? raw : raw + "/"
    }
    if let raw = getenv("OMI_LOCAL_TRANSCRIPTION_URL").flatMap({ String(validatingUTF8: $0) }),
      !raw.isEmpty
    {
      return raw.hasSuffix("/") ? raw : raw + "/"
    }
    return localAPIURL
  }

  static func envFlag(_ name: String) -> Bool {
    guard let raw = getenv(name).flatMap({ String(validatingUTF8: $0) }) else {
      return false
    }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["1", "true", "yes", "on"].contains(normalized)
  }
}
