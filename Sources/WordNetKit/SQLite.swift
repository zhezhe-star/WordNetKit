import Foundation
import SQLite3

/// `sqlite3_bind_text` copies the bytes when handed this destructor.
private let transientDestructor = unsafeBitCast(
    -1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self
)

/// A read-only SQLite connection with a prepared-statement cache.
///
/// Not `Sendable` on purpose: instances live inside the `WordNet` actor, which
/// serialises access to them.
final class Connection {
    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw WordNetError.databaseUnavailable(reason: message)
        }
        self.handle = handle
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    /// Runs `sql`, calling `readRow` once per result row.
    func query(
        _ sql: String,
        _ bindings: [Binding] = [],
        readRow: (Row) throws -> Void
    ) throws {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, transientDestructor)
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            }
        }

        let row = Row(statement: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try readRow(row)
            case SQLITE_DONE:
                return
            default:
                throw WordNetError.queryFailed(
                    reason: String(cString: sqlite3_errmsg(handle))
                )
            }
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw WordNetError.queryFailed(reason: String(cString: sqlite3_errmsg(handle)))
        }
        statements[sql] = statement
        return statement
    }

    enum Binding {
        case text(String)
        case integer(Int64)

        static func int(_ value: Int) -> Binding { .integer(Int64(value)) }
    }

    /// A cursor over the current row. Only valid inside the `readRow` closure.
    struct Row {
        let statement: OpaquePointer

        func string(_ index: Int32) -> String {
            guard let bytes = sqlite3_column_text(statement, index) else { return "" }
            let count = Int(sqlite3_column_bytes(statement, index))
            return String(
                decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self
            )
        }

        func optionalString(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : string(index)
        }

        func int(_ index: Int32) -> Int {
            Int(sqlite3_column_int64(statement, index))
        }
    }
}
