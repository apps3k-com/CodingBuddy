//
//  BackupBrowserTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Discovery and restore coverage for CodingBuddy's backup browser.
@MainActor
@Suite(.serialized)
struct BackupBrowserTests {
    /// Verifies restore recovery UI preserves commit state and every retained artifact.
    @Test func restoreFailurePresentationPreservesStructuredRecoveryState() {
        let paths = ["/tmp/recovery-a", "/tmp/recovery-b"]
        let contexts: [SafeFileWriter.RecoveryArtifact.Context] = [.stagedWrite, .uncertainTarget]
        let artifacts = zip(paths, contexts).map {
            SafeFileWriter.RecoveryArtifact(lastKnownPath: $0.0, context: $0.1)
        }

        let notApplied = BackupRestoreFailurePresentation(error: SafeFileWriter.RecoveryError(
            commitState: .notCommitted,
            artifacts: artifacts
        ))
        let applied = BackupRestoreFailurePresentation(error: SafeFileWriter.RecoveryError(
            commitState: .committed,
            artifacts: artifacts
        ))
        let uncertain = BackupRestoreFailurePresentation(error: SafeFileWriter.RecoveryError(
            commitState: .unknown,
            artifacts: artifacts
        ))
        let needsVerification = BackupRestoreFailurePresentation(
            error: SafeFileWriter.CleanupDurabilityError()
        )
        let ordinary = BackupRestoreFailurePresentation(
            error: CocoaError(.fileWriteUnknown)
        )

        #expect(notApplied.outcome == .notApplied)
        #expect(applied.outcome == .appliedWithRecovery)
        #expect(uncertain.outcome == .uncertain)
        #expect(needsVerification.outcome == .appliedNeedsVerification)
        #expect(needsVerification.title == String(localized: "Restore Applied; Verification Required"))
        #expect(needsVerification.recoveryURLs.isEmpty)
        #expect(needsVerification.requiresPersistentAttention)
        #expect(ordinary.outcome == .ordinaryFailure)
        #expect(!ordinary.requiresPersistentAttention)
        #expect(notApplied.recoveryURLs.map(\.path) == paths)
    }

    /// Creates an isolated fixture root for backup browser tests.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupBrowserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes UTF-8 text while creating missing parent directories.
    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Returns a discovered backup item by exact backup filename.
    private func item(_ fileName: String, in items: [BackupBrowserItem]) throws -> BackupBrowserItem {
        try #require(items.first { $0.backupURL.lastPathComponent == fileName })
    }

