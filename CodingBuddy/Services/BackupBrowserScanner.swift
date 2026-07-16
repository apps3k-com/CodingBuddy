//
//  BackupBrowserScanner.swift
//  CodingBuddy
//

import Darwin
import Foundation

/// Read-only scanner for CodingBuddy's managed backup directory.
nonisolated struct BackupBrowserScanner: Sendable {
    /// Discovery failures that prevent the browser from presenting a complete inventory.
    enum ScanError: LocalizedError, Equatable, Sendable {
        /// The managed backup directory could not be opened as a directory without following its leaf.
        case directoryUnavailable
        /// Discovery stopped before reading an attacker-controlled number of directory entries.
        case tooManyEntries(maximum: Int)

        /// Localized refusal explanation shown instead of a partial or empty inventory.
        var errorDescription: String? {
            switch self {
            case .directoryUnavailable:
                return String(localized: "CodingBuddy could not inspect the backup folder safely.")
            case .tooManyEntries(let maximum):
                return String(localized: "The backup folder contains more than \(maximum) entries, so CodingBuddy refused to show a partial inventory.")
            }
        }
    }

    /// Default ceiling for every entry in the managed backup directory, including unrelated files.
    static let defaultMaximumDirectoryEntryCount = 4_096

    /// Home directory used to resolve known backup basenames back to targets.
    var homeDirectory: URL
    /// Directory where `SafeFileWriter` stores timestamped backups.
    var backupDirectory: URL
    /// Maximum number of directory entries discovery will inspect in one pass.
    var maximumDirectoryEntryCount: Int

    /// Creates a scanner for one home directory and backup directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true),
        maximumDirectoryEntryCount: Int = Self.defaultMaximumDirectoryEntryCount
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.maximumDirectoryEntryCount = max(0, maximumDirectoryEntryCount)
    }

    /// Loads parseable backup files, newest first.
    func items() throws -> [BackupBrowserItem] {
        let descriptor = backupDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return [] }
            throw ScanError.directoryUnavailable
        }
        defer { Darwin.close(descriptor) }

        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw ScanError.directoryUnavailable
        }
        defer { closedir(directory) }

        var result: [BackupBrowserItem] = []
        var inspectedEntryCount = 0
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw ScanError.directoryUnavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            inspectedEntryCount += 1
            guard inspectedEntryCount <= maximumDirectoryEntryCount else {
                throw ScanError.tooManyEntries(maximum: maximumDirectoryEntryCount)
            }

            var info = Darwin.stat()
            let isRegularFile = name.withCString {
                fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) == 0
                    && (info.st_mode & S_IFMT) == S_IFREG
            }
            guard isRegularFile, let item = item(for: name, info: info) else { continue }
            result.append(item)
        }

        return result.sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                return lhs.backupURL.lastPathComponent > rhs.backupURL.lastPathComponent
            }
    }

    /// Creates a backup row for one parseable regular file, including explicit rejections.
    private func item(for fileName: String, info: Darwin.stat) -> BackupBrowserItem? {
        guard let parsed = Self.parse(fileName: fileName) else { return nil }
        let accessState: BackupBrowserAccessState
        do {
            accessState = .available(
                try SecureInputReader.metadata(
                    from: info,
                    maximumByteCount: BackupBrowserStore.maximumBackupFileSize,
                    policy: .backup
                )
            )
        } catch SecureInputReadError.fileTooLarge {
            accessState = .rejected(
                .exceedsSizeLimit(maximumByteCount: BackupBrowserStore.maximumBackupFileSize)
            )
        } catch {
            accessState = .rejected(.unsafeMetadata)
        }
        let backupURL = backupDirectory.appendingPathComponent(fileName, isDirectory: false)
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )

        let source = source(for: parsed.baseName)
        let targetURL = source.targetURL(in: homeDirectory)
        let targetExists = targetURL
            .map { FileManager.default.fileExists(atPath: $0.resolvingSymlinksInPath().path) } ?? false

        return BackupBrowserItem(
            backupURL: backupURL,
            baseName: parsed.baseName,
            timestamp: parsed.timestamp,
            collisionCounter: parsed.collisionCounter,
            source: source,
            targetURL: targetURL,
            byteCount: Int(exactly: info.st_size),
            modifiedAt: modifiedAt,
            targetExists: targetExists,
            accessState: accessState
        )
    }

    /// Maps a backup basename to a supported restore target.
    private func source(for baseName: String) -> BackupBrowserSource {
        switch baseName {
        case "zshenv":
            .shell(.zshenv)
        case "zprofile":
            .shell(.zprofile)
        case "zshrc":
            .shell(.zshrc)
        case "mcp.env":
            .codexMCPEnv
        case "settings.json":
            .claudeSettings
        case "settings.local.json":
            .claudeLocalSettings
        case "mcp.json":
            .cursorMCPJSON
        default:
            .unsupported(baseName: baseName)
        }
    }

    /// Parses `baseName-yyyy-MM-dd-HHmmss-SSS[-counter]` backup filenames.
    private static func parse(fileName: String) -> (baseName: String, timestamp: Date, collisionCounter: Int?)? {
        guard let match = fileName.wholeMatch(
            of: #/^(.+)-(\d{4}-\d{2}-\d{2}-\d{6}-\d{3})(?:-(\d+))?$/#
        ) else {
            return nil
        }
        let stamp = String(match.2)
        guard let timestamp = timestampFormatter.date(from: stamp) else { return nil }
        return (
            baseName: String(match.1),
            timestamp: timestamp,
            collisionCounter: match.3.map { Int($0) ?? 0 }
        )
    }

    /// Formatter matching `SafeFileWriter` backup timestamps.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return formatter
    }()
}
