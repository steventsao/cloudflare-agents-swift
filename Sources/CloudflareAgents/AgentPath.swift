import Foundation

/// One agent identity in a root-first address chain.
///
/// Mirrors `AgentPathStep` from `cloudflare/agents` `packages/agents/src/sub-routing.ts`.
public struct AgentPathStep: Equatable, Sendable {
    /// Agent class name as exported by the Worker.
    public let className: String
    /// Logical Agent instance name.
    public let name: String

    public init(className: String, name: String) {
        self.className = className
        self.name = name
    }
}

/// Options for `buildAgentPath` / `buildAgentUrl`.
public struct BuildAgentPathOptions: Equatable, Sendable {
    /// Top-level route prefix. Must match `routeAgentRequest`; defaults to `agents`.
    public var prefix: String
    /// Pathname suffix appended after the destination Agent identity.
    public var leafPath: String?
    /// Root Durable Object binding name, when it differs from the root class name.
    public var rootBinding: String?

    public init(prefix: String = "agents", leafPath: String? = nil, rootBinding: String? = nil) {
        self.prefix = prefix
        self.leafPath = leafPath
        self.rootBinding = rootBinding
    }
}

/// Errors thrown while composing Agent addresses.
public enum AgentPathError: Error, Equatable, LocalizedError, Sendable {
    case emptyPath
    case invalidLeafPath(String)
    case invalidRoutingPrefix(String)
    case invalidAgentClassName(String)
    case invalidChildAgentName(String)
    case invalidRootAgentName(String)
    case reservedIdentity(String)
    case invalidOrigin(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Agent path must contain at least one step."
        case .invalidLeafPath(let value):
            return "Cannot build an Agent path for leaf path \(String(reflecting: value)) because it is not a stable pathname."
        case .invalidRoutingPrefix(let value):
            return "Cannot build an Agent path for routing prefix \(String(reflecting: value)) because it is not externally routable."
        case .invalidAgentClassName(let value):
            return "Cannot build an Agent path for Agent class name \(String(reflecting: value)) because it is not externally routable."
        case .invalidChildAgentName(let value):
            return "Cannot build an Agent path for child Agent name \(String(reflecting: value)) because it is not externally routable."
        case .invalidRootAgentName(let value):
            return "Cannot build an Agent path for root Agent name \(String(reflecting: value)) because it is not externally routable."
        case .reservedIdentity(let value):
            return "Cannot build an Agent path for \(String(reflecting: value)) because \"\(AgentPath.subPrefix)\" is reserved."
        case .invalidOrigin(let value):
            return "Invalid Agent URL origin \(String(reflecting: value)). Pass an HTTP(S) or WS(S) origin without credentials, a pathname, query, or fragment."
        }
    }
}

/// Canonical root-first Agent / sub-agent address builders.
///
/// Port of `buildAgentPath` / `buildAgentUrl` from upstream `agents@0.21.0`.
public enum AgentPath {
    public static let subPrefix = "sub"

    /// Build the strictly validated path tail for sub-agent routing.
    public static func buildSubAgentPath(
        _ path: [AgentPathStep],
        leafPath: String? = nil
    ) throws -> String {
        try serializeSubAgentPath(path, leafPath: leafPath, validate: true)
    }

    /// Tolerant path composition for disabled placeholders (mirrors React).
    public static func buildSubAgentPathUnchecked(
        _ path: [AgentPathStep],
        leafPath: String? = nil
    ) -> String {
        (try? serializeSubAgentPath(path, leafPath: leafPath, validate: false)) ?? ""
    }

    /// Build the canonical pathname for a root Agent or nested sub-agent.
    public static func buildAgentPath(
        _ path: [AgentPathStep],
        options: BuildAgentPathOptions = .init()
    ) throws -> String {
        guard let root = path.first else {
            throw AgentPathError.emptyPath
        }
        let children = Array(path.dropFirst())

        let rootPath = [
            try validateRoutingPrefix(options.prefix),
            try encodeAgentClassName(options.rootBinding ?? root.className),
            try validateRootAgentName(root.name)
        ].joined(separator: "/")

        let leafPath = try options.leafPath.map { try validateLeafPath($0) }
        if children.isEmpty {
            return "/\(rootPath)\(leafPath ?? "")"
        }
        return "/\(rootPath)/\(try buildSubAgentPath(children, leafPath: leafPath))"
    }

