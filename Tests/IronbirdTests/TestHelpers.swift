@testable import Ironbird
import Testing

actor NotificationBuffer<T: Sendable> {
	private var items: [T] = []

	func append(_ item: T) {
		self.items.append(item)
	}

	func drain() -> [T] {
		let result = self.items
		self.items = []
		return result
	}

	var count: Int { self.items.count }
}

func waitAndDrain<T: Sendable>(_ buffer: NotificationBuffer<T>, expecting count: Int, timeout: Duration = .seconds(5)) async throws -> [T] {
	let deadline = ContinuousClock.now + timeout
	while await buffer.count < count {
		if ContinuousClock.now > deadline { break }
		try await Task.sleep(for: .milliseconds(1))
	}
	return await buffer.drain()
}

struct CacheLimit: TestTrait, TestScoping {
	let testModelLimit: Int
	let testModelWithDescriptionLimit: Int

	init(testModel: Int, testModelWithDescription: Int? = nil) {
		self.testModelLimit = testModel
		self.testModelWithDescriptionLimit = testModelWithDescription ?? testModel
	}

	func provideScope(for test: Test, testCase: Test.Case?, performing function: () async throws -> Void) async throws {
		try await TestModel.$cacheLimit.withValue(self.testModelLimit) {
			try await TestModelWithDescription.$cacheLimit.withValue(self.testModelWithDescriptionLimit) {
				try await function()
			}
		}
	}
}
