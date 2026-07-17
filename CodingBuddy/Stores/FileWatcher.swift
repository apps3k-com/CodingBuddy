//
//  FileWatcher.swift
//  CodingBuddy
//

import Foundation

/// Watches a single path (file or directory) for changes with a kqueue-backed
/// DispatchSource and invokes the handler on the main actor. Atomic saves
/// replace the underlying inode, so callers should recreate their watchers
/// after every change event.
final class FileWatcher {
    private let source: DispatchSourceFileSystemObject

    /// Opens a path for event-only observation, failing when the path is unavailable.
    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.resolvingSymlinksInPath().path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated(onChange)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    /// Stops observation and closes the owned file descriptor.
    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
