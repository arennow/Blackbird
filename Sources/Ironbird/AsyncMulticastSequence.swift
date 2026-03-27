//  SPDX-License-Identifier: MIT
//  Copyright 2026 Aaron Rennow
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import Synchronization

final class AsyncMulticastSequence<T: Sendable>: AsyncSequence, Sendable {
	typealias Element = T
	typealias Failure = Never

	typealias TX = AsyncStream<T>.Continuation
	typealias RX = AsyncStream<T>.AsyncIterator

	// TODO: Use a readers-writer lock here instead of a mutex
	private let idsToTX = Mutex(Dictionary<UUID, TX>())
	let bufferingPolicy: TX.BufferingPolicy

	init(bufferingPolicy limit: TX.BufferingPolicy) {
		self.bufferingPolicy = limit
	}

	deinit {
		// Probably not really doing anything useful here since if we're being deinitialized, there shouldn't be any subscribers (they'd hold a retain)
		self.finish()
	}

	func makeAsyncIterator() -> RX {
		let id = UUID()
		let (stream, tx) = AsyncStream.makeStream(of: T.self, bufferingPolicy: self.bufferingPolicy)

		self.idsToTX.withLock { $0[id] = tx }

		tx.onTermination = { @Sendable [weak self] termination in
			// We don't remove it on a finish because:
			// 1. This should only happen through `self.finish`, which will do it anyway
			// 2. That means we'd have to try to recursively acquire the mutex, which is undefined
			if termination != .finished {
				_ = self?.idsToTX.withLock { $0.removeValue(forKey: id) }
			}
		}

		return stream.makeAsyncIterator()
	}

	func send(_ t: T) {
		self.idsToTX.withLock { dict in
			for tx in dict.values {
				tx.yield(t)
			}
		}
	}

	func finish() {
		self.idsToTX.withLock { dict in
			for tx in dict.values {
				tx.finish()
			}
			dict.removeAll()
		}
	}
}
