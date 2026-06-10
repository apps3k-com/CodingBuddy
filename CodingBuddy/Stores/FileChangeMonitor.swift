//
//  FileChangeMonitor.swift
//  CodingBuddy
//

import Foundation

/// Owns the watcher set and the debounce that every store needs: watch a set
/// of URLs, coalesce change bursts, then notify. Callers re-call `watch(_:)`
/// after each notification because atomic saves replace the watched inodes.
final class FileChangeMonitor {
    private var watchers: [FileWatcher] = []
    private var pendingChange: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void

    init(debounce: TimeInterval = 0.2, onChange: @escaping @MainActor () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    /// Replaces the current watcher set. URLs that cannot be opened (missing
    /// files) are skipped silently — pass them again once they exist.
    func watch(_ urls: [URL]) {
        watchers.forEach { $0.cancel() }
        watchers = urls.compactMap { url in
            FileWatcher(url: url) { [weak self] in self?.scheduleChange() }
        }
    }

    /// Drops a queued notification — call before a store's own synchronous
    /// mutation+reload, which would otherwise be repeated by the debounce.
    func cancelPending() {
        pendingChange?.cancel()
        pendingChange = nil
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit {
        watchers.forEach { $0.cancel() }
        pendingChange?.cancel()
    }
}