    /// Build an absolute URL for a root Agent or nested sub-agent.
    public static func buildAgentURL(
        origin: String,
        path: [AgentPathStep],
        options: BuildAgentPathOptions = .init()
    ) throws -> URL {
        guard let base = URL(string: origin) else {
            throw AgentPathError.invalidOrigin(origin)
        }
        return try buildAgentURL(origin: base, path: path, options: options)
    }

    /// Build an absolute URL for a root Agent or nested sub-agent.
    public static func buildAgentURL(
        origin: URL,
        path: [AgentPathStep],
        options: BuildAgentPathOptions = .init()
    ) throws -> URL {
        let allowedSchemes: Set<String> = ["http", "https", "ws", "wss"]
        guard
            let scheme = origin.scheme?.lowercased(),
            allowedSchemes.contains(scheme),
            origin.user == nil,
            origin.password == nil,
            (origin.path.isEmpty || origin.path == "/"),
            origin.query == nil,
            origin.fragment == nil
        else {
            throw AgentPathError.invalidOrigin(origin.absoluteString)
        }

        let pathname = try buildAgentPath(path, options: options)
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw AgentPathError.invalidOrigin(origin.absoluteString)
        }
        components.percentEncodedPath = pathname
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw AgentPathError.invalidOrigin(origin.absoluteString)
        }
        return url
    }

    // MARK: - Internals

    private static func serializeSubAgentPath(
        _ path: [AgentPathStep],
        leafPath: String?,
        validate: Bool
    ) throws -> String {
        if path.isEmpty {
            return leafPath ?? ""
        }

        var segments: [String] = []
        for child in path {
            segments.append(subPrefix)
            if validate {
                segments.append(try encodeAgentClassName(child.className))
                segments.append(try encodeChildAgentName(child.name))
            } else {
                segments.append(camelCaseToKebabCase(child.className))
                segments.append(encodeURIComponent(child.name))
            }
        }
        let subPath = segments.joined(separator: "/")
        guard let leafPath else { return subPath }
        let normalizedLeaf = leafPath.hasPrefix("/") ? leafPath : "/\(leafPath)"
        return "\(subPath)\(normalizedLeaf)"
    }

    private static func validateLeafPath(_ leafPath: String) throws -> String {
        let normalized = leafPath.hasPrefix("/") ? leafPath : "/\(leafPath)"
        if normalized.contains("//")
            || (normalized.count > 1 && normalized.hasSuffix("/"))
            || !isLiteralStablePathname(normalized)
        {
            throw AgentPathError.invalidLeafPath(leafPath)
        }
        return normalized
    }

    private static func validateRoutingPrefix(_ prefix: String) throws -> String {
        // Match JS `prefix.split("/")`, including `[""]` for the empty string.
        let prefixParts: [String] = prefix.isEmpty
            ? [""]
            : prefix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let rawPath = "/\(prefix)/leaf"
        if prefixParts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == subPrefix })
            || !isLiteralStablePathname(rawPath)
        {
            throw AgentPathError.invalidRoutingPrefix(prefix)
        }
        return prefix
    }

    private static func encodeAgentClassName(_ className: String) throws -> String {
        let segment = camelCaseToKebabCase(className)
        if segment == subPrefix {
            throw AgentPathError.reservedIdentity(className)
        }
        let rawPath = "/root/\(segment)/leaf"
        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segment.isEmpty
            || !isLiteralStablePathname(rawPath)
            || parts.count != 4
            || parts[2] != segment
        {
            throw AgentPathError.invalidAgentClassName(className)
        }
        return segment
    }

    private static func encodeChildAgentName(_ name: String) throws -> String {
        if name.isEmpty || name == "." || name == ".." || name.contains("\0") || containsUnpairedSurrogate(name) {
            throw AgentPathError.invalidChildAgentName(name)
        }
        return encodeURIComponent(name)
    }

    private static func validateRootAgentName(_ name: String) throws -> String {
        if name == subPrefix {
            throw AgentPathError.reservedIdentity(name)
        }
        let rawPath = "/root/\(name)/leaf"
        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if name.isEmpty
            || !isLiteralStablePathname(rawPath)
            || parts.count != 4
            || parts[2] != name
        {
            throw AgentPathError.invalidRootAgentName(name)
        }
        return name
    }

    /// Approximate WHATWG pathname stability used by upstream `new URL(path, base)`.
    ///
    /// A pathname is stable when parsing would neither encode characters nor
    /// normalize away `.` / `..` (including `%2e` forms), and when it has no
    /// query or fragment markers.
    private static func isLiteralStablePathname(_ path: String) -> Bool {
        if path.contains("?") || path.contains("#") {
            return false
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for segment in segments {
            if segment == "." || segment == ".." {
                return false
            }
            let decoded = percentDecodeForDotSegment(segment)
            if decoded == "." || decoded == ".." {
                return false
            }
            if !segment.isEmpty && !isPcharSegment(segment) {
                return false
            }
        }
        return true
    }

    private static func isPcharSegment(_ segment: String) -> Bool {
        // RFC 3986 pchar without requiring us to decode %2F (PartyServer keeps it literal).
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")
        var index = segment.startIndex
        while index < segment.endIndex {
            let ch = segment[index]
            if ch == "%" {
                let next = segment.index(index, offsetBy: 1, limitedBy: segment.endIndex)
                let next2 = segment.index(index, offsetBy: 2, limitedBy: segment.endIndex)
                guard let next, let next2, next2 < segment.endIndex else { return false }
                let h1 = segment[next]
                let h2 = segment[segment.index(after: next)]
                guard h1.isHexDigit && h2.isHexDigit else { return false }
                index = segment.index(after: next2)
                continue
            }
            guard allowed.contains(ch) else { return false }
            index = segment.index(after: index)
        }
        return true
    }

    private static func percentDecodeForDotSegment(_ segment: String) -> String {
        var output = ""
        var index = segment.startIndex
        while index < segment.endIndex {
            let ch = segment[index]
            if ch == "%" {
                let next = segment.index(index, offsetBy: 1, limitedBy: segment.endIndex)
                let next2 = segment.index(index, offsetBy: 2, limitedBy: segment.endIndex)
                if let next, let next2, next2 < segment.endIndex {
                    let hex = String(segment[next...next2])
                    if let value = UInt8(hex, radix: 16) {
                        output.append(Character(UnicodeScalar(value)))
                        index = segment.index(after: next2)
                        continue
                    }
                }
            }
            output.append(ch)
            index = segment.index(after: index)
        }
        return output
    }

    private static func containsUnpairedSurrogate(_ string: String) -> Bool {
        var index = string.utf16.startIndex
        while index < string.utf16.endIndex {
            let unit = string.utf16[index]
            if (0xD800...0xDBFF).contains(unit) {
                let next = string.utf16.index(after: index)
                guard next < string.utf16.endIndex else { return true }
                let trailing = string.utf16[next]
                if !(0xDC00...0xDFFF).contains(trailing) {
                    return true
                }
                index = string.utf16.index(after: next)
            } else if (0xDC00...0xDFFF).contains(unit) {
                return true
            } else {
                index = string.utf16.index(after: index)
            }
        }
        return false
    }
}

/// Convenience wrappers matching the upstream free-function names.
public func buildAgentPath(
    _ path: [AgentPathStep],
    options: BuildAgentPathOptions = .init()
) throws -> String {
    try AgentPath.buildAgentPath(path, options: options)
}

public func buildAgentURL(
    origin: String,
    path: [AgentPathStep],
    options: BuildAgentPathOptions = .init()
) throws -> URL {
    try AgentPath.buildAgentURL(origin: origin, path: path, options: options)
}
