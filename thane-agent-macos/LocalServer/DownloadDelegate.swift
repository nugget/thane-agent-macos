import Foundation

/// Bridges URLSessionDownloadTask delegate callbacks to a CheckedContinuation.
/// Must be used as the delegate of a dedicated URLSession (not URLSession.shared)
/// because per-task delegates are not supported on download tasks.
///
/// Marked `@unchecked Sendable` because URLSession serializes delegate callbacks
/// on its delegate queue — mutable-state writes never race in practice, but the
/// compiler can't prove it.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let tempFileExtension: String
    var continuation: CheckedContinuation<URL, Error>?
    private var tempCopy: URL?
    private var hasResumed = false

    init(tempFileExtension: String, onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        self.tempFileExtension = tempFileExtension
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(fraction, 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file at `location` is deleted after this method returns, so copy
        // it to a stable temp path before resuming the continuation.
        let dest = FileManager.default.temporaryDirectory
            .appending(component: "thane-download-\(UUID().uuidString).\(tempFileExtension)")
        do {
            try FileManager.default.copyItem(at: location, to: dest)
            tempCopy = dest
        } catch {
            guard !hasResumed else { return }
            hasResumed = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !hasResumed else { return }
        hasResumed = true
        if let error {
            continuation?.resume(throwing: error)
        } else if let tempCopy {
            continuation?.resume(returning: tempCopy)
        } else {
            continuation?.resume(throwing: DownloadError.completedWithoutFile)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}

enum DownloadError: LocalizedError {
    case completedWithoutFile

    var errorDescription: String? {
        switch self {
        case .completedWithoutFile:
            return "Download completed without producing a file"
        }
    }
}
