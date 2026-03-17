import Foundation
@testable import Blackbird

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
        try await TestModel.$cacheLimit.withValue(testModelLimit) {
            try await TestModelWithDescription.$cacheLimit.withValue(testModelWithDescriptionLimit) {
                try await body()
            }
        }
    }
}
