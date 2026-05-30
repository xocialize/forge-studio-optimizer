import Foundation

/// A bounded async channel for backpressure between decode and encode stages.
///
/// When the channel is full, the producer suspends until the consumer reads.
/// This prevents unbounded memory growth when the decoder outpaces the encoder.
final class AsyncBoundedChannel<Element: Sendable>: @unchecked Sendable {
    private let capacity: Int
    private var buffer: [Element] = []
    private let lock = NSLock()
    private var producerContinuations: [CheckedContinuation<Void, Never>] = []
    private var consumerContinuations: [CheckedContinuation<Element?, Never>] = []
    private var isFinished = false

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer.reserveCapacity(capacity)
    }

    /// Send an element into the channel. Suspends if the channel is full.
    func send(_ element: Element) async {
        lock.lock()
        if buffer.count < capacity {
            buffer.append(element)
            if let consumer = consumerContinuations.first {
                consumerContinuations.removeFirst()
                let item = buffer.removeFirst()
                lock.unlock()
                consumer.resume(returning: item)
            } else {
                lock.unlock()
            }
            return
        }

        // Channel is full — suspend until space is available
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            producerContinuations.append(continuation)
            lock.unlock()
        }

        lock.lock()
        buffer.append(element)
        if let consumer = consumerContinuations.first {
            consumerContinuations.removeFirst()
            let item = buffer.removeFirst()
            lock.unlock()
            consumer.resume(returning: item)
        } else {
            lock.unlock()
        }
    }

    /// Receive the next element from the channel. Returns nil when finished.
    func receive() async -> Element? {
        lock.lock()
        if let item = buffer.first {
            buffer.removeFirst()
            if let producer = producerContinuations.first {
                producerContinuations.removeFirst()
                lock.unlock()
                producer.resume()
            } else {
                lock.unlock()
            }
            return item
        }

        if isFinished {
            lock.unlock()
            return nil
        }

        // Buffer is empty — suspend until an element is available
        lock.unlock()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
            lock.lock()
            if isFinished && buffer.isEmpty {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            consumerContinuations.append(continuation)
            lock.unlock()
        }
    }

    /// Signal that no more elements will be sent.
    func finish() {
        lock.lock()
        isFinished = true
        let consumers = consumerContinuations
        consumerContinuations.removeAll()
        lock.unlock()

        for consumer in consumers {
            consumer.resume(returning: nil)
        }
    }
}
