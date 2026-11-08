import Foundation

public enum KavachError: LocalizedError, Sendable, Equatable {
    case http(status: Int, message: String)
    case notRegistered
    case notFound(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .http(_, let m): m.isEmpty ? "The server refused the request." : m
        case .notRegistered: "Please finish setting up first."
        case .notFound(let what): "Couldn't find \(what)."
        case .transport(let m): "Can't reach the server. \(m)"
        }
    }
}

/// SpacetimeDB HTTP API client (docs/CONTRACTS.md section 1). Thin: reducers + SQL reads only.
public struct SpacetimeClient: Sendable {
    public let baseURL: URL
    public let database: String
    let session: URLSession

    public init(baseURL: URL, database: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.database = database
        self.session = session
    }

    public init(config: AppConfig) {
        self.init(baseURL: config.spacetimeURL, database: config.databaseName)
    }

    public struct Identity: Codable, Sendable { public let identity: String; public let token: String }

    /// `POST /v1/identity` → a fresh identity and token.
    public func newIdentity() async throws -> Identity {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/identity"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        let data = try await send(req)
        return try JSONDecoder().decode(Identity.self, from: data)
    }

    /// Calls a reducer with named args. Throws `.http` with the module's error text on failure.
    public func call(_ reducer: String, _ args: [String: JSONValue], token: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/database/\(database)/call/\(reducer)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(args)
        _ = try await send(req)
    }

    /// Runs a SQL query and decodes rows into `T`.
    public func query<T: Decodable>(_ sql: String, as: T.Type, token: String?) async throws -> [T] {
        try SQLDecoder.decode(T.self, from: await sqlData(sql, token: token))
    }

    public func sqlData(_ sql: String, token: String?) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/database/\(database)/sql"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = Data(sql.utf8)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw KavachError.transport(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw KavachError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

/// SQL string literal escaping for the few queries that embed a value (request keys are UUIDs).
public func sqlQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
