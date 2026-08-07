import Foundation

/// An offline English dictionary and thesaurus backed by Open English WordNet.
///
/// The database ships inside this package, so lookups never touch the network:
///
/// ```swift
/// let senses = try await WordNet.shared.senses(for: "susurrus")
/// print(senses.first?.definition ?? "not found")
/// // the indistinct sound of people whispering
/// ```
///
/// The actor serialises access to a single read-only SQLite connection. Queries
/// are fast enough to drive search-as-you-type directly.
public actor WordNet {
    /// A shared instance backed by the bundled database.
    public static let shared = WordNet()

    private let databaseURL: URL?
    private var connection: Connection?

    /// - Parameter databaseURL: A database built by `Tools/build_db.py`. Pass
    ///   `nil` to use the one bundled with this package.
    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    private func database() throws -> Connection {
        if let connection { return connection }

        let url: URL
        if let databaseURL {
            url = databaseURL
        } else {
            guard let bundled = Bundle.module.url(forResource: "wordnet", withExtension: "sqlite")
            else {
                throw WordNetError.databaseNotFound
            }
            url = bundled
        }

        let connection = try Connection(path: url.path)
        self.connection = connection
        return connection
    }

    // MARK: - Metadata

    /// Provenance of the bundled data, including the attribution line CC BY 4.0
    /// requires you to display.
    public func metadata() throws -> Metadata {
        var values: [String: String] = [:]
        try database().query("SELECT key, value FROM meta") { row in
            values[row.string(0)] = row.string(1)
        }
        return Metadata(
            source: values["source"] ?? "Open English WordNet",
            version: values["version"] ?? "",
            license: values["license"] ?? "",
            generated: values["generated"] ?? ""
        )
    }

    /// The number of headwords in the dictionary.
    public func entryCount() throws -> Int {
        var count = 0
        try database().query("SELECT COUNT(*) FROM entries") { row in count = row.int(0) }
        return count
    }

    // MARK: - Lookup

    /// Every entry for `word` — one per part of speech, each with its senses.
    ///
    /// Matching ignores case and diacritics, so `naive` finds *naïve*.
    public func entries(for word: String) throws -> [Entry] {
        try entries(matching: WordNet.normalize(word), partOfSpeech: nil)
    }

    /// Entries for `word` restricted to one part of speech.
    public func entries(for word: String, partOfSpeech: PartOfSpeech) throws -> [Entry] {
        try entries(matching: WordNet.normalize(word), partOfSpeech: partOfSpeech)
    }

    /// Every sense of `word`, flattened across parts of speech and ordered by
    /// WordNet's familiarity ordering.
    ///
    /// This is the list to hand a model when you need it to pick which meaning
    /// applies in a sentence.
    public func senses(for word: String) throws -> [Sense] {
        try entries(for: word).flatMap(\.senses)
    }

    /// Whether the dictionary knows `word` at all.
    public func contains(_ word: String) throws -> Bool {
        var found = false
        try database().query(
            "SELECT 1 FROM entries WHERE lemma_norm = ? LIMIT 1",
            [.text(WordNet.normalize(word))]
        ) { _ in found = true }
        return found
    }

    /// Headwords beginning with `prefix`, shortest first — built for
    /// search-as-you-type.
    public func completions(forPrefix prefix: String, limit: Int = 25) throws -> [String] {
        let normalized = WordNet.normalize(prefix)
        guard !normalized.isEmpty else { return [] }

        var results: [String] = []
        try database().query(
            """
            SELECT DISTINCT lemma FROM entries
            WHERE lemma_norm >= ? AND lemma_norm < ?
            ORDER BY LENGTH(lemma), lemma_norm
            LIMIT ?
            """,
            [.text(normalized), .text(normalized + "\u{10FFFF}"), .int(limit)]
        ) { row in
            results.append(row.string(0))
        }
        return results
    }

    /// Synsets whose definitions match `query`, ranked by relevance.
    ///
    /// Use this for "what's the word for…" searches. The query is tokenised, so
    /// punctuation in the input is harmless.
    public func searchDefinitions(_ query: String, limit: Int = 25) throws -> [Synset] {
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"" }.joined(separator: " AND ")

        var synsets: [Synset] = []
        try database().query(
            """
            SELECT y.oewn_id, y.pos, y.ili, y.lexfile, y.definition
            FROM definition_fts f
            JOIN synsets y ON y.id = f.rowid
            WHERE definition_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            [.text(match), .int(limit)]
        ) { row in
            synsets.append(WordNet.synset(from: row, examples: []))
        }

        return try synsets.map { synset in
            Synset(
                id: synset.id,
                partOfSpeech: synset.partOfSpeech,
                definition: synset.definition,
                examples: try examples(forSynset: synset.id),
                lexicalFile: synset.lexicalFile,
                interlingualIndex: synset.interlingualIndex
            )
        }
    }

    // MARK: - By identifier

    public func synset(_ id: SynsetID) throws -> Synset? {
        var result: Synset?
        try database().query(
            """
            SELECT oewn_id, pos, ili, lexfile, definition
            FROM synsets WHERE oewn_id = ?
            """,
            [.text(id.rawValue)]
        ) { row in
            result = WordNet.synset(from: row, examples: [])
        }
        guard let result else { return nil }
        return Synset(
            id: result.id,
            partOfSpeech: result.partOfSpeech,
            definition: result.definition,
            examples: try examples(forSynset: result.id),
            lexicalFile: result.lexicalFile,
            interlingualIndex: result.interlingualIndex
        )
    }

    public func sense(_ id: SenseID) throws -> Sense? {
        var found: (senseID: String, lemma: String, order: Int, synsetID: String)?
        try database().query(
            """
            SELECT se.oewn_id, e.lemma, se.sense_order, y.oewn_id
            FROM senses se
            JOIN entries e ON e.id = se.entry_id
            JOIN synsets y ON y.id = se.synset_id
            WHERE se.oewn_id = ?
            """,
            [.text(id.rawValue)]
        ) { row in
            found = (row.string(0), row.string(1), row.int(2), row.string(3))
        }

        guard let found, let synset = try synset(SynsetID(found.synsetID)) else { return nil }
        return Sense(
            id: SenseID(found.senseID),
            lemma: found.lemma,
            partOfSpeech: synset.partOfSpeech,
            order: found.order,
            synset: synset
        )
    }

    // MARK: - Relations

    /// The words that share this meaning — the synset's members, which are the
    /// synonyms of any word in it.
    public func synonyms(in id: SynsetID) throws -> [String] {
        var lemmas: [String] = []
        try database().query(
            """
            SELECT DISTINCT e.lemma
            FROM synsets y
            JOIN senses se ON se.synset_id = y.id
            JOIN entries e ON e.id = se.entry_id
            WHERE y.oewn_id = ?
            ORDER BY se.sense_order
            """,
            [.text(id.rawValue)]
        ) { row in
            lemmas.append(row.string(0))
        }
        return lemmas
    }

    /// Synsets reachable from `id` by one relation, e.g. every hypernym.
    public func related(to id: SynsetID, by relation: SynsetRelation) throws -> [Synset] {
        try relations(of: id)
            .filter { $0.relation == relation }
            .map(\.synset)
    }

    /// Every synset relation leading out of `id`.
    public func relations(of id: SynsetID) throws -> [RelatedSynset] {
        var rows: [(relation: String, synset: Synset)] = []
        try database().query(
            """
            SELECT r.rel_type, t.oewn_id, t.pos, t.ili, t.lexfile, t.definition
            FROM synsets s
            JOIN synset_relations r ON r.source_id = s.id
            JOIN synsets t ON t.id = r.target_id
            WHERE s.oewn_id = ?
            """,
            [.text(id.rawValue)]
        ) { row in
            let synset = Synset(
                id: SynsetID(row.string(1)),
                partOfSpeech: PartOfSpeech(rawValue: row.string(2)) ?? .noun,
                definition: row.string(5),
                examples: [],
                lexicalFile: row.optionalString(4),
                interlingualIndex: row.optionalString(3)
            )
            rows.append((row.string(0), synset))
        }

        return rows.compactMap { row in
            guard let relation = SynsetRelation(rawValue: row.relation) else { return nil }
            return RelatedSynset(relation: relation, synset: row.synset)
        }
    }

    /// Every sense relation leading out of `id` — antonyms, derived forms, and
    /// the rest.
    public func relations(of id: SenseID) throws -> [RelatedSense] {
        var targets: [(relation: String, senseID: String)] = []
        try database().query(
            """
            SELECT r.rel_type, t.oewn_id
            FROM senses s
            JOIN sense_relations r ON r.source_id = s.id
            JOIN senses t ON t.id = r.target_id
            WHERE s.oewn_id = ?
            """,
            [.text(id.rawValue)]
        ) { row in
            targets.append((row.string(0), row.string(1)))
        }

        return try targets.compactMap { target in
            guard let relation = SenseRelation(rawValue: target.relation),
                let sense = try sense(SenseID(target.senseID))
            else { return nil }
            return RelatedSense(relation: relation, sense: sense)
        }
    }

    /// The opposites of a sense. Antonymy lives on senses, not synsets — *hot*
    /// opposes *cold* as a word pair.
    public func antonyms(of id: SenseID) throws -> [Sense] {
        try relations(of: id).filter { $0.relation == .antonym }.map(\.sense)
    }

    // MARK: - Browsing

    /// A random entry that has at least one sense. Useful for word of the day.
    public func randomEntry(partOfSpeech: PartOfSpeech? = nil) throws -> Entry? {
        var maximum = 0
        try database().query("SELECT MAX(id) FROM entries") { row in maximum = row.int(0) }
        guard maximum > 0 else { return nil }

        for _ in 0..<8 {
            let start = Int.random(in: 1...maximum)
            var candidate: (rowID: Int, id: String, lemma: String, pos: String)?

            let sql =
                partOfSpeech == nil
                ? "SELECT id, oewn_id, lemma, pos FROM entries WHERE id >= ? ORDER BY id LIMIT 1"
                : "SELECT id, oewn_id, lemma, pos FROM entries WHERE id >= ? AND pos = ? ORDER BY id LIMIT 1"
            var bindings: [Connection.Binding] = [.int(start)]
            if let partOfSpeech { bindings.append(.text(partOfSpeech.rawValue)) }

            try database().query(sql, bindings) { row in
                candidate = (row.int(0), row.string(1), row.string(2), row.string(3))
            }

            guard let candidate else { continue }
            let entry = try buildEntry(
                rowID: candidate.rowID,
                id: candidate.id,
                lemma: candidate.lemma,
                pos: candidate.pos
            )
            if !entry.senses.isEmpty { return entry }
        }
        return nil
    }

    // MARK: - Building

    private func entries(matching normalized: String, partOfSpeech: PartOfSpeech?) throws
        -> [Entry]
    {
        guard !normalized.isEmpty else { return [] }

        var rows: [(rowID: Int, id: String, lemma: String, pos: String)] = []
        let sql =
            partOfSpeech == nil
            ? "SELECT id, oewn_id, lemma, pos FROM entries WHERE lemma_norm = ? ORDER BY pos"
            : "SELECT id, oewn_id, lemma, pos FROM entries WHERE lemma_norm = ? AND pos = ?"
        var bindings: [Connection.Binding] = [.text(normalized)]
        if let partOfSpeech { bindings.append(.text(partOfSpeech.rawValue)) }

        try database().query(sql, bindings) { row in
            rows.append((row.int(0), row.string(1), row.string(2), row.string(3)))
        }

        return try rows.map {
            try buildEntry(rowID: $0.rowID, id: $0.id, lemma: $0.lemma, pos: $0.pos)
        }
    }

    private func buildEntry(rowID: Int, id: String, lemma: String, pos: String) throws -> Entry {
        var pronunciations: [Pronunciation] = []
        try database().query(
            "SELECT ipa, variety FROM pronunciations WHERE entry_id = ?",
            [.int(rowID)]
        ) { row in
            pronunciations.append(
                Pronunciation(ipa: row.string(0), variety: row.optionalString(1))
            )
        }

        // Examples for every synset of this entry, fetched in one pass and then
        // grouped, rather than one query per sense.
        var examplesBySynset: [String: [String]] = [:]
        try database().query(
            """
            SELECT y.oewn_id, x.text
            FROM senses se
            JOIN synsets y ON y.id = se.synset_id
            JOIN examples x ON x.synset_id = y.id
            WHERE se.entry_id = ?
            ORDER BY x.ordinal
            """,
            [.int(rowID)]
        ) { row in
            examplesBySynset[row.string(0), default: []].append(row.string(1))
        }

        var senses: [Sense] = []
        try database().query(
            """
            SELECT se.oewn_id, se.sense_order, y.oewn_id, y.pos, y.ili, y.lexfile, y.definition
            FROM senses se
            JOIN synsets y ON y.id = se.synset_id
            WHERE se.entry_id = ?
            ORDER BY se.sense_order
            """,
            [.int(rowID)]
        ) { row in
            let synsetID = row.string(2)
            let synset = Synset(
                id: SynsetID(synsetID),
                partOfSpeech: PartOfSpeech(rawValue: row.string(3)) ?? .noun,
                definition: row.string(6),
                examples: examplesBySynset[synsetID] ?? [],
                lexicalFile: row.optionalString(5),
                interlingualIndex: row.optionalString(4)
            )
            senses.append(
                Sense(
                    id: SenseID(row.string(0)),
                    lemma: lemma,
                    partOfSpeech: synset.partOfSpeech,
                    order: row.int(1),
                    synset: synset
                )
            )
        }

        return Entry(
            id: id,
            lemma: lemma,
            partOfSpeech: PartOfSpeech(rawValue: pos) ?? .noun,
            pronunciations: pronunciations,
            senses: senses
        )
    }

    private func examples(forSynset id: SynsetID) throws -> [String] {
        var results: [String] = []
        try database().query(
            """
            SELECT x.text FROM examples x
            JOIN synsets y ON y.id = x.synset_id
            WHERE y.oewn_id = ? ORDER BY x.ordinal
            """,
            [.text(id.rawValue)]
        ) { row in
            results.append(row.string(0))
        }
        return results
    }

    private static func synset(from row: Connection.Row, examples: [String]) -> Synset {
        Synset(
            id: SynsetID(row.string(0)),
            partOfSpeech: PartOfSpeech(rawValue: row.string(1)) ?? .noun,
            definition: row.string(4),
            examples: examples,
            lexicalFile: row.optionalString(3),
            interlingualIndex: row.optionalString(2)
        )
    }

    /// Mirrors the normalisation applied when the database was built: case and
    /// diacritics folded away.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
