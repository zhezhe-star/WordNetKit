import Foundation

public enum WordNetError: Error, Sendable, Equatable {
    /// The bundled database is missing from the module's resources.
    case databaseNotFound
    /// SQLite could not open the database file.
    case databaseUnavailable(reason: String)
    /// A query failed to prepare or step.
    case queryFailed(reason: String)
}

extension WordNetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            "The WordNet database could not be found in the bundle."
        case .databaseUnavailable(let reason):
            "The WordNet database could not be opened: \(reason)"
        case .queryFailed(let reason):
            "A WordNet query failed: \(reason)"
        }
    }
}
