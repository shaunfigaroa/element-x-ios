// Copyright 2026 Kinooz.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import SwiftUI

struct MiyaNotesShell: View {
    let chat: AnyView
    let startChat: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store = MiyaNotesStore()
    @State private var phraseStore = MiyaPhraseStore()
    @State private var unlocked = false
    @State private var started = false
    @State private var selected: MiyaNote?
    @State private var settingsPresented = false
    @State private var phrase = ""
    @State private var settingsError: String?
    @FocusState private var focus: Field?

    private enum Field { case title, body, phrase }

    var body: some View {
        ZStack {
            if started && unlocked {
                // `.identity` is required, not cosmetic: SwiftUI's default transition is `.opacity`, so an
                // animated removal would keep private chat content drawn and in the hierarchy until the
                // fade finished. Locking is never animated, and this makes that hold regardless of the
                // surrounding transaction.
                chat
                    .safeAreaInset(edge: .top) { chatBar }
                    .transition(.identity)
            }
            if !unlocked {
                notes
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                if !unlocked, let note = selected { store.update(note) }
                selected = nil
                focus = nil
                settingsPresented = false
                phrase = ""
                unlocked = false
            }
        }
        .sheet(isPresented: $settingsPresented) { settings }
        .onChange(of: settingsPresented) { _, presented in
            if !presented { clearPhraseDraft() }
        }
        .onChange(of: selected) { oldValue, newValue in
            if newValue == nil, !unlocked, let note = oldValue { store.update(note) }
        }
    }

    private var chatBar: some View {
        HStack {
            Button { settingsPresented = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Instellingen")
                .padding(.leading)
            Spacer()
            Button { setUnlocked(false) } label: { Label("Verbergen", systemImage: "eye.slash") }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .accessibilityHint("Vergrendelt de chat en toont de notities")
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
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
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Dubbel tik om de notitie te openen")
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
                        .accessibilityHint("Maakt een lege notitie aan")
                }
            }
            .navigationDestination(item: $selected) { _ in editor }
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Titel", text: Binding(get: { selected?.title ?? "" }, set: { selected?.title = $0 }))
                    .font(.title2.bold())
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focus = .body }
                    .accessibilityLabel("Titel van de notitie")
                TextEditor(text: Binding(get: { selected?.body ?? "" }, set: draftChanged))
                    .frame(minHeight: 200)
                    .focused($focus, equals: .body)
                    .accessibilityLabel("Inhoud van de notitie")
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Notitie")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Klaar") { focus = nil }
            }
        }
        .onAppear {
            if selected?.title.isEmpty == true, selected?.body.isEmpty == true { focus = .title }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Codezin") {
                    SecureField("Persoonlijke codezin (minimaal 8 tekens)", text: $phrase)
                        .focused($focus, equals: .phrase)
                        .submitLabel(.done)
                        .onSubmit { savePhrase() }
                    if let error = settingsError { Text(error).foregroundStyle(.red) }
                    Button("Opslaan") { savePhrase() }
                        .disabled(phrase.count < 8 || !canChangePhrase)
                }
            }
            .navigationTitle("Instellingen")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Gereed") { settingsPresented = false } } }
        }
    }

    /// An existing codephrase may only be changed while the chat is unlocked. Single source of truth for
    /// both the button's disabled state and the authorization inside savePhrase(), so the two cannot drift.
    private var canChangePhrase: Bool { !phraseStore.isConfigured || unlocked }

    private func savePhrase() {
        // The SecureField's return key reaches this action directly and never passes the button's
        // disabled state, so the authorization has to be enforced here as well.
        guard canChangePhrase else {
            clearPlaintextPhrase()
            settingsError = "Ontgrendel de chat om de codezin te wijzigen."
            return
        }
        do {
            try phraseStore.set(phrase)
            clearPhraseDraft()
            settingsPresented = false
        } catch MiyaPhraseStore.Failure.invalidPhrase {
            clearPlaintextPhrase()
            settingsError = "Gebruik minimaal 8 tekens, zonder regeleinde."
        } catch {
            clearPlaintextPhrase()
            settingsError = "De codezin kon niet worden opgeslagen."
        }
    }

    /// Drops only the typed phrase. Used when a save is rejected or fails: the reason must survive.
    private func clearPlaintextPhrase() {
        phrase = ""
    }

    /// Drops the typed phrase and the message. Used on a successful save and when the sheet closes, also
    /// when it is swiped away instead of closed with "Gereed".
    private func clearPhraseDraft() {
        phrase = ""
        settingsError = nil
    }

    private func setUnlocked(_ value: Bool) {
        guard value != unlocked else { return }
        guard value else {
            // No animation transaction when locking: the chat has to leave the hierarchy on this frame.
            unlocked = false
            return
        }
        let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.2)
        withAnimation(animation) { unlocked = true }
    }

    private func draftChanged(_ body: String) {
        guard let sanitized = phraseStore.removingTrigger(from: body) else {
            selected?.body = body
            return
        }
        selected?.body = sanitized
        if let note = selected { store.updateAfterPhraseRemoval(note) }
        selected = nil
        focus = nil
        setUnlocked(true)
        if !started {
            started = true
            startChat()
        }
    }
}
