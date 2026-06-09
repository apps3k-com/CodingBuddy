# Architecture

Native macOS app — Swift, SwiftUI, AppKit only. No third-party dependencies (see [Conventions](Conventions)).

## Layers

```
Views/  (SwiftUI)            ContentView · VariableListView · VariableEditorView
                             PathEditorView · ImportPreviewView
   │  reads @Observable state, calls store methods
Stores/                      EnvStore (source of truth) · FileWatcher
   │  orchestrates parse/write, owns precedence logic
Services/  (pure logic)      ShellConfigParser · ShellConfigWriter
                             ShellQuoting · EnvFileCodec · FeatureFlags
Models/                      EnvVariable · ParsedAssignment · ShellConfigFile
```

- **`EnvStore`** (`@Observable`, MainActor) loads the three zsh files, exposes `[EnvVariable]`, performs mutations through the writer and reloads afterwards. The base directory is injectable — tests never touch the real `$HOME`.
- **`ShellConfigParser` / `ShellConfigWriter`** are pure, stateless services. The parser produces the decomposed model (see [Data Model](Data-Model)); the writer is the only component that touches disk for mutations.
- **`FileWatcher`** wraps a kqueue-backed `DispatchSourceFileSystemObject` per watched path (home directory + each existing dotfile). Events are debounced (200 ms) and trigger a reload; watchers are recreated after every change because atomic saves replace the inode.

## Concurrency

The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. UI and store live on the main actor; pure logic types (`ShellQuoting`, parser et al.) are marked `nonisolated`. Dispatch sources deliver on the main queue and bridge with `MainActor.assumeIsolated`.

## Write path (safety-critical)

1. UI calls a store mutation → store delegates to `ShellConfigWriter`.
2. Writer **re-reads** the file and verifies the target line still equals the parsed `sourceLine` — otherwise it throws (`fileChangedExternally`).
3. **Backup** of the current content to Application Support (retention 20/file).
4. New content is written **atomically** to the **symlink-resolved** path; POSIX permissions are restored afterwards.
5. Store reloads and re-arms the watchers.

No-op writes (identical content) skip backup and write entirely.

## Sandbox

The app is deliberately **not sandboxed**: its purpose is reading and writing dotfiles in `$HOME`, which the App Sandbox forbids. Hardened runtime stays enabled. See [ADRs](ADRs).
