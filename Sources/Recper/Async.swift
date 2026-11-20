import Foundation

/// Waits at most `seconds` for the work, so a stuck call (e.g. ScreenCaptureKit without permission) can't lock the session:
/// on timeout it throws; the work finishes in the background and its result is discarded.
func withTimeout<T: Sendable>(_ seconds: Double, _ what: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let once = Once()
        Task {
            do { let v = try await op(); if once.fire() { cont.resume(returning: v) } }
            catch { if once.fire() { cont.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.fire() {
                cont.resume(throwing: NSError(domain: "recper", code: 9, userInfo: [NSLocalizedDescriptionKey: "\(what) timed out"]))
            }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