    /// Verifies backup files are grouped by supported logical source files.
    @Test func scannerGroupsSupportedBackupsByLogicalSource() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write("zsh backup\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        try write("codex backup\n", to: backups.appendingPathComponent("mcp.env-2026-06-28-001123-333"))
        try write("claude backup\n", to: backups.appendingPathComponent("settings.json-2026-06-28-001124-333"))
        try write("claude local backup\n", to: backups.appendingPathComponent("settings.local.json-2026-06-28-001125-333"))
        try write("cursor backup\n", to: backups.appendingPathComponent("mcp.json-2026-06-28-001126-333"))
        try write("unknown backup\n", to: backups.appendingPathComponent("random-2026-06-28-001127-333"))

        let items = try BackupBrowserScanner(homeDirectory: home, backupDirectory: backups).items()

        #expect(items.map(\.backupURL.lastPathComponent) == [
            "random-2026-06-28-001127-333",
            "mcp.json-2026-06-28-001126-333",
            "settings.local.json-2026-06-28-001125-333",
            "settings.json-2026-06-28-001124-333",
            "mcp.env-2026-06-28-001123-333",
            "zshrc-2026-06-28-001122-333",
        ])
        #expect(try item("zshrc-2026-06-28-001122-333", in: items).targetURL == home.appendingPathComponent(".zshrc"))
        #expect(try item("mcp.env-2026-06-28-001123-333", in: items).sourceDisplayName == "Codex mcp.env")
        #expect(try item("settings.json-2026-06-28-001124-333", in: items).targetURL == home.appendingPathComponent(".claude/settings.json"))
        #expect(try item("settings.local.json-2026-06-28-001125-333", in: items).targetURL == home.appendingPathComponent(".claude/settings.local.json"))
        #expect(try item("mcp.json-2026-06-28-001126-333", in: items).targetURL == home.appendingPathComponent(".cursor/mcp.json"))
        #expect(try item("random-2026-06-28-001127-333", in: items).targetURL == nil)
    }

    /// Verifies discovery counts unrelated entries and refuses an incomplete inventory.
    @Test func scannerRefusesDirectoryEntryOverflowWithoutReturningPartialItems() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write("backup\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        try write("noise\n", to: backups.appendingPathComponent("unrelated-a"))
        try write("noise\n", to: backups.appendingPathComponent("unrelated-b"))
        let scanner = BackupBrowserScanner(
            homeDirectory: home,
            backupDirectory: backups,
            maximumDirectoryEntryCount: 2
        )

        #expect(throws: BackupBrowserScanner.ScanError.tooManyEntries(maximum: 2)) {
            _ = try scanner.items()
        }
    }

    /// Verifies a disappearing entry cannot turn a failed metadata lookup into a complete inventory.
    @Test func scannerRefusesMetadataLookupRaceWithoutReturningPartialItems() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let racedBackup = backups.appendingPathComponent("zshrc-2026-06-28-001122-333")
        try write("backup\n", to: racedBackup)
        let scanner = BackupBrowserScanner(
            homeDirectory: home,
            backupDirectory: backups,
            entryMetadataHook: { name in
                guard name == racedBackup.lastPathComponent else { return }
                try FileManager.default.removeItem(at: racedBackup)
            }
        )

        #expect(throws: BackupBrowserScanner.ScanError.directoryUnavailable) {
            _ = try scanner.items()
        }
    }

    /// Verifies a reload clears stale rows and exposes the exact fail-closed discovery state.
    @Test func storeClearsInventoryWhenDirectoryEntryLimitIsExceeded() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write("backup\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        let store = BackupBrowserStore(
            homeDirectory: home,
            backupDirectory: backups,
            maximumDirectoryEntryCount: 2
        )
        store.reload()
        #expect(store.items.count == 1)
        #expect(store.discoveryError == nil)

        try write("noise\n", to: backups.appendingPathComponent("unrelated-a"))
        try write("noise\n", to: backups.appendingPathComponent("unrelated-b"))
        store.reload()

        #expect(store.items.isEmpty)
        #expect(store.discoveryError == .tooManyEntries(maximum: 2))
    }

    /// Verifies normal per-source retention can exceed 64 rows without disabling restore.
    @Test func storeInventoriesNormalRetentionWithoutEagerSnapshotLimit() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let baseNames = [
            "zshenv", "zprofile", "zshrc", "mcp.env", "settings.json",
            "settings.local.json", "mcp.json",
        ]
        for baseName in baseNames {
            for counter in 1...10 {
                try write(
                    "\(baseName)-\(counter)\n",
                    to: backups.appendingPathComponent(
                        "\(baseName)-2026-06-28-001122-333-\(counter)"
                    )
                )
            }
        }
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)

        store.reload()

        #expect(store.items.count == 70)
        #expect(store.discoveryError == nil)
        let selected = try #require(store.items.first)
        #expect(store.preview(for: selected).backupText != String(localized: "Could not read file."))
    }

    /// Verifies implausibly large backups remain visible as explicit safety rejections.
    @Test func storeShowsOversizedBackupsAsRejectedWithoutReadingContents() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let backup = backups.appendingPathComponent("zshrc-2026-06-28-001122-333")
        try write("", to: backup)
        let handle = try FileHandle(forWritingTo: backup)
        try handle.truncate(atOffset: UInt64(BackupBrowserStore.maximumBackupFileSize + 1))
        try handle.close()
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)

        store.reload()

        let item = try #require(store.items.first)
        #expect(store.items.count == 1)
        #expect(store.discoveryError == nil)
        #expect(item.byteCount == BackupBrowserStore.maximumBackupFileSize + 1)
        #expect(item.rejectionReason == .exceedsSizeLimit(
            maximumByteCount: BackupBrowserStore.maximumBackupFileSize
        ))
        #expect(item.statusDisplayName == String(localized: "Rejected"))
        #expect(!item.canPreview)
        #expect(!item.canRestore)
        #expect(store.preview(for: item).backupText == item.rejectionReason?.explanation)
    }

    /// Verifies restore writes through SafeFileWriter and backs up the current target first.
    @Test func storeRestoreCreatesBackupOfCurrentFileBeforeReplacingIt() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".zshrc")
        try write("current\n", to: target)
        try write("restored\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        try store.restore(backup)

        #expect(try String(contentsOf: target, encoding: .utf8) == "restored\n")
        let entries = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(entries.contains { $0.lastPathComponent.hasPrefix("zshrc-") && $0.lastPathComponent != backup.backupURL.lastPathComponent })
        let currentBackup = try #require(entries.first { $0.lastPathComponent != backup.backupURL.lastPathComponent })
        #expect(try String(contentsOf: currentBackup, encoding: .utf8) == "current\n")
    }

    /// Verifies unresolved restore recovery survives view recreation and blocks another restore.
    @Test func restoreRecoveryAttentionPersistsUntilExplicitlyReviewed() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".zshrc")
        let recoveryPath = root.appendingPathComponent("retained-recovery")
        try write("current\n", to: target)
        try write("restored\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        let injectedError = SafeFileWriter.RecoveryError(
            commitState: .notCommitted,
            artifacts: [
                SafeFileWriter.RecoveryArtifact(
                    lastKnownPath: recoveryPath.path,
                    context: .stagedWrite
                )
            ]
        )
        let store = BackupBrowserStore(
            homeDirectory: home,
            backupDirectory: backups,
            restoreTransactionHook: { point in
                if case .beforeCommit = point { throw injectedError }
            }
        )
        store.reload()
        let backup = try #require(store.items.first)

        #expect(throws: SafeFileWriter.RecoveryError.self) {
            try store.restore(backup)
        }

        let attention = try #require(store.restoreRecoveryAttention)
        #expect(attention.outcome == .notApplied)
        #expect(attention.recoveryURLs == [recoveryPath])
        #expect(try String(contentsOf: target, encoding: .utf8) == "current\n")
        #expect(throws: BackupBrowserError.recoveryRequiresReview) {
            try store.restore(backup)
        }

        store.markRestoreRecoveryReviewed()
        #expect(store.restoreRecoveryAttention == nil)
    }

    /// Verifies restoring Codex credentials recreates missing files with restrictive permissions.
    @Test func storeRestoreCreatesCodexEnvWithRestrictivePermissions() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".codex/mcp.env")
        try write("OPENAI_API_KEY=restored\n", to: backups.appendingPathComponent("mcp.env-2026-06-28-001122-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        try store.restore(backup)

        #expect(try String(contentsOf: target, encoding: .utf8) == "OPENAI_API_KEY=restored\n")
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        )
        #expect(permissions & 0o777 == 0o600)
    }

    /// Verifies restore refuses to snapshot an unexpectedly large current target.
    @Test func storeRestoreRefusesOversizedCurrentTargetBeforeBackupOrMutation() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".zshrc")
        let backupURL = backups.appendingPathComponent("zshrc-2026-06-28-001122-333")
        try write("", to: target)
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: UInt64(BackupBrowserStore.maximumBackupFileSize + 1))
        try handle.close()
        try write("restored\n", to: backupURL)
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        #expect(throws: SafeFileWriter.WriteError.targetTooLarge) {
            try store.restore(backup)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attributes[.size] as? Int == BackupBrowserStore.maximumBackupFileSize + 1)
        let entries = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(entries.map(\.lastPathComponent) == [backupURL.lastPathComponent])
    }

    /// Verifies descriptor-created parents are rebound before a restored file can be committed.
    @Test func storeRestoreRejectsCreatedParentReplacementBeforeCommit() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let parent = home.appendingPathComponent(".codex", isDirectory: true)
        let movedParent = home.appendingPathComponent(".codex-moved", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write(
            "OPENAI_API_KEY=restored\n",
            to: backups.appendingPathComponent("mcp.env-2026-06-28-001122-333")
        )
        var replacedParent = false
        let store = BackupBrowserStore(
            homeDirectory: home,
            backupDirectory: backups,
            restoreTransactionHook: { point in
                guard case .beforeSnapshotValidation = point, !replacedParent else { return }
                replacedParent = true
                try FileManager.default.moveItem(at: parent, to: movedParent)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            }
        )
        store.reload()
        let backup = try #require(store.items.first)

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try store.restore(backup)
        }
        #expect(replacedParent)
        #expect(!FileManager.default.fileExists(atPath: movedParent.appendingPathComponent("mcp.env").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("mcp.env").path))
    }

    /// Verifies every supported secret-bearing restore target opts into private creation.
    @Test func allSupportedRestoreSourcesUseRestrictiveCreationMode() {
        let sources: [BackupBrowserSource] = [
            .shell(.zshenv),
            .shell(.zprofile),
            .shell(.zshrc),
            .codexMCPEnv,
            .claudeSettings,
            .claudeLocalSettings,
            .cursorMCPJSON,
        ]

        for source in sources {
            #expect(source.createMode == 0o600)
        }
        #expect(BackupBrowserSource.unsupported(baseName: "unknown").createMode == nil)
    }

    /// Verifies a target created after a missing snapshot is treated as stale.
    @Test func storeRestoreRejectsConcurrentlyCreatedMissingTarget() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".zshrc")
        try write("restored\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        var createdTarget = false
        let store = BackupBrowserStore(
            homeDirectory: home,
            backupDirectory: backups,
            restoreTransactionHook: { point in
                guard case .beforeSnapshotValidation = point, !createdTarget else { return }
                createdTarget = true
                try "outside\n".write(to: target, atomically: true, encoding: .utf8)
            }
        )
        store.reload()
        let backup = try #require(store.items.first)

        #expect(throws: SafeFileWriter.WriteError.staleOriginal) {
            try store.restore(backup)
        }
        #expect(createdTarget)
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside\n")
        let entries = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(entries.map(\.lastPathComponent) == [backup.backupURL.lastPathComponent])
    }

    /// Verifies restoring through a dotfile symlink updates the target without replacing the link.
    @Test func storeRestorePreservesDotfileSymlink() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let realTarget = root.appendingPathComponent("dotfiles-zshrc")
        let link = home.appendingPathComponent(".zshrc")
        try write("current\n", to: realTarget)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realTarget)
        try write("restored\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        try store.restore(backup)

        #expect(try String(contentsOf: realTarget, encoding: .utf8) == "restored\n")
        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
    }

    /// Verifies shell previews hide every assignment regardless of its variable name.
    @Test func storePreviewRedactsAllShellValues() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write(
            """
            export GITHUB_TOKEN=secret
            DATABASE_URL=postgres://user:password@host/database
            REDIS_URL=redis://user:password@host
            CONNECTION_STRING=Server=host;Password=secret
            NORMAL=value
            # Harmless section comment
            """,
            to: backups.appendingPathComponent("mcp.env-2026-06-28-001122-333")
        )
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        let preview = store.preview(for: backup)

        #expect(preview.backupText.contains("export GITHUB_TOKEN=••••••••"))
        #expect(preview.backupText.contains("DATABASE_URL=••••••••"))
        #expect(preview.backupText.contains("REDIS_URL=••••••••"))
        #expect(preview.backupText.contains("CONNECTION_STRING=••••••••"))
        #expect(preview.backupText.contains("NORMAL=••••••••"))
        #expect(preview.backupText.contains("# Harmless section comment"))
        for secret in ["postgres://", "redis://", "Password=secret", "NORMAL=value"] {
            #expect(!preview.backupText.contains(secret))
        }
    }

    /// Verifies zsh declaration builtins preserve only an unambiguous prefix before masking.
    @Test func shellPreviewRedactsSupportedDeclarationVariants() {
        #expect(BackupShellPreviewRedactor.redact("GITHUB_TOKEN=secret") ==
            "GITHUB_TOKEN=••••••••")
        #expect(BackupShellPreviewRedactor.redact("  export   GITHUB_TOKEN='secret'") ==
            "  export   GITHUB_TOKEN=••••••••")
        #expect(BackupShellPreviewRedactor.redact("typeset -x GITHUB_TOKEN=secret") ==
            "typeset -x GITHUB_TOKEN=••••••••")
        #expect(BackupShellPreviewRedactor.redact("typeset -gx -- API_KEY=secret") ==
            "typeset -gx -- API_KEY=••••••••")
        #expect(BackupShellPreviewRedactor.redact("readonly AWS_SECRET_ACCESS_KEY=secret") ==
            "readonly AWS_SECRET_ACCESS_KEY=••••••••")
        #expect(BackupShellPreviewRedactor.redact("export -n NPM_AUTH=secret") ==
            "export -n NPM_AUTH=••••••••")
        #expect(BackupShellPreviewRedactor.redact("typeset PATH=/opt/bin") ==
            "typeset PATH=••••••••")
        #expect(BackupShellPreviewRedactor.redact("readonly NORMAL=value # harmless") ==
            "readonly NORMAL=•••••••• # harmless")
    }

    /// Verifies ambiguous secret-bearing shell text fails closed instead of leaking a suffix.
    @Test func shellPreviewFailsClosedForMalformedAndCompoundSecretLines() {
        let malformed = BackupShellPreviewRedactor.redact(
            "typeset -x GITHUB_TOKEN='unterminated-secret"
        )
        let compound = BackupShellPreviewRedactor.redact(
            "typeset NORMAL=visible GITHUB_TOKEN=compound-secret"
        )
        let embedded = BackupShellPreviewRedactor.redact(
            #"NORMAL="GITHUB_TOKEN=embedded-secret""#
        )
        let comment = BackupShellPreviewRedactor.redact(
            "# stale GITHUB_TOKEN=comment-secret"
        )
        let appended = BackupShellPreviewRedactor.redact(
            "typeset -x GITHUB_TOKEN+=append-secret"
        )
        let indexed = BackupShellPreviewRedactor.redact(
            "GITHUB_TOKEN[work] = indexed-secret"
        )

        #expect(malformed == "typeset -x GITHUB_TOKEN=••••••••")
        #expect(compound == "typeset NORMAL=••••••••")
        #expect(embedded == "NORMAL=••••••••")
        #expect(comment == "••••••••")
        #expect(appended == "••••••••")
        #expect(indexed == "GITHUB_TOKEN[work] =••••••••")
        let redactedLines = [malformed, compound, embedded, comment, appended, indexed]
        for secret in [
            "unterminated-secret", "compound-secret", "embedded-secret",
            "comment-secret", "append-secret", "indexed-secret",
        ] {
            #expect(!redactedLines.contains(where: { $0.contains(secret) }))
        }
    }

    /// Verifies the store applies declaration redaction to real backup preview content.
    @Test func storePreviewDoesNotExposeDeclarationSecrets() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write(
            """
            typeset -x GITHUB_TOKEN=typeset-secret
            readonly AWS_SECRET_ACCESS_KEY=readonly-secret
            export -n NPM_AUTH=export-option-secret
            NORMAL=value
            """,
            to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333")
        )
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        let preview = store.preview(for: backup).backupText

        #expect(preview.contains("typeset -x GITHUB_TOKEN=••••••••"))
        #expect(preview.contains("readonly AWS_SECRET_ACCESS_KEY=••••••••"))
        #expect(preview.contains("export -n NPM_AUTH=••••••••"))
        #expect(preview.contains("NORMAL=••••••••"))
        for secret in ["typeset-secret", "readonly-secret", "export-option-secret"] {
            #expect(!preview.contains(secret))
        }
    }

    /// Verifies multiline shell assignments make the whole preview opaque.
    @Test func shellPreviewFailsClosedForMultilineAssignmentForms() {
        let documents = [
            "GITHUB_TOKEN='first-line\nquoted-secret'\nNORMAL=value",
            "GITHUB_TOKEN=first-line\\\ncontinued-secret\nNORMAL=value",
            "GITHUB_TOKEN=$(cat <<'EOF'\nheredoc-secret\nEOF\n)\nNORMAL=value",
            "env GITHUB_TOKEN='wrapper-line\nwrapper-secret'\nNORMAL=value",
        ]

        for document in documents {
            let preview = BackupShellPreviewRedactor.redactDocument(document)
            #expect(preview == "••••••••")
            for secret in [
                "quoted-secret", "continued-secret", "heredoc-secret", "wrapper-secret",
            ] {
                #expect(!preview.contains(secret))
            }
        }
    }

    /// Verifies the store routes shell backups through whole-document multiline refusal.
    @Test func storePreviewFailsClosedForMultilineShellAssignment() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write(
            "GITHUB_TOKEN='first-line\nstore-secret'\nNORMAL=value",
            to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333")
        )
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        let preview = store.preview(for: backup).backupText

        #expect(preview == "••••••••")
        #expect(!preview.contains("store-secret"))
    }

    /// Verifies JSON backup previews retain shape while masking all scalar values.
    @Test func storePreviewStructurallyRedactsEveryJSONValue() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let secret = "SECRET\\\"}, \\\"suffix\\\": \\\"LEAK"
        let json = try JSONSerialization.data(withJSONObject: [
            "access_token": secret,
            "scope": "read",
            "env": [
                "DATABASE_URL": "postgres://user:password@host/database",
                "ARBITRARY_NAME": "must-not-be-visible",
            ],
            "enabled": true,
            "retries": 3,
        ], options: [.sortedKeys])
        let backupURL = backups.appendingPathComponent("settings.json-2026-06-28-001122-333")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try json.write(to: backupURL)
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        let preview = store.preview(for: backup)

        #expect(!preview.backupText.contains("SECRET"))
        #expect(!preview.backupText.contains("LEAK"))
        #expect(!preview.backupText.contains("read"))
        #expect(!preview.backupText.contains("postgres://"))
        #expect(!preview.backupText.contains("must-not-be-visible"))
        #expect(preview.backupText.contains("\"env\""))
        #expect(preview.backupText.contains("\"ARBITRARY_NAME\""))
        #expect(preview.backupText.contains("\"enabled\""))
        #expect(preview.backupText.contains("\"retries\""))
    }

    /// Verifies malformed JSON fails closed instead of falling back to textual display.
    @Test func storePreviewMasksMalformedJSONAsOneOpaqueValue() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write(
            #"{"env":{"CONNECTION_STRING":"Server=host;Password=LEAK"}"#,
            to: backups.appendingPathComponent("settings.json-2026-06-28-001122-333")
        )
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        let preview = store.preview(for: backup).backupText

        #expect(preview == "••••••••")
        #expect(!preview.contains("LEAK"))
        #expect(!preview.contains("CONNECTION_STRING"))
    }

    /// Verifies harmless shell structure survives while uncertain assignment text is opaque.
    @Test func shellPreviewPreservesHarmlessStructureAndMasksUncertainty() {
        #expect(BackupShellPreviewRedactor.redact("") == "")
        #expect(BackupShellPreviewRedactor.redact("# Development tools") == "# Development tools")
        #expect(BackupShellPreviewRedactor.redact("autoload -Uz compinit") == "autoload -Uz compinit")
        #expect(BackupShellPreviewRedactor.redact("PLAIN=value # safe note") ==
            "PLAIN=•••••••• # safe note")
        #expect(BackupShellPreviewRedactor.redact("PLAIN=value # fallback=secret") ==
            "PLAIN=••••••••")
        #expect(BackupShellPreviewRedactor.redact("PLAIN+=appended") ==
            "PLAIN+=••••••••")
        #expect(BackupShellPreviewRedactor.redact("PLAIN[index]=indexed") ==
            "PLAIN[index]=••••••••")
        #expect(BackupShellPreviewRedactor.redact("PLAIN=one SECOND=two") ==
            "PLAIN=••••••••")
    }

    /// Verifies an atomic backup replacement after discovery cannot be previewed or restored.
    @Test func storeRejectsBackupReplacementAfterDiscovery() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".zshrc")
        let backupURL = backups.appendingPathComponent("zshrc-2026-06-28-001122-333")
        try write("current\n", to: target)
        try write("captured\n", to: backupURL)
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        try FileManager.default.removeItem(at: backupURL)
        try write("replacement\n", to: backupURL)

        #expect(store.preview(for: backup).backupText == String(localized: "Could not read file."))
        #expect(throws: BackupBrowserError.backupChanged) {
            try store.restore(backup)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "current\n")
    }

    /// Verifies in-place byte changes are rejected even when the backup inode is unchanged.
    @Test func storeRejectsBackupContentMutationAfterDiscovery() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".zshrc")
        let backupURL = backups.appendingPathComponent("zshrc-2026-06-28-001122-333")
        try write("current\n", to: target)
        try write("captured\n", to: backupURL)
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        let handle = try FileHandle(forWritingTo: backupURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("mutation\n".utf8))
        try handle.close()

        #expect(store.preview(for: backup).backupText == String(localized: "Could not read file."))
        #expect(throws: BackupBrowserError.backupChanged) {
            try store.restore(backup)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "current\n")
    }

    /// Verifies replacing a discovered backup with a symlink fails closed.
    @Test func storeRejectsBackupSymlinkAfterDiscovery() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let target = home.appendingPathComponent(".zshrc")
        let backupURL = backups.appendingPathComponent("zshrc-2026-06-28-001122-333")
        let external = root.appendingPathComponent("external")
        try write("current\n", to: target)
        try write("captured\n", to: backupURL)
        try write("external\n", to: external)
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        try FileManager.default.removeItem(at: backupURL)
        try FileManager.default.createSymbolicLink(at: backupURL, withDestinationURL: external)

        #expect(store.preview(for: backup).backupText == String(localized: "Could not read file."))
        #expect(throws: BackupBrowserError.backupChanged) {
            try store.restore(backup)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "current\n")
    }

    /// Verifies unsupported backup names are preview-only and cannot be restored.
    @Test func storeRestoreRefusesUnsupportedBackupTargets() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try write("unknown\n", to: backups.appendingPathComponent("random-2026-06-28-001125-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        #expect(throws: BackupBrowserError.unsupportedBackup) {
            try store.restore(backup)
        }
    }

    /// Verifies restore fails before writing when the target path is not a file.
    @Test func storeRestoreRefusesDirectoryTargets() throws {
        let root = try makeTempDir()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".zshrc"), withIntermediateDirectories: true)
        try write("restored\n", to: backups.appendingPathComponent("zshrc-2026-06-28-001122-333"))
        let store = BackupBrowserStore(homeDirectory: home, backupDirectory: backups)
        store.reload()
        let backup = try #require(store.items.first)

        #expect(throws: BackupBrowserError.targetNotWritable) {
            try store.restore(backup)
        }
    }
}
