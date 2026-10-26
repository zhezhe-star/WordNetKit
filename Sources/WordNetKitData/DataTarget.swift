// This target exists only to package Open English WordNet's SQLite database.
// Consumers that only need query code should link WordNetKit, not this target.
import Foundation

public enum WordNetKitData {
    /// Canonical database filename bundled by this target.
    public static let databaseFilename = "wordnet.sqlite"
}
