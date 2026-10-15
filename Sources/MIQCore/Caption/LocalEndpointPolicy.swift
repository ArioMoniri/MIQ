import Foundation

/// Validates the user-configured OpenAI-compatible endpoint for the "Describe
/// file" feature (e.g. a llama.cpp server running a local model).
///
/// The feature's privacy promise is that no header data leaves the Mac, so the
/// endpoint must be a loopback address. This is enforced here, in code, rather
/// than trusting the settings field: only `http` / `https` URLs whose host is
/// exactly `localhost`, a dotted-quad in 127.0.0.0/8, or the IPv6 loopback
/// `::1` are accepted. Look-alike hosts (`localhost.evil.com`,
/// `127.0.0.1.nip.io`), shorthand IPv4 forms (`127.1`, `2130706433`), embedded
/// credentials and every other scheme are rejected. Callers must additionally
/// refuse HTTP redirects, because a loopback server could otherwise bounce the
/// request elsewhere — see `isAllowedRedirect(to:)`.
public enum LocalEndpointPolicy {

    public enum Rejection: Error, Equatable, Sendable {
        case malformed
        case unsupportedScheme
        case nonLoopbackHost
        case credentialsNotAllowed
    }

    /// Default suggested in Settings (llama.cpp's `llama-server` default port).
    public static let defaultEndpoint = "http://127.0.0.1:8080"

    /// Returns the normalised base URL, or why it was rejected.
    public static func validate(_ string: String) -> Result<URL, Rejection> {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let url = components.url else { return .failure(.malformed) }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme)
        }
        guard components.user == nil, components.password == nil else {
            return .failure(.credentialsNotAllowed)
        }
        guard let host = components.host, !host.isEmpty else { return .failure(.malformed) }
        guard isLoopbackHost(host) else { return .failure(.nonLoopbackHost) }
        return .success(url)
    }

    /// Throwing convenience over `validate(_:)`.
    static func validatedBaseURL(_ string: String) throws -> URL {
        try validate(string).get()
    }

    /// `true` only for `localhost` (optionally with a trailing root dot), a
    /// strict four-octet IPv4 address in 127.0.0.0/8, or IPv6 `::1` in any
    /// spelling (brackets and zero-padding tolerated).
    public static func isLoopbackHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host == "localhost." { return true }
        if isLoopbackIPv4(host) { return true }
        return isLoopbackIPv6(host)
    }

    /// A redirect target is acceptable only if it would itself pass `validate`.
    /// The app's URLSession delegate refuses all redirects regardless; this is
    /// exposed for tests and for callers that choose to follow same-host ones.
    public static func isAllowedRedirect(to url: URL) -> Bool {
        if case .success = validate(url.absoluteString) { return true }
        return false
    }

    /// Resolves the chat-completions URL for a validated base: a base ending in
    /// `/chat/completions` is used as is, one ending in `/v1` gets
    /// `/chat/completions`, anything else gets `/v1/chat/completions`.
    public static func chatCompletionsURL(base: URL) -> URL {
        var path = base.path
        while path.hasSuffix("/") { path.removeLast() }
        let suffix: String
        if path.hasSuffix("/chat/completions") {
            suffix = ""
        } else if path.hasSuffix("/v1") {
            suffix = "/chat/completions"
        } else {
            suffix = "/v1/chat/completions"
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = path + suffix
        components.query = nil
        components.fragment = nil
        return components.url ?? base
    }

    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var values: [Int] = []
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 3, octet.allSatisfy(\.isASCII), octet.allSatisfy(\.isNumber),
                  let value = Int(octet), value <= 255 else { return false }
            values.append(value)
        }
        return values[0] == 127
    }

    private static func isLoopbackIPv6(_ host: String) -> Bool {
        // Strip a zone index ("::1%lo0").
        let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard address.contains(":"),
              address.allSatisfy({ $0 == ":" || $0.isHexDigit }) else { return false }
        let doubleColons = address.components(separatedBy: "::").count - 1
        guard doubleColons <= 1 else { return false }
        let groups: [String]
        if doubleColons == 1 {
            let halves = address.components(separatedBy: "::")
            let head = halves[0].isEmpty ? [] : halves[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let tail = halves[1].isEmpty ? [] : halves[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard head.count + tail.count < 8 else { return false }
            groups = head + Array(repeating: "0", count: 8 - head.count - tail.count) + tail
        } else {
            groups = address.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        }
        guard groups.count == 8,
              groups.allSatisfy({ !$0.isEmpty && $0.count <= 4 }) else { return false }
        let values = groups.compactMap { UInt16($0, radix: 16) }
        guard values.count == 8 else { return false }
        return values.dropLast().allSatisfy { $0 == 0 } && values[7] == 1
    }
}
