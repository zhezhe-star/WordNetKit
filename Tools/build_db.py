#!/usr/bin/env python3
"""Convert an Open English WordNet WN-LMF XML release into the SQLite database
bundled by WordNetKit.

    python3 build_db.py data/oewn2025.xml ../Sources/WordNetKit/Resources/wordnet.sqlite

The XML is parsed with a streaming parser so peak memory stays flat.
"""

import argparse
import os
import sqlite3
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

SCHEMA = """
PRAGMA page_size = 4096;

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE entries (
    id         INTEGER PRIMARY KEY,
    oewn_id    TEXT NOT NULL,
    lemma      TEXT NOT NULL,
    lemma_norm TEXT NOT NULL,
    pos        TEXT NOT NULL
);

CREATE TABLE pronunciations (
    entry_id INTEGER NOT NULL,
    variety  TEXT,
    ipa      TEXT NOT NULL
);

CREATE TABLE synsets (
    id         INTEGER PRIMARY KEY,
    oewn_id    TEXT NOT NULL,
    pos        TEXT NOT NULL,
    ili        TEXT,
    lexfile    TEXT,
    definition TEXT NOT NULL DEFAULT ''
);

CREATE TABLE examples (
    synset_id INTEGER NOT NULL,
    ordinal   INTEGER NOT NULL,
    text      TEXT NOT NULL
);

CREATE TABLE senses (
    id          INTEGER PRIMARY KEY,
    oewn_id     TEXT NOT NULL,
    entry_id    INTEGER NOT NULL,
    synset_id   INTEGER NOT NULL,
    sense_order INTEGER NOT NULL
);

CREATE TABLE synset_relations (
    source_id INTEGER NOT NULL,
    rel_type  TEXT NOT NULL,
    target_id INTEGER NOT NULL
);

CREATE TABLE sense_relations (
    source_id INTEGER NOT NULL,
    rel_type  TEXT NOT NULL,
    target_id INTEGER NOT NULL
);
"""

INDEXES = """
CREATE INDEX        idx_entries_norm   ON entries(lemma_norm);
CREATE INDEX        idx_pron_entry     ON pronunciations(entry_id);
CREATE UNIQUE INDEX idx_synsets_oewn   ON synsets(oewn_id);
CREATE INDEX        idx_examples_syn   ON examples(synset_id, ordinal);
CREATE UNIQUE INDEX idx_senses_oewn    ON senses(oewn_id);
CREATE INDEX        idx_senses_entry   ON senses(entry_id, sense_order);
CREATE INDEX        idx_senses_synset  ON senses(synset_id);
CREATE INDEX        idx_synrel_source  ON synset_relations(source_id, rel_type);
CREATE INDEX        idx_senserel_src   ON sense_relations(source_id, rel_type);

-- External-content FTS: the index points back at synsets rather than storing a
-- second copy of every definition.
CREATE VIRTUAL TABLE definition_fts USING fts5(
    definition,
    content = 'synsets',
    content_rowid = 'id',
    tokenize = 'porter unicode61 remove_diacritics 2'
);
INSERT INTO definition_fts(rowid, definition)
    SELECT id, definition FROM synsets WHERE definition <> '';
"""

# Combining marks are stripped so "naive" matches "naïve".
import unicodedata


def normalize(lemma: str) -> str:
    decomposed = unicodedata.normalize("NFD", lemma.casefold())
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return unicodedata.normalize("NFC", stripped)


def tag(element) -> str:
    """Local name, ignoring any namespace."""
    return element.tag.rsplit("}", 1)[-1]


