import Foundation

/// Runs the already enabled local receipt listener. Error pacing never retries a
/// model send or changes receipt/acknowledgment authority.
public enum NativeReplyLoop {
    public static func run<Frame>(shouldContinue: () -> Bool, receive: () throws -> Frame, onFrame: (Frame) -> Void, onError: (Error) -> Void, sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        var failures = 0
        while shouldContinue() {
            do {
                let frame = try receive()
                failures = 0
                onFrame(frame)
            } catch NativeBridgeError.timedOut { continue }
            catch {
                failures = min(failures + 1, 7)
                onError(error)
                sleep(min(2.0, 0.05 * pow(2.0, Double(failures - 1))))
            }
        }
    }
}
