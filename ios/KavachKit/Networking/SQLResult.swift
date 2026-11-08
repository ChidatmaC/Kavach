import Foundation

/// Decodes SpacetimeDB `/sql` responses:
/// `[{"schema":{"elements":[{"name":{"some":"id"},...}]},"rows":[[...]]}]`.
/// Each row is zipped with the column names into a JSON object, then decoded into `T` with
/// snake_case → camelCase conversion. Timestamps are `[micros]` (see `STTimestamp`).
public enum SQLDecoder {
    struct Statement: Decodable {
        struct Schema: Decodable { let elements: [Element] }
        struct Element: Decodable {
            struct Name: Decodable { let some: String? }
            let name: Name?
        }
        let schema: Schema
        let rows: [[JSONValue]]
    }

    /// Rows as objects keyed by column name (first statement only, like scripts/lib/stdb.ts).
    public static func objects(from data: Data) throws -> [[String: JSONValue]] {
        let statements = try JSONDecoder().decode([Statement].self, from: data)
        guard let first = statements.first else { return [] }
        let names = first.schema.elements.enumerated().map { $0.element.name?.some ?? "col\($0.offset)" }
        return first.rows.map { row in
            var obj: [String: JSONValue] = [:]
            for (i, v) in row.enumerated() where i < names.count { obj[names[i]] = v }
            return obj
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        let objs = try objects(from: data)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try objs.map { try decoder.decode(T.self, from: JSONEncoder().encode($0)) }
    }
}
