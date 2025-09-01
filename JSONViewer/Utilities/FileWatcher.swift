import Foundation
#if os(macOS)
import AppKit
import Darwin
#endif

final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let url: URL
    private let handler: () -> Void

    init?(url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
        let path = (url as NSURL).fileSystemRepresentation
        descriptor = open(path, O_EVTONLY)
        if descriptor < 0 {
            return nil
        }

        let queue = DispatchQueue.global(qos: .utility)
        let mask: DispatchSource.FileSystemEvent = [.write, .extend, .rename, .delete]
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handler()
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.descriptor, fd >= 0 {
                close(fd)
            }
        }
        src.resume()
        source = src
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit {
        cancel()
    }
}