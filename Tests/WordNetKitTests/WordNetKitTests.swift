import Foundation
import Testing

@testable import WordNetKit

@Suite("WordNetKit")
struct WordNetKitTests {
    let wordnet = WordNet()

    @Test("The bundled database opens and reports its provenance")
    func metadata() async throws {
        let metadata = try await wordnet.metadata()
        #expect(metadata.source.localizedCaseInsensitiveContains("wordnet"))
        #expect(metadata.version == "2025")
        #expect(metadata.license.contains("creativecommons.org"))
        #expect(metadata.attribution.contains("CC BY 4.0"))
    }

    @Test("The dictionary holds the whole of Open English WordNet")
    func entryCount() async throws {
        #expect(try await wordnet.entryCount() > 130_000)
    }

    @Test("A word resolves to its definition")
    func lookup() async throws {
        let senses = try await wordnet.senses(for: "susurrus")
        #expect(senses.count == 1)
        #expect(senses.first?.definition == "the indistinct sound of people whispering")
        #expect(senses.first?.partOfSpeech == .noun)
    }

    @Test("A word with several parts of speech returns one entry for each")
    func partsOfSpeech() async throws {
        let entries = try await wordnet.entries(for: "run")
        let partsOfSpeech = Set(entries.map(\.partOfSpeech))
        #expect(partsOfSpeech.contains(.noun))
        #expect(partsOfSpeech.contains(.verb))

        let verbsOnly = try await wordnet.entries(for: "run", partOfSpeech: .verb)
        #expect(verbsOnly.allSatisfy { $0.partOfSpeech == .verb })
        #expect(verbsOnly.first.map { $0.senses.count > 20 } == true)
    }

    @Test("Senses come back in WordNet's familiarity order")
    func senseOrdering() async throws {
        let senses = try await wordnet.senses(for: "dog")
        #expect(senses.first?.order == 0)
        #expect(senses.first?.definition.contains("Canis") == true)
    }

    @Test("Lookup ignores case and diacritics")
    func folding() async throws {
        #expect(try await wordnet.contains("NAIVE"))
        #expect(try await wordnet.contains("naïve"))
        #expect(try await wordnet.contains("Dog"))
        #expect(try await !wordnet.contains("zzzzznotaword"))
    }

    @Test("Prefix completion returns shortest matches first")
    func completions() async throws {
        let words = try await wordnet.completions(forPrefix: "susu", limit: 10)
        #expect(!words.isEmpty)
        #expect(words.contains("susurrus"))
        let lengths = words.map(\.count)
        #expect(lengths == lengths.sorted())
    }

    @Test("Empty prefixes return nothing rather than everything")
    func emptyPrefix() async throws {
        #expect(try await wordnet.completions(forPrefix: "").isEmpty)
        #expect(try await wordnet.completions(forPrefix: "   ").isEmpty)
    }

    @Test("Definitions are searchable as full text")
    func definitionSearch() async throws {
        let synsets = try await wordnet.searchDefinitions("people whispering", limit: 10)
        #expect(synsets.contains { $0.definition.contains("whispering") })
    }

    @Test("Punctuation in a definition search is harmless")
    func definitionSearchSanitises() async throws {
        let synsets = try await wordnet.searchDefinitions("\"whisper* AND (", limit: 5)
        #expect(!synsets.isEmpty)
    }

    @Test("Synsets carry usage examples")
    func examples() async throws {
        let senses = try await wordnet.senses(for: "able")
        let withExamples = senses.first { !$0.examples.isEmpty }
        #expect(withExamples != nil)
    }

    @Test("Pronunciations are included where the release has them")
    func pronunciations() async throws {
        let entries = try await wordnet.entries(for: "zero")
        let pronunciations = entries.flatMap(\.pronunciations)
        #expect(!pronunciations.isEmpty)
        #expect(pronunciations.contains { $0.variety == "US" })
    }

    @Test("Hypernyms walk up the taxonomy")
    func hypernyms() async throws {
        let senses = try await wordnet.senses(for: "dog")
        let synsetID = try #require(senses.first?.synset.id)
        let hypernyms = try await wordnet.related(to: synsetID, by: .hypernym)
        #expect(!hypernyms.isEmpty)

        let members = try await withThrowingTaskGroup(of: [String].self) { group -> [String] in
            for hypernym in hypernyms {
                group.addTask { try await self.wordnet.synonyms(in: hypernym.id) }
            }
            var all: [String] = []
            for try await lemmas in group { all.append(contentsOf: lemmas) }
            return all
        }
        #expect(members.contains { $0 == "canine" || $0 == "domestic animal" })
    }

    @Test("Synonyms come from synset membership")
    func synonyms() async throws {
        let senses = try await wordnet.senses(for: "car")
        let synsetID = try #require(senses.first?.synset.id)
        let synonyms = try await wordnet.synonyms(in: synsetID)
        #expect(synonyms.contains("automobile"))
    }

    @Test("Antonyms are sense-level relations")
    func antonyms() async throws {
        let senses = try await wordnet.senses(for: "hot")
        var opposites: [String] = []
        for sense in senses {
            opposites += try await wordnet.antonyms(of: sense.id).map(\.lemma)
        }
        #expect(opposites.contains("cold"))
    }

    @Test("Identifiers round-trip, so they are safe to persist")
    func identifierRoundTrip() async throws {
        let original = try #require(try await wordnet.senses(for: "susurrus").first)

        let recoveredSense = try await wordnet.sense(original.id)
        #expect(recoveredSense == original)

        let recoveredSynset = try await wordnet.synset(original.synset.id)
        #expect(recoveredSynset == original.synset)
    }

    @Test("Unknown identifiers return nil rather than throwing")
    func unknownIdentifiers() async throws {
        #expect(try await wordnet.synset("oewn-99999999-n") == nil)
        #expect(try await wordnet.sense("oewn-not__a__sense") == nil)
        #expect(try await wordnet.senses(for: "zzzzznotaword").isEmpty)
    }

    @Test("Random entries always have at least one sense")
    func randomEntry() async throws {
        for _ in 0..<10 {
            let entry = try #require(try await wordnet.randomEntry())
            #expect(!entry.senses.isEmpty)
        }
        let verb = try #require(try await wordnet.randomEntry(partOfSpeech: .verb))
        #expect(verb.partOfSpeech == .verb)
    }

    @Test("Models encode and decode")
    func codable() async throws {
        let sense = try #require(try await wordnet.senses(for: "susurrus").first)
        let data = try JSONEncoder().encode(sense)
        #expect(try JSONDecoder().decode(Sense.self, from: data) == sense)
    }

    @Test("Concurrent lookups from many tasks are safe")
    func concurrentAccess() async throws {
        let words = ["dog", "run", "book", "leaf", "sheaf", "keep", "word", "read"]
        let found = try await withThrowingTaskGroup(of: Int.self) { group -> Int in
            for word in words {
                for _ in 0..<8 {
                    group.addTask { try await self.wordnet.senses(for: word).count }
                }
            }
            var total = 0
            for try await count in group { total += count }
            return total
        }
        #expect(found > 0)
    }
}
