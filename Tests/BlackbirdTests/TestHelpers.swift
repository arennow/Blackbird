@testable import Blackbird
import Foundation

protocol TestScoping {
	func run(_ body: () async throws -> Void) async throws
}

struct CacheLimitScope: TestScoping {
	let testModelLimit: Int
	let testModelWithDescriptionLimit: Int

	init(testModel: Int, testModelWithDescription: Int? = nil) {
		self.testModelLimit = testModel
		self.testModelWithDescriptionLimit = testModelWithDescription ?? testModel
	}

	func run(_ body: () async throws -> Void) async throws {
		try await TestModel.$cacheLimit.withValue(self.testModelLimit) {
			try await TestModelWithDescription.$cacheLimit.withValue(self.testModelWithDescriptionLimit) {
				try await body()
			}
		}
	}
}
