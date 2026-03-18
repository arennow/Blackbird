@testable import Blackbird
import Testing

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
