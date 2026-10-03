# Kinooz / MI-YA native shell

The app opens as a plain "Notities" notes app (`ElementX/Sources/Application/Miya`). The Element X chat
stays hidden until the owner types their own personal phrase on its own line in a note. The phrase is a
user-chosen privacy convenience for this device only: there is no administrator access, no remote
unlock, no hidden retention and no encryption backdoor. The phrase is removed from the note the moment
it is recognised, and only a salted PBKDF2 hash of it is kept in the Keychain (this-device-only).

## Notes storage and migration

- Native notes live in `Application Support/MiyaNative/notes.json` (atomic write, complete file protection).
- On first launch, if the Flutter app's `Documents/miya_notities.sqlite` exists (same path as sqflite's
  `getDatabasesPath()` on iOS; table `notes`, optional `note_folders`), it is imported once.
  - The source is never modified: its files (plus any `-wal`/`-shm`) are copied to a protected temporary
    folder that is deleted afterwards, and the copy is read.
  - Older schema versions (no `folder`/`daily_key`, no `note_folders`) are tolerated.
  - If import fails, an error is shown, no `notes.json` is written, and the next launch retries.
  - A corrupt `notes.json` is never overwritten; editing is disabled and an error is shown.
- Only when neither file exists are six example notes created.
- Caveat: the import only finds the Flutter database when the app runs with the same app container
  (same bundle identifier / install). A different bundle id starts a new container and shows examples.

## Verifying behaviour

`Kinooz/Proofs/MiyaShellBehavior.swift` is a standalone check of the store, migration and phrase logic:

```sh
swiftc -parse-as-library -o /tmp/miya-proof Kinooz/Proofs/MiyaShellBehavior.swift \
  ElementX/Sources/Application/Miya/Miya{NotesStore,LegacyNotes,PhraseStore}.swift -lsqlite3 && /tmp/miya-proof
```

## Current build limitations

- The full unsigned Debug device build passed on Xcode 26.2, including a second build after the free
  OpenCode/Bunny review fixes. A physical-device runtime test and signed push delivery remain pending.
  Use an isolated `-clonedSourcePackagesDirPath` and package cache for reproducibility.
- `DEVELOPMENT_TEAM` is empty in `app.yml`. The main app falls back to its private Keychain when the
  shared group has no team prefix. Signed push/extension sharing still needs the correct Apple team.
- `project.yml`/`app.yml` changes (bundle id `nl.kinooz.miya`, name, version) were also applied to the
  checked-in `ElementX.xcodeproj`; regenerate with XcodeGen to confirm they stay in sync.
- The SwiftUI shell views (`MiyaNotesShell`) are only covered by compilation, not by UI tests; the app
  skips the shell when running under the existing test processes.
- Notes do not sync, and are included in device backups unless protected by the user's backup settings.

Canonical GitLab source keeps full upstream Git history with LFS storage disabled. Original upstream
LFS fixtures remain available from `upstream`: run `git lfs pull upstream --include="DevelopmentAssets/Media/**"`
for the development build. Do not fetch all historical snapshots merely to build the app.

Free review proof: DUSK Mini OpenCode 1.18.34, provider `opencode`, model `space-bunny-free`,
all assistant messages reported cost 0. Whitespace-only codephrases are rejected, accepted phrases
are normalized, and inactive/background transitions remove the chat view from the hierarchy.
The old notes SQLite has no attachments table; chat media remains on the unchanged Matrix server.

DUSK ran a second independent OpenCode/Bunny review at cost 0. The sideload private Keychain
uses WhenUnlockedThisDeviceOnly. The unsigned IPA must be re-signed by Feather before installation;
unsigned compilation is build evidence, not device runtime proof. The built Info.plist actually contains
`.nl.kinooz.miya` when no team is set, which the fallback handles. Shared namespaces with valid team
prefixes retain upstream behavior. Use a configured Matrix recovery backup to restore encrypted history.
