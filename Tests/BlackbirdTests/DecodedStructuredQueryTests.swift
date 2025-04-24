//
//  DecodedStructuredQueryTests.swift
//  Blackbird
//
//  Created by Aaron Rennow on 2025-04-23.
//

@testable import Blackbird
import Testing

struct DecodedStructuredQueryTests {
    @Test func selectAll() {
        let dsq = DecodedStructuredQuery(selectColumnSubset: Optional<Array<PartialKeyPath<FakeModel>>>.none)
        #expect(dsq.query == "SELECT * FROM `FakeModel`")
        #expect(dsq.whereArguments == nil)
    }

    @Test func selectColumns() {
        let dsq = DecodedStructuredQuery(selectColumnSubset: [\FakeModel.$name])
        #expect(dsq.query == "SELECT `name` FROM `FakeModel`")
        #expect(dsq.whereArguments == nil)
    }

    @Test func selectAllMatching() {
        let dsq = DecodedStructuredQuery(matching: \FakeModel.$id > 5)
        #expect(dsq.query == "SELECT * FROM `FakeModel` WHERE `id` > ?")
        #expect(dsq.whereArguments as? Array<Blackbird.Value> == [5])
    }

    @Test func selectAllMatchingOrderBy() {
        let dsq = DecodedStructuredQuery(matching: \FakeModel.$id > 5,
                                         orderBy: [.descending(\.$name)])
        #expect(dsq.query == "SELECT * FROM `FakeModel` WHERE `id` > ? ORDER BY `name` DESC")
        #expect(dsq.whereArguments as? Array<Blackbird.Value> == [5])
    }

    @Test func selectAllOrderByLimit() {
        let dsq = DecodedStructuredQuery(orderBy: [.descending(\FakeModel.$name)],
                                         limit: 10)
        #expect(dsq.query == "SELECT * FROM `FakeModel` ORDER BY `name` DESC LIMIT 10")
        #expect(dsq.whereArguments == nil)
    }
}

fileprivate struct FakeModel:BlackbirdModel {
    @BlackbirdColumn var id: Int
    @BlackbirdColumn var name: String
}
