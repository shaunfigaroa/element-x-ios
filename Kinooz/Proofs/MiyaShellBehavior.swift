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

        try proveLegacyMigration(in: folder)

        let service = "nl.kinooz.miya.proof.\(UUID().uuidString)"
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
        let phrase = MiyaPhraseStore(service: service)
        precondition(!phrase.isConfigured)
        try phrase.set("persoonlijke testzin")
        precondition(phrase.isConfigured)
        precondition(phrase.removingTrigger(from: "Vooraf\npersoonlijke testzin\nAchteraf") == "Vooraf\n\nAchteraf")
        precondition(phrase.removingTrigger(from: "persoonlijke testzin") == "")
        precondition(phrase.removingTrigger(from: "persoonlijke testzi") == nil)
        precondition(phrase.removingTrigger(from: "Tekst persoonlijke testzin") == nil)
        print("PASS: seeded notes, restart persistence, corrupt-file preservation, secure phrase, immediate trigger sanitation, partial/wrong-line rejection")
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
}
