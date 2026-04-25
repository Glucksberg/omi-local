import Foundation

enum LocalNetworkPolicy {
  private static var didInstall = false

  static var blocksExternalEgress: Bool {
    LocalMode.isEnabled && !LocalMode.envFlag("OMI_LOCAL_ALLOW_EGRESS")
  }

  static var allowsLAN: Bool {
    LocalMode.envFlag("OMI_LOCAL_ALLOW_LAN")
  }

  static func installIfNeeded() {
    guard blocksExternalEgress else { return }
    guard !didInstall else { return }
    didInstall = true
    _ = URLProtocol.registerClass(LocalNetworkGuardURLProtocol.self)
    NSLog("OMI LOCAL NETWORK: external egress blocked; loopback allowed")
  }

  static func apply(to configuration: URLSessionConfiguration) {
    guard blocksExternalEgress else { return }
    let existing = configuration.protocolClasses ?? []
    if existing.contains(where: { $0 == LocalNetworkGuardURLProtocol.self }) {
      return
    }
    configuration.protocolClasses = [LocalNetworkGuardURLProtocol.self] + existing
  }

  static func validate(_ url: URL) throws {
    guard blocksExternalEgress, !isAllowed(url) else { return }
    throw LocalNetworkError.blocked(url.absoluteString)
  }

  static func isAllowed(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return true }

    switch scheme {
    case "file", "data", "about":
      return true
    case "http", "https", "ws", "wss":
      guard let host = url.host?.lowercased() else { return false }
      return isLoopbackHost(host) || (allowsLAN && isLANHost(host))
    default:
      return true
    }
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  private static func isLANHost(_ host: String) -> Bool {
    if host.hasSuffix(".local") { return true }
    if host.hasPrefix("10.") { return true }
    if host.hasPrefix("192.168.") { return true }

    let parts = host.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) {
      return true
    }
    return false
  }
}

enum LocalNetworkError: LocalizedError {
  case blocked(String)

  var errorDescription: String? {
    switch self {
    case .blocked(let url):
      return "omi-local blocked external network request: \(url)"
    }
  }
}

final class LocalNetworkGuardURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    guard let url = request.url else { return false }
    return LocalNetworkPolicy.blocksExternalEgress && !LocalNetworkPolicy.isAllowed(url)
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let urlString = request.url?.absoluteString ?? "unknown"
    NSLog("OMI LOCAL NETWORK: blocked %@", urlString)
    client?.urlProtocol(self, didFailWithError: LocalNetworkError.blocked(urlString))
  }

  override func stopLoading() {}
}
