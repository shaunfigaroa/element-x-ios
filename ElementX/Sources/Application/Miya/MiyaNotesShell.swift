// Copyright 2026 Kinooz.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI

struct MiyaNotesShell: View {
    let chat: AnyView
    let startChat: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = MiyaNotesStore()
    @State private var unlocked = false
    @State private var started = false
    @State private var selected: MiyaNote?
    @State private var settingsPresented = false
    @State private var phrase = ""
    @State private var settingsError: String?
    private let phraseStore = MiyaPhraseStore()

    var body: some View {
        ZStack {
            if started {
                chat
                    .safeAreaInset(edge: .top) {
                        HStack {
                            Button { settingsPresented = true } label: { Image(systemName: "gearshape") }
                                .accessibilityLabel("Instellingen")
                                .padding(.leading)
                            Spacer()
                            Button { unlocked = false } label: { Label("Verbergen", systemImage: "note.text") }
                                .buttonStyle(.bordered)
                                .padding(.horizontal)
                        }
                        .padding(.vertical, 4)
                        .background(.regularMaterial)
                    }
                    .opacity(unlocked ? 1 : 0)
                    .allowsHitTesting(unlocked)
                    .accessibilityHidden(!unlocked)
            }
            if !unlocked { notes }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                if !unlocked, let note = selected { store.update(note) }
                unlocked = false
            }
        }
        .sheet(isPresented: $settingsPresented) { settings }
        .onChange(of: selected) { oldValue, newValue in
            if newValue == nil, !unlocked, let note = oldValue { store.update(note) }
        }
    }

    private var notes: some View {
        NavigationStack {
            List {
                if let error = store.storageError { Text(error).foregroundStyle(.red) }
                ForEach(store.notes) { note in
                    Button { selected = note } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.title.isEmpty ? "Nieuwe notitie" : note.title).font(.headline)
                            Text(note.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Notities")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settingsPresented = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Instellingen")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { selected = MiyaNote(title: "", body: "") } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Nieuwe notitie")
                }
            }
            .navigationDestination(item: $selected) { _ in editor }
        }
    }

    private var editor: some View {
        VStack {
            TextField("Titel", text: Binding(get: { selected?.title ?? "" }, set: { selected?.title = $0 }))
                .font(.title2.bold()).padding(.horizontal)
            TextEditor(text: Binding(get: { selected?.body ?? "" }, set: draftChanged))
                .padding(.horizontal, 8)
        }
        .navigationTitle("Notitie")
        .navigationBarTitleDisplayMode(.inline)

    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Codezin") {
                    SecureField("Persoonlijke codezin (minimaal 8 tekens)", text: $phrase)
                    if let error = settingsError { Text(error).foregroundStyle(.red) }
                    Button("Opslaan") {
                        do {
                            try phraseStore.set(phrase)
                            phrase = ""
                            settingsError = nil
                            settingsPresented = false
                        } catch {
                            settingsError = "Gebruik minimaal 8 tekens. De codezin kon niet worden opgeslagen."
                        }
                    }
                    .disabled(phrase.count < 8 || (phraseStore.isConfigured && !unlocked))
                }
            }
            .navigationTitle("Instellingen")
            .toolbar { Button("Gereed") { phrase = ""; settingsPresented = false } }
        }
    }

    private func draftChanged(_ body: String) {
        guard let sanitized = phraseStore.removingTrigger(from: body) else {
            selected?.body = body
            return
        }
        selected?.body = sanitized
        if let note = selected {
            if !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !note.title.isEmpty {
                store.update(note)
            }
        }
        selected = nil
        unlocked = true
        if !started {
            started = true
            startChat()
        }
    }
}
