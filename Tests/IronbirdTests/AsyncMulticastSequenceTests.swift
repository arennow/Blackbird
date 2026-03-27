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
}

fileprivate actor ShareableArray<T> {
	var array = Array<T>()
	func append(_ t: T) {
		self.array.append(t)
	}
}
