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

- A full `xcodebuild` of the `ElementX` scheme has not been confirmed as part of this change. It needs the
  Swift packages (including the Matrix Rust SDK binary) to resolve, which is slow, and only one
  package resolution may run per cache path at a time. Use an isolated `-clonedSourcePackagesDirPath`
  / package cache when another build is running, with `CODE_SIGNING_ALLOWED=NO`.
- `DEVELOPMENT_TEAM` is empty in `app.yml`, so signed device builds, push, and keychain access groups
  (`KEYCHAIN_ACCESS_GROUP_IDENTIFIER`) need a team set locally before use.
- `project.yml`/`app.yml` changes (bundle id `nl.kinooz.miya`, name, version) were also applied to the
  checked-in `ElementX.xcodeproj`; regenerate with XcodeGen to confirm they stay in sync.
- The SwiftUI shell views (`MiyaNotesShell`) are only covered by compilation, not by UI tests; the app
  skips the shell when running under the existing test processes.
- Notes do not sync, and are included in device backups unless protected by the user's backup settings.
