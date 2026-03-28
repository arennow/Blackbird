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

@testable import Ironbird
import Testing

// Each test in this suite is marked as available only on >= 26 OSes because that introduces `Task.immediate`, which is required for us to deterministically wait until the subscriber task is ready to receive values before we send them

@Suite(.timeLimit(.minutes(1)))
struct AsyncMulticastSequenceTests {
	enum EndType: CaseIterable {
		case txFinish, rxCancel
	}

	@available(macOS 26.0, *)
	@Test(arguments: EndType.allCases)
	func receivesValuesSingleSubscriber(endType: EndType) async {
		let sequence = AsyncMulticastSequence<Int>(bufferingPolicy: .unbounded)

		let receivedValues = ShareableArray<Int>()

		let rTask = Task.immediate {
			for await value in sequence {
				await receivedValues.append(value)
			}
		}

		sequence.send(1)
		sequence.send(2)
		sequence.send(3)

		switch endType {
			case .txFinish: sequence.finish()
			case .rxCancel: rTask.cancel()
		}

		await rTask.value

		await #expect(receivedValues.array == [1, 2, 3])
	}

	@available(macOS 26.0, *)
	@Test(arguments: EndType.allCases)
	func receivesValuesMultipleSubscribers(endType: EndType) async {
		let sequence = AsyncMulticastSequence<Int>(bufferingPolicy: .unbounded)

		let receivedValues1 = ShareableArray<Int>()
		let receivedValues2 = ShareableArray<Int>()

		let rTask1 = Task.immediate {
			for await value in sequence {
				await receivedValues1.append(value)
			}
		}

		let rTask2 = Task.immediate {
			for await value in sequence {
				await receivedValues2.append(value)
			}
		}

		sequence.send(1)
		sequence.send(2)
		sequence.send(3)

		switch endType {
			case .txFinish: sequence.finish()
			case .rxCancel: rTask1.cancel(); rTask2.cancel()
		}

		await rTask1.value
		await rTask2.value

		await #expect(receivedValues1.array == [1, 2, 3])
		await #expect(receivedValues2.array == [1, 2, 3])
	}

	@available(macOS 26.0, *)
	@Test(arguments: EndType.allCases)
	func lateSubscriberMissesEarlyValues(endType: EndType) async {
		let sequence = AsyncMulticastSequence<Int>(bufferingPolicy: .unbounded)

		let receivedValues1 = ShareableArray<Int>()
		let receivedValues2 = ShareableArray<Int>()

		let rTask1 = Task.immediate {
			for await value in sequence {
				await receivedValues1.append(value)
			}
		}

		sequence.send(1)

		let rTask2 = Task.immediate {
			for await value in sequence {
				await receivedValues2.append(value)
			}
		}

		sequence.send(2)
		sequence.send(3)

		switch endType {
			case .txFinish: sequence.finish()
			case .rxCancel: rTask1.cancel(); rTask2.cancel()
		}

		await rTask1.value
		await rTask2.value

		await #expect(receivedValues1.array == [1, 2, 3])
		await #expect(receivedValues2.array == [2, 3])
	}

	@Test
	func finishWithZeroSubscribers() {
		let sequence = AsyncMulticastSequence<Int>(bufferingPolicy: .unbounded)
		sequence.finish()
		sequence.finish() // second call should be a no-op
	}

	@available(macOS 26.0, *)
	@Test
	func postFinishSubscriberTerminates() async {
		let sequence = AsyncMulticastSequence<Int>(bufferingPolicy: .unbounded)
		sequence.finish()

		// A subscriber created after finish() should terminate immediately
		let rTask = Task.immediate {
			for await _ in sequence {
				Issue.record("This should be unreachable")
				break
			}
		}
		await rTask.value
	}

	@available(macOS 26.0, *)
	@Test
	func cancelledSubscriberStopsReceiving() async {
		let sequence = AsyncMulticastSequence<Int>(bufferingPolicy: .unbounded)
		let receivedValues1 = ShareableArray<Int>()
		let receivedValues2 = ShareableArray<Int>()

		let rTask1 = Task.immediate {
			for await value in sequence {
				await receivedValues1.append(value)
			}
		}
		let rTask2 = Task.immediate {
			for await value in sequence {
				await receivedValues2.append(value)
			}
		}

		sequence.send(1)

		rTask1.cancel()
		await rTask1.value // wait for rTask1 to fully exit and its entry to be removed

		sequence.send(2)
		sequence.send(3)
		sequence.finish()

		await rTask2.value

		await #expect(receivedValues1.array == [1])
		await #expect(receivedValues2.array == [1, 2, 3])
	}

	@Test
	func bufferingNewestDropsIntermediateValues() async {
		let sequence = AsyncMulticastSequence<Int>(bufferingPolicy: .bufferingNewest(1))
		let receivedValues = ShareableArray<Int>()

		let (subscribedStream, subscribedContinuation) = AsyncStream<Void>.makeStream()
		let (startStream, startContinuation) = AsyncStream<Void>.makeStream()

		// Manually manage the iterator so we can subscribe without calling next() yet.
		// The subscriber signals when it has subscribed, then waits for our go-ahead.
		let rTask = Task {
			var iterator = sequence.makeAsyncIterator()
			subscribedContinuation.finish()
			for await _ in startStream {}
			while let value = await iterator.next() {
				await receivedValues.append(value)
			}
		}

		for await _ in subscribedStream {} // wait until subscribed

		// All sends happen while the subscriber holds an iterator but has not yet called next().
		// With bufferingNewest(1), each send overwrites the previous in the buffer; only 100 survives.
		for i in 1...100 {
			sequence.send(i)
		}
		sequence.finish()
		startContinuation.finish()

		await rTask.value

		await #expect(receivedValues.array == [100])
	}

	@available(macOS 26.0, *)
	@Test
	func concurrentSendsAreThreadSafe() async {
		let sequence = AsyncMulticastSequence<Int>(bufferingPolicy: .unbounded)
		let receivedValues = ShareableArray<Int>()

		let rTask = Task.immediate {
			for await value in sequence {
				await receivedValues.append(value)
			}
		}

		await withTaskGroup(of: Void.self) { group in
			for i in 0..<100 {
				group.addTask { sequence.send(i) }
			}
		}

		sequence.finish()
		await rTask.value

		await #expect(receivedValues.array.count == 100)
	}
}

fileprivate actor ShareableArray<T> {
	var array = Array<T>()
	func append(_ t: T) {
		self.array.append(t)
	}
}
