import Foundation

// MARK: - Identifiers

/// A stable identifier for a synset, e.g. `oewn-02086723-n`.
///
/// Identifiers come from the Open English WordNet release and are stable across
/// rebuilds of the bundled database, so they are safe to persist.
public struct SynsetID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

/// A stable identifier for a sense — one word in one meaning.
public struct SenseID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

// MARK: - Part of speech

public enum PartOfSpeech: String, Hashable, Sendable, Codable, CaseIterable {
    case noun = "n"
    case verb = "v"
    case adjective = "a"
    case adverb = "r"
    /// An adjective that has no direct antonym and is defined by similarity to
    /// a head adjective — WordNet models these separately.
    case adjectiveSatellite = "s"

    public var displayName: String {
        switch self {
        case .noun: "noun"
        case .verb: "verb"
        case .adjective, .adjectiveSatellite: "adjective"
        case .adverb: "adverb"
        }
    }

    /// The conventional dictionary abbreviation.
    public var abbreviation: String {
        switch self {
        case .noun: "n."
        case .verb: "v."
        case .adjective, .adjectiveSatellite: "adj."
        case .adverb: "adv."
        }
    }
}

// MARK: - Values

public struct Pronunciation: Hashable, Sendable, Codable {
    /// IPA, without surrounding slashes.
    public let ipa: String
    /// `US`, `GB`, and similar. `nil` when the release does not say.
    public let variety: String?

    public init(ipa: String, variety: String? = nil) {
        self.ipa = ipa
        self.variety = variety
    }
}

/// A set of synonyms sharing one meaning, with the definition attached to it.
public struct Synset: Hashable, Sendable, Codable, Identifiable {
    public let id: SynsetID
    public let partOfSpeech: PartOfSpeech
    public let definition: String
    public let examples: [String]
    /// WordNet's lexicographer file, e.g. `noun.animal` — a coarse semantic category.
    public let lexicalFile: String?
    /// Interlingual index identifier, for aligning with wordnets in other languages.
    public let interlingualIndex: String?

    public init(
        id: SynsetID,
        partOfSpeech: PartOfSpeech,
        definition: String,
        examples: [String] = [],
        lexicalFile: String? = nil,
        interlingualIndex: String? = nil
    ) {
        self.id = id
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.examples = examples
        self.lexicalFile = lexicalFile
        self.interlingualIndex = interlingualIndex
    }
}

/// One word used in one meaning. This is the unit to persist when you want to
/// record *which* meaning of a word someone meant.
public struct Sense: Hashable, Sendable, Codable, Identifiable {
    public let id: SenseID
    public let lemma: String
    public let partOfSpeech: PartOfSpeech
    /// Position within the entry. WordNet orders senses roughly by familiarity,
    /// so sense 0 is usually the one people mean.
    public let order: Int
    public let synset: Synset

    public var definition: String { synset.definition }
    public var examples: [String] { synset.examples }

    public init(
        id: SenseID,
        lemma: String,
        partOfSpeech: PartOfSpeech,
        order: Int,
        synset: Synset
    ) {
        self.id = id
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.order = order
        self.synset = synset
    }
}

/// One headword in one part of speech, with all of its senses.
///
/// A word like *bank* produces several entries — one per part of speech — each
/// carrying its own senses.
public struct Entry: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let lemma: String
    public let partOfSpeech: PartOfSpeech
    public let pronunciations: [Pronunciation]
    public let senses: [Sense]

    public init(
        id: String,
        lemma: String,
        partOfSpeech: PartOfSpeech,
        pronunciations: [Pronunciation] = [],
        senses: [Sense] = []
    ) {
        self.id = id
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.pronunciations = pronunciations
        self.senses = senses
    }
}

// MARK: - Relations

/// Relations that hold between synsets.
public enum SynsetRelation: String, Hashable, Sendable, Codable, CaseIterable {
    /// A more general concept: *dog* → *canine*.
    case hypernym
    /// A more specific concept: *dog* → *puppy*.
    case hyponym
    case instanceHypernym = "instance_hypernym"
    case instanceHyponym = "instance_hyponym"
    /// Part of: *wheel* → *car*.
    case partHolonym = "holo_part"
    /// Has part: *car* → *wheel*.
    case partMeronym = "mero_part"
    case memberHolonym = "holo_member"
    case memberMeronym = "mero_member"
    case substanceHolonym = "holo_substance"
    case substanceMeronym = "mero_substance"
    case similar
    case also
    case attribute
    case entails
    case isEntailedBy = "is_entailed_by"
    case causes
    case isCausedBy = "is_caused_by"
    case domainTopic = "domain_topic"
    case hasDomainTopic = "has_domain_topic"
    case domainRegion = "domain_region"
    case hasDomainRegion = "has_domain_region"
    case exemplifies
    case isExemplifiedBy = "is_exemplified_by"

    public var displayName: String {
        switch self {
        case .hypernym, .instanceHypernym: "More general"
        case .hyponym, .instanceHyponym: "More specific"
        case .partHolonym, .memberHolonym, .substanceHolonym: "Part of"
        case .partMeronym, .memberMeronym, .substanceMeronym: "Has part"
        case .similar: "Similar"
        case .also: "See also"
        case .attribute: "Attribute"
        case .entails, .isEntailedBy: "Entails"
        case .causes, .isCausedBy: "Causes"
        case .domainTopic, .hasDomainTopic: "Topic"
        case .domainRegion, .hasDomainRegion: "Region"
        case .exemplifies, .isExemplifiedBy: "Example of"
        }
    }
}

/// Relations that hold between senses rather than whole synsets. Antonymy is
/// the important one: *hot* is the antonym of *cold* as a word pair, not as a
/// pair of meanings.
public enum SenseRelation: String, Hashable, Sendable, Codable, CaseIterable {
    case antonym
    case derivation
    case pertainym
    case participle
    case similar
    case also
    case exemplifies
    case isExemplifiedBy = "is_exemplified_by"
    case other

    public var displayName: String {
        switch self {
        case .antonym: "Opposite"
        case .derivation: "Related form"
        case .pertainym: "Pertains to"
        case .participle: "Participle of"
        case .similar: "Similar"
        case .also: "See also"
        case .exemplifies, .isExemplifiedBy: "Example of"
        case .other: "Related"
        }
    }
}

/// A synset reached from another synset, with the relation that led there.
public struct RelatedSynset: Hashable, Sendable, Codable {
    public let relation: SynsetRelation
    public let synset: Synset

    public init(relation: SynsetRelation, synset: Synset) {
        self.relation = relation
        self.synset = synset
    }
}

/// A sense reached from another sense, with the relation that led there.
public struct RelatedSense: Hashable, Sendable, Codable {
    public let relation: SenseRelation
    public let sense: Sense

    public init(relation: SenseRelation, sense: Sense) {
        self.relation = relation
        self.sense = sense
    }
}

// MARK: - Metadata

/// Provenance of the bundled data. `attribution` is the credit line the
/// CC BY 4.0 licence requires you to display somewhere in your app.
public struct Metadata: Hashable, Sendable, Codable {
    public let source: String
    public let version: String
    public let license: String
    public let generated: String

    public var attribution: String {
        "\(source) \(version), licensed under CC BY 4.0"
    }
}
