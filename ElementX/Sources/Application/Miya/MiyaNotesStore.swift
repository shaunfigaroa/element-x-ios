// Copyright 2026 Kinooz.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI

struct MiyaNote: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var folder = ""
    var legacyID: Int64?
    var dailyKey: String?
    var createdAt: Int64?
    var updatedAt: Int64?
}

@MainActor final class MiyaNotesStore: ObservableObject {
    @Published var notes: [MiyaNote] = []
    @Published var storageError: String?
    private(set) var folders: [String] = []
    private struct Document: Codable { let notes: [MiyaNote]; let folders: [String] }
    private let fileURL: URL

    init(fileURL: URL? = nil, legacyURL: URL = MiyaLegacyNotes.databaseURL) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory.appending(path: "MiyaNative/notes.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.fileURL))
                notes = document.notes
                folders = document.folders
            } catch {
                storageError = "De notities konden niet worden geopend. Het bestaande bestand blijft bewaard."
            }
        } else if FileManager.default.fileExists(atPath: legacyURL.path) {
            do {
                let imported = try MiyaLegacyNotes.read(legacyURL)
                notes = imported.notes
                folders = imported.folders
                save()
            } catch {
                storageError = "De bestaande notities konden niet worden overgenomen. Het oorspronkelijke bestand blijft bewaard."
            }
        } else {
            notes = Self.examples
            save()
        }
    }

    func update(_ note: MiyaNote) {
        guard storageError == nil else { return }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else if !note.title.isEmpty || !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.insert(note, at: 0)
        }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Document(notes: notes, folders: folders)).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            storageError = "De notities konden niet worden opgeslagen."
        }
    }

    private static let examples = [
        MiyaNote(title: "Weekplanning", body: "Maandag: boodschappen en administratie.\nWoensdag: rondje wandelen na het eten.\nVrijdag: alvast nadenken over het weekend."),
        MiyaNote(title: "Boodschappen", body: "- Havermout\n- Bananen\n- Eieren\n- Tomaten\n- Yoghurt\n- Koffie"),
        MiyaNote(title: "Pasta met tomaat", body: "Fruit een ui met knoflook. Voeg tomaten toe en laat rustig inkoken. Kook de pasta, bewaar een kopje kookwater en meng alles met basilicum."),
        MiyaNote(title: "Boeken om te lezen", body: "Kijk bij de bibliotheek naar een roman voor het weekend en een boek over fotografie."),
        MiyaNote(title: "Idee voor thuis", body: "Een plank bij het bureau voor boeken en een klein plantje. Eerst de breedte meten."),
        MiyaNote(title: "Weekend", body: "Zaterdagochtend rustig ontbijten. Misschien naar de markt, en daarna een wandeling als het droog is.")
    ]
}
