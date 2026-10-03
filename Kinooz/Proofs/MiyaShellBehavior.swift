// Copyright 2026 Kinooz.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI
import Security
import SQLite3

@main struct MiyaShellBehavior {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.json")
        let initial = MiyaNotesStore(fileURL: file)
        precondition(initial.notes.count == 6 && initial.storageError == nil)
        let note = MiyaNote(title: "Eigen notitie", body: "Blijft na herstart bestaan")
        initial.update(note)
        let restored = MiyaNotesStore(fileURL: file)
        precondition(restored.notes.first == note)
        try Data("kapot".utf8).write(to: file)
        let corrupt = MiyaNotesStore(fileURL: file)
        corrupt.update(note)
        precondition(corrupt.storageError != nil)
        let preserved = try String(contentsOf: file, encoding: .utf8)
        precondition(preserved == "kapot")

        // A phrase removal must not get around that refusal. This store loaded no notes, so any sanitised
        // note is new to it, but a note that would normally be written still has to reach update(_:),
        // where blocksSaving stops it. The unreadable file must survive the attempt unchanged.
        corrupt.updateAfterPhraseRemoval(MiyaNote(title: "Nieuwe titel", body: ""))
        precondition(corrupt.storageError != nil)
        let afterRefusedRemoval = try String(contentsOf: file, encoding: .utf8)
        precondition(afterRefusedRemoval == "kapot", "a phrase removal must not overwrite an unreadable notes.json")

        try proveLegacyMigration(in: folder)
        try proveWriteFailureRecovery(in: folder)

