# WordNetKit

An offline English dictionary and thesaurus for Apple platforms, packaged as a Swift library.

The whole of [Open English WordNet](https://github.com/globalwordnet/english-wordnet) 2025 ships
inside the module — 136,000 headwords, 107,000 meanings, 185,000 senses, with definitions, usage
examples, IPA pronunciations, synonyms, antonyms and the full semantic graph. No network, no API
key, no account, no first-launch download.

```swift
import WordNetKit

let senses = try await WordNet.shared.senses(for: "susurrus")
print(senses.first?.definition ?? "")
// the indistinct sound of people whispering
```

## Requirements

iOS 17 · macOS 14 · tvOS 17 · watchOS 10 · visionOS 1 · Swift 6

## Installation

```swift
.package(url: "https://github.com/acorscadden/WordNetKit.git", from: "1.0.0")
```

The bundled database adds about 66 MB to your app before App Store thinning and compression.

## Using it

`WordNet` is an actor, so it is safe to call from anywhere. Use the shared instance, or make your
own if you would rather manage the lifetime yourself.

### Looking up a word

```swift
let entries = try await WordNet.shared.entries(for: "bank")
for entry in entries {
    print(entry.lemma, entry.partOfSpeech.abbreviation)
    for sense in entry.senses {
        print("  \(sense.order + 1). \(sense.definition)")
        for example in sense.examples { print("     — \(example)") }
    }
}
```

One `Entry` comes back per part of speech. `senses(for:)` flattens them when you just want the
meanings in familiarity order.

Matching folds case and diacritics, so `NAIVE` and `naïve` both find *naïve*.

### Search as you type

```swift
let words = try await WordNet.shared.completions(forPrefix: "susu", limit: 10)
// ["susurrus", "susurration", …]
```

Shortest matches come first. Queries run in well under a millisecond, so you can call this straight
from `onChange` without debouncing.

### Searching definitions

```swift
let synsets = try await WordNet.shared.searchDefinitions("sound of people whispering")
```

Full-text search over every definition, ranked by relevance — for when you know the meaning but not
the word. Punctuation in the query is ignored, so you can pass raw user input.

### Walking the semantic graph

```swift
let sense = try await WordNet.shared.senses(for: "dog").first!

let broader = try await WordNet.shared.related(to: sense.synset.id, by: .hypernym)
let narrower = try await WordNet.shared.related(to: sense.synset.id, by: .hyponym)
let synonyms = try await WordNet.shared.synonyms(in: sense.synset.id)
let opposites = try await WordNet.shared.antonyms(of: sense.id)

// Or everything at once, grouped for display:
let related = try await WordNet.shared.relations(of: sense.synset.id)
let grouped = Dictionary(grouping: related, by: \.relation)
```

Antonymy is a relation between *senses*, not synsets — *hot* opposes *cold* as a word pair — which
is why `antonyms(of:)` takes a `SenseID`.

### Persisting a meaning

`SynsetID` and `SenseID` are stable across releases of this package, so you can store them to record
which meaning of a word someone meant, and resolve them later:

```swift
let stored = sense.id                       // e.g. "oewn-dog__1.05.00.."
let restored = try await WordNet.shared.sense(stored)
```

Both are `Codable`, `Hashable` and `Sendable`, as is every model type.

### Word of the day

```swift
let entry = try await WordNet.shared.randomEntry(partOfSpeech: .adjective)
```

Only returns entries that actually have senses.

## Attribution is required

The data is Open English WordNet, licensed **CC BY 4.0**, which obliges you to credit it. The
package hands you the line to display:

```swift
let metadata = try await WordNet.shared.metadata()
print(metadata.attribution)
// Open English Wordnet 2025, licensed under CC BY 4.0
```

Put it in your about screen, settings, or acknowledgements. The library code itself is MIT.

## Rebuilding the database

The SQLite file is generated from an official WordNet release and committed to the repository, so
consumers never build anything. To regenerate it:

```bash
cd Tools
curl -L -o data/oewn2025.xml.gz \
  https://github.com/globalwordnet/english-wordnet/releases/download/2025-edition/english-wordnet-2025.xml.gz
gunzip -k data/oewn2025.xml.gz
python3 build_db.py data/oewn2025.xml ../Sources/WordNetKit/Resources/wordnet.sqlite
```

`build_db.py` needs only the Python standard library. It streams the 85 MB XML, so memory stays
flat, and finishes in a few seconds.

The schema is deliberately plain — `entries`, `senses`, `synsets`, `examples`, `pronunciations`,
two relation tables, and an external-content FTS5 index over definitions. Open it with any SQLite
browser if you want to poke around.

## Design notes

- **Read-only, single connection, inside an actor.** SQLite is opened with `SQLITE_OPEN_READONLY`
  and `SQLITE_OPEN_NOMUTEX`; the actor provides the serialisation instead of SQLite's own mutex.
- **Prepared statements are cached** by SQL text, so repeated lookups skip re-parsing.
- **No dependencies.** Not even a SQLite wrapper — the package talks to the system `sqlite3`
  directly, so there is nothing to keep in step with your app's other packages.
- **Adjective satellites** are preserved as `.adjectiveSatellite` rather than being folded into
  `.adjective`, because WordNet's structure depends on them. `displayName` presents both as
  "adjective".

## Licence

MIT for the code. See `NOTICE` for the data licence and attribution requirement.
