// Copyright 2026 Kinooz.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI
import SQLite3

enum MiyaLegacyNotes {
    static var databaseURL: URL { URL.documentsDirectory.appending(path: "miya_notities.sqlite") }

    /// Reads the Flutter notes database without modifying it. The files are copied to a private,
    /// short-lived folder first so a write-ahead log next to the source is honoured and the source
    /// (and its -wal/-shm files) are never opened for writing.
    static func read(_ fileURL: URL) throws -> (notes: [MiyaNote], folders: [String]) {
        let fileManager = FileManager.default
        let workFolder = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try fileManager.createDirectory(at: workFolder, withIntermediateDirectories: false,
                                            attributes: [.protectionKey: FileProtectionType.complete])
        } catch {
            throw Failure.unreadable
        }
        defer { try? fileManager.removeItem(at: workFolder) }
        let copyURL = workFolder.appending(path: "notes.sqlite")
        do {
            try fileManager.copyItem(at: fileURL, to: copyURL)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: fileURL.path + suffix)
                if fileManager.fileExists(atPath: sidecar.path) {
                    try fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: copyURL.path + suffix))
                }
            }
        } catch {
            throw Failure.unreadable
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(copyURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Failure.unreadable
        }
        defer { sqlite3_close(database) }

        // Schema version 1 only had id/title/body/created_at/updated_at; tolerate missing columns.
        let columns = Set(try query("PRAGMA table_info(notes)", database: database).compactMap { $0[1] })
        guard ["id", "title", "body"].allSatisfy(columns.contains) else { throw Failure.unreadable }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let rows = try query("SELECT id,title,body,\(column("folder")),\(column("daily_key")),\(column("created_at")),\(column("updated_at")) FROM notes ORDER BY \(column("updated_at")) DESC, id DESC",
                             database: database)
        let notes = rows.map { row in
            MiyaNote(title: row[1] ?? "", body: row[2] ?? "", folder: row[3] ?? "", legacyID: Int64(row[0] ?? ""),
                     dailyKey: row[4], createdAt: Int64(row[5] ?? ""), updatedAt: Int64(row[6] ?? ""))
        }
        let hasFolders = try !query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='note_folders'", database: database).isEmpty
        let folders = hasFolders ? try query("SELECT path FROM note_folders ORDER BY path", database: database).compactMap { $0[0] } : []
        return (notes, folders)
    }

    private static func query(_ sql: String, database: OpaquePointer?) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.unreadable }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw Failure.unreadable }
        return rows
    }

    enum Failure: Error { case unreadable }
}