        let service = "nl.kinooz.miya.proof.\(UUID().uuidString)"
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
        let phrase = MiyaPhraseStore(service: service)
        precondition(!phrase.isConfigured)
        do { try phrase.set("        "); preconditionFailure("whitespace-only phrase accepted") } catch {}
        try phrase.set("  persoonlijke testzin  ")
        precondition(phrase.isConfigured)
        precondition(phrase.removingTrigger(from: "Vooraf\npersoonlijke testzin\nAchteraf") == "Vooraf\n\nAchteraf")
        precondition(phrase.removingTrigger(from: "persoonlijke testzin") == "")
        precondition(phrase.removingTrigger(from: "persoonlijke testzi") == nil)
        precondition(phrase.removingTrigger(from: "Tekst persoonlijke testzin") == nil)
        // The normalised (trimmed) form of the codephrase set above: the plaintext that must not survive.
        try provePhraseRemovalPersistence(in: folder, phraseStore: phrase, codephrase: "persoonlijke testzin")
        print("PASS: seeded notes, restart persistence, corrupt-file preservation (also against a phrase removal), secure phrase, immediate trigger sanitation, partial/wrong-line rejection, phrase-removal persistence (title and other body kept, phrase-only note emptied and kept, fresh empty note adds no row, no plaintext codephrase in notes.json), transient write-failure recovery")
    }

    @MainActor static func proveLegacyMigration(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appending(path: "miya_notities.sqlite")
        var db: OpaquePointer?
        precondition(sqlite3_open(source.path, &db) == SQLITE_OK)
        // Schema v1 (no folder/daily_key columns, no folders table), in WAL mode with an uncheckpointed row.
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0",
                    "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
                    "INSERT INTO notes (title,body,created_at,updated_at) VALUES ('Oud','Bestaande tekst',1,2)"] {
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        let before = try Data(contentsOf: source)
        let target = folder.appending(path: "migrated/notes.json")
        let migrated = MiyaNotesStore(fileURL: target, legacyURL: source)
        precondition(migrated.storageError == nil && migrated.notes.count == 1)
        precondition(migrated.notes[0].title == "Oud" && migrated.notes[0].body == "Bestaande tekst" && migrated.notes[0].folder == "")
        precondition(migrated.notes[0].legacyID == 1 && migrated.notes[0].updatedAt == 2)
        let after = try Data(contentsOf: source)
        precondition(after == before, "source database must stay untouched")
        // Second launch reads the JSON, never re-imports.
        precondition(MiyaNotesStore(fileURL: target, legacyURL: source).notes == migrated.notes)
        sqlite3_close(db)

        let broken = folder.appending(path: "broken.sqlite")
        try Data("geen database".utf8).write(to: broken)
        let failed = MiyaNotesStore(fileURL: folder.appending(path: "failed/notes.json"), legacyURL: broken)
        precondition(failed.storageError != nil && failed.notes.isEmpty)
        let brokenText = try String(contentsOf: broken, encoding: .utf8)
        precondition(brokenText == "geen database")
        precondition(!FileManager.default.fileExists(atPath: folder.appending(path: "failed/notes.json").path))
    }

    /// The three shapes `updateAfterPhraseRemoval(_:)` has to tell apart, driven through the real phrase
    /// store so the sanitised text is produced exactly as the shell produces it. notes.json is re-read as
    /// text after every write: it must not keep the plaintext codephrase in any of the three cases.
    @MainActor static func provePhraseRemovalPersistence(in folder: URL,
                                                        phraseStore: MiyaPhraseStore,
                                                        codephrase: String) throws {
        let file = folder.appending(path: "phrase-removal/notes.json")
        // An explicit absent legacy database keeps the fixture independent of the developer's Documents
        // folder; nothing here may depend on a real Flutter database being present or missing.
        let absent = folder.appending(path: "phrase-removal/absent.sqlite")
        let store = MiyaNotesStore(fileURL: file, legacyURL: absent)
        precondition(store.storageError == nil && store.notes.count == 6)

        // 1. A stored note with a title and other body text keeps both once the codephrase is taken out.
        //    The draft including the codephrase is persisted first, so the sanitising write has real
        //    plaintext on disk to remove instead of merely never adding any.
        let titled = MiyaNote(title: "Vakantie", body: "Vlucht gepland\n- Hotel")
        store.update(titled)
        let titledCount = store.notes.count
        guard let titledIndex = store.notes.firstIndex(where: { $0.id == titled.id }) else {
            preconditionFailure("the note just written must be stored")
        }
        precondition(titledIndex == 0)
        store.update(MiyaNote(id: titled.id, title: titled.title, body: titled.body + "\n" + codephrase))
        let withCodephrase = try String(contentsOf: file, encoding: .utf8)
        precondition(withCodephrase.contains(codephrase), "fixture premise: the draft with the codephrase is on disk")
        guard let sanitizedTitled = phraseStore.removingTrigger(from: titled.body + "\n" + codephrase) else {
            preconditionFailure("a codephrase on its own line must be recognised")
        }
        precondition(sanitizedTitled == titled.body + "\n", "removal leaves the line break behind, as the original fixture encodes")
        store.updateAfterPhraseRemoval(MiyaNote(id: titled.id, title: titled.title, body: sanitizedTitled))
        precondition(store.notes.count == titledCount, "an existing note is replaced in place, never inserted twice")
        precondition(store.notes[titledIndex].id == titled.id, "an existing note keeps its identity and position")
        precondition(store.notes[titledIndex].title == "Vakantie", "the title of an existing note must survive")
        precondition(store.notes[titledIndex].body.contains("Vlucht gepland"), "other body text must survive")
        precondition(store.notes[titledIndex].body.contains("- Hotel"), "other body text must survive")
        try assertNoCodephrase(in: file, codephrase)

        // 2. A stored note whose whole body is the codephrase is written back empty and kept in place.
        let phraseOnly = MiyaNote(title: "", body: codephrase)
        store.update(phraseOnly)
        guard let phraseIndex = store.notes.firstIndex(where: { $0.id == phraseOnly.id }) else {
            preconditionFailure("the phrase-only note just written must be stored")
        }
        let phraseOnDisk = try String(contentsOf: file, encoding: .utf8)
        precondition(phraseOnDisk.contains(codephrase), "fixture premise: the plaintext codephrase is on disk")
        guard let sanitizedOnly = phraseStore.removingTrigger(from: phraseOnly.body) else {
            preconditionFailure("a note that is only the codephrase must be recognised")
        }
        precondition(sanitizedOnly.isEmpty)
        store.updateAfterPhraseRemoval(MiyaNote(id: phraseOnly.id, title: "", body: sanitizedOnly))
        precondition(store.notes.count == titledCount + 1, "the emptied note is not deleted")
        precondition(store.notes[phraseIndex].id == phraseOnly.id && store.notes[phraseIndex].body.isEmpty)
        precondition(store.notes[phraseIndex].title.isEmpty)
        precondition(!store.notes.contains { $0.body.contains(codephrase) })
        try assertNoCodephrase(in: file, codephrase)
        let reloaded = MiyaNotesStore(fileURL: file, legacyURL: absent)
        precondition(reloaded.storageError == nil && reloaded.notes.count == titledCount + 1)
        precondition(reloaded.notes.contains { $0.id == phraseOnly.id && $0.title.isEmpty && $0.body.isEmpty },
                     "the emptied note stays stored across a restart")

        // 3. A note that was never stored and is empty after sanitising must not create a row or a write.
        let countBeforeFresh = store.notes.count
        let bytesBeforeFresh = try Data(contentsOf: file)
        store.updateAfterPhraseRemoval(MiyaNote(title: "", body: ""))
        precondition(store.notes.count == countBeforeFresh, "a fresh empty note adds no row")
        store.updateAfterPhraseRemoval(MiyaNote(title: "", body: "  \n "))
        precondition(store.notes.count == countBeforeFresh, "whitespace alone is not content")
        let bytesAfterFresh = try Data(contentsOf: file)
        precondition(bytesAfterFresh == bytesBeforeFresh, "skipping an empty fresh note must not rewrite notes.json")
        // The skip above is only about empty notes, not a blanket refusal of new ones.
        let fresh = MiyaNote(title: "Nieuw", body: "Tekst")
        store.updateAfterPhraseRemoval(fresh)
        precondition(store.notes.count == countBeforeFresh + 1 && store.notes.first == fresh)
        try assertNoCodephrase(in: file, codephrase)
    }

    /// A real transient write failure: the parent path of notes.json is replaced by a regular file, so the
    /// createDirectory() in save() fails. Restoring a valid directory must let the very same store write
    /// again — one failed write may set storageError, but it must not disable editing for the session,
    /// which is what blocksSaving (not storageError) is for.
    @MainActor static func proveWriteFailureRecovery(in folder: URL) throws {
        let fileManager = FileManager.default
        let root = folder.appending(path: "write-recovery")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "notes.json")
        let absent = folder.appending(path: "write-recovery/absent.sqlite")
        let store = MiyaNotesStore(fileURL: file, legacyURL: absent)
        precondition(store.storageError == nil && store.notes.count == 6)
        let target = store.notes[0]

        try fileManager.removeItem(at: root)
        try Data("geen map".utf8).write(to: root) // invalid parent path: a regular file, not a directory
        store.update(MiyaNote(id: target.id, title: target.title, body: "Gewijzigde tekst"))
        precondition(store.storageError != nil, "a failed write must be reported")
        precondition(!fileManager.fileExists(atPath: file.path), "a failed write must not leave a partial file")
        precondition(store.notes.first?.body == "Gewijzigde tekst",
                     "the note is edited in memory even when the write fails, so nothing is silently dropped")

        try fileManager.removeItem(at: root) // restore a valid directory
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        store.update(MiyaNote(id: target.id, title: target.title, body: "Opnieuw opgeslagen"))
        precondition(store.storageError == nil, "a recovered write must clear the error again")
        let reloaded = MiyaNotesStore(fileURL: file, legacyURL: absent)
        precondition(reloaded.storageError == nil && reloaded.notes.count == 6,
                     "the recovered store writes the full note list again")
        precondition(reloaded.notes.first?.body == "Opnieuw opgeslagen")
        precondition(reloaded.notes.contains { $0.id == target.id })
    }

    /// notes.json is the artefact that must never keep the plaintext codephrase, so it is read back as
    /// text and searched after every sanitising write. The codephrase contains no character that the
    /// encoder escapes, so a literal substring search is exact.
    private static func assertNoCodephrase(in file: URL, _ codephrase: String) throws {
        let raw = try String(contentsOf: file, encoding: .utf8)
        precondition(!raw.contains(codephrase), "notes.json still contains the plaintext codephrase")
    }
}
