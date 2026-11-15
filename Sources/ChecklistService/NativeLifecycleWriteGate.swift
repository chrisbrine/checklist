import Foundation
import Dispatch

// The semaphore publishes the value before its single reader accesses it. The
// command queue owns the write; the relay worker alone waits and reads it.
private final class NativeLifecycleWriteResult<Value>: @unchecked Sendable {
    var value: Value?
}

extension Coordinator {
    /// Relay workers need a real committed fence before external IO. They wait
    /// off the command queue while a native resumption owns the Core writer.
    func syncNativeLifecycleWrite<Value>(_ work: @escaping @Sendable () -> Value) -> Value {
        dispatchPrecondition(condition: .notOnQueue(queue.dispatchQueue))
        let completed = DispatchSemaphore(value: 0), result = NativeLifecycleWriteResult<Value>()
        queue.async { [self] in
            performNativeLifecycleWrite {
                result.value = work()
                completed.signal()
            }
        }
        completed.wait()
        return result.value!
    }
}