def build(xml_path: str, db_path: str) -> None:
    if os.path.exists(db_path):
        os.remove(db_path)
    os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)

    db = sqlite3.connect(db_path)
    db.executescript(SCHEMA)

    entry_ids: dict[str, int] = {}
    synset_ids: dict[str, int] = {}
    sense_ids: dict[str, int] = {}

    # Relations reference targets that may not have been read yet, so they are
    # buffered as strings and resolved once every id is known.
    pending_synset_relations: list[tuple[int, str, str]] = []
    pending_sense_relations: list[tuple[int, str, str]] = []

    lexicon_version = ""
    lexicon_license = ""
    lexicon_label = ""

    next_entry = 0
    next_synset = 0
    next_sense = 0

    context = ET.iterparse(xml_path, events=("start", "end"))
    for event, element in context:
        name = tag(element)

        if event == "start" and name == "Lexicon":
            lexicon_version = element.get("version", "")
            lexicon_license = element.get("license", "")
            lexicon_label = element.get("label", "")
            continue

        if event != "end":
            continue

        if name == "LexicalEntry":
            lemma_el = element.find("Lemma")
            if lemma_el is None:
                element.clear()
                continue

            oewn_id = element.get("id")
            lemma = lemma_el.get("writtenForm", "")
            pos = lemma_el.get("partOfSpeech", "")

            next_entry += 1
            entry_id = next_entry
            entry_ids[oewn_id] = entry_id
            db.execute(
                "INSERT INTO entries (id, oewn_id, lemma, lemma_norm, pos) VALUES (?,?,?,?,?)",
                (entry_id, oewn_id, lemma, normalize(lemma), pos),
            )

            for pron in lemma_el.findall("Pronunciation"):
                if pron.text:
                    db.execute(
                        "INSERT INTO pronunciations (entry_id, variety, ipa) VALUES (?,?,?)",
                        (entry_id, pron.get("variety"), pron.text),
                    )

            for order, sense_el in enumerate(element.findall("Sense")):
                sense_oewn = sense_el.get("id")
                next_sense += 1
                sense_id = next_sense
                sense_ids[sense_oewn] = sense_id
                db.execute(
                    "INSERT INTO senses (id, oewn_id, entry_id, synset_id, sense_order)"
                    " VALUES (?,?,?,?,?)",
                    (sense_id, sense_oewn, entry_id, 0, order),
                )
                # synset_id is patched below, once synsets are known.
                db.execute(
                    "UPDATE senses SET synset_id = -1 WHERE id = ?", (sense_id,)
                )
                pending_sense_relations.append(
                    (sense_id, "@synset", sense_el.get("synset"))
                )
                for rel in sense_el.findall("SenseRelation"):
                    pending_sense_relations.append(
                        (sense_id, rel.get("relType"), rel.get("target"))
                    )

            element.clear()

        elif name == "Synset":
            oewn_id = element.get("id")
            next_synset += 1
            synset_id = next_synset
            synset_ids[oewn_id] = synset_id

            definition_el = element.find("Definition")
            definition = (definition_el.text or "") if definition_el is not None else ""

            db.execute(
                "INSERT INTO synsets (id, oewn_id, pos, ili, lexfile, definition)"
                " VALUES (?,?,?,?,?,?)",
                (
                    synset_id,
                    oewn_id,
                    element.get("partOfSpeech", ""),
                    element.get("ili") or None,
                    element.get("lexfile") or None,
                    definition.strip(),
                ),
            )

            for ordinal, example in enumerate(element.findall("Example")):
                if example.text:
                    db.execute(
                        "INSERT INTO examples (synset_id, ordinal, text) VALUES (?,?,?)",
                        (synset_id, ordinal, example.text.strip()),
                    )

            for rel in element.findall("SynsetRelation"):
                pending_synset_relations.append(
                    (synset_id, rel.get("relType"), rel.get("target"))
                )

            element.clear()

    db.commit()
    print(f"  entries {next_entry}  synsets {next_synset}  senses {next_sense}")

    # Resolve senses -> synsets, then the relation tables.
    resolved_senses = 0
    for sense_id, kind, target in pending_sense_relations:
        if kind != "@synset":
            continue
        target_id = synset_ids.get(target)
        if target_id is not None:
            db.execute(
                "UPDATE senses SET synset_id = ? WHERE id = ?", (target_id, sense_id)
            )
            resolved_senses += 1
    db.execute("DELETE FROM senses WHERE synset_id <= 0")
    db.commit()
    print(f"  senses linked to synsets: {resolved_senses}")

    synset_rows = [
        (source, kind, synset_ids[target])
        for source, kind, target in pending_synset_relations
        if target in synset_ids
    ]
    db.executemany(
        "INSERT INTO synset_relations (source_id, rel_type, target_id) VALUES (?,?,?)",
        synset_rows,
    )

    sense_rows = [
        (source, kind, sense_ids[target])
        for source, kind, target in pending_sense_relations
        if kind != "@synset" and target in sense_ids
    ]
    db.executemany(
        "INSERT INTO sense_relations (source_id, rel_type, target_id) VALUES (?,?,?)",
        sense_rows,
    )
    db.commit()
    print(f"  synset relations {len(synset_rows)}  sense relations {len(sense_rows)}")

    db.executescript(INDEXES)

    db.executemany(
        "INSERT INTO meta (key, value) VALUES (?,?)",
        [
            ("source", lexicon_label or "Open English WordNet"),
            ("version", lexicon_version),
            ("license", lexicon_license),
            ("schema_version", "1"),
            ("generated", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
        ],
    )
    db.commit()

    db.execute("PRAGMA journal_mode = DELETE")
    db.execute("VACUUM")
    db.execute("ANALYZE")
    db.commit()
    db.close()

    size_mb = os.path.getsize(db_path) / 1_048_576
    print(f"  wrote {db_path} ({size_mb:.1f} MB)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xml", help="path to the WN-LMF XML release")
    parser.add_argument("out", help="path of the SQLite file to write")
    args = parser.parse_args()

    if not os.path.exists(args.xml):
        print(f"no such file: {args.xml}", file=sys.stderr)
        return 1

    print(f"building {args.out} from {args.xml}")
    build(args.xml, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
