import CoreServices
import Foundation
import Synchronization

/// Sorveglia ricorsivamente delle cartelle con FSEvents e riporta i file toccati.
public final class DirectoryWatcher: Sendable {
    private let paths: [URL]
    private let latency: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "it.vitosaulle.Belvedere.watcher")
    private let stream = Mutex<FSEventStreamRef?>(nil)

    public init(paths: [URL], latency: TimeInterval = 0.3, onChange: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        stream.withLock { current in
            guard current == nil else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
                watcher.onChange(Array(list.prefix(count)))
            }
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                               | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, &context, paths.map(\.path) as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                    latency, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            current = created
        }
    }

    public func stop() {
        stream.withLock { current in
            guard let s = current else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            current = nil
        }
    }
}
