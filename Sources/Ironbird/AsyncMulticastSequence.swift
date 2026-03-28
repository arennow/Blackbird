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

public final class AsyncMulticastSequence<T: Sendable>: AsyncSequence, Sendable {
	public typealias Element = T
	public typealias Failure = Never

	typealias TX = AsyncStream<T>.Continuation
	public typealias RX = AsyncStream<T>.AsyncIterator

	private struct State {
		var isFinished = false
		var idsToTX: [UUID: TX] = [:]
	}

	// TODO: Use a readers-writer lock here instead of a mutex
	private let state = Mutex(State())
	let bufferingPolicy: TX.BufferingPolicy

	init(bufferingPolicy limit: TX.BufferingPolicy) {
		self.bufferingPolicy = limit
	}

	deinit {
		// Probably not really doing anything useful here since if we're being deinitialized, there shouldn't be any subscribers (they'd hold a retain)
		self.finish()
	}

	public func makeAsyncIterator() -> RX {
		let id = UUID()
		let (stream, tx) = AsyncStream.makeStream(of: T.self, bufferingPolicy: self.bufferingPolicy)

		// Set onTermination before inserting into the dict so that if the task is cancelled
		// in the narrow window between them, the handler is already registered and will clean up.
		tx.onTermination = { @Sendable [weak self] termination in
			// We don't remove it on a finish because:
			// 1. This should only happen through `self.finish`, which will do it anyway
			// 2. That means we'd have to try to recursively acquire the mutex, which is undefined
			if termination != .finished {
				_ = self?.state.withLock { $0.idsToTX.removeValue(forKey: id) }
			}
		}

		let alreadyFinished: Bool = self.state.withLock { s in
			if s.isFinished { return true }
			s.idsToTX[id] = tx
			return false
		}

		if alreadyFinished {
			tx.finish()
		}

		return stream.makeAsyncIterator()
	}

	func send(_ t: T) {
		self.state.withLock { s in
			for tx in s.idsToTX.values {
				tx.yield(t)
			}
		}
	}

	func finish() {
		self.state.withLock { s in
			if s.isFinished { return }
			s.isFinished = true
			for tx in s.idsToTX.values {
				tx.finish()
			}
			s.idsToTX.removeAll()
		}
	}
}
