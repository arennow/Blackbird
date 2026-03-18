//
//           /\
//          |  |                       Blackbird
//          |  |
//         .|  |.       https://github.com/marcoarment/Blackbird
//         $    $
//        /$    $\          Copyright 2022–2023 Marco Arment
//       / $|  |$ \          Released under the MIT License
//      .__$|  |$__.
//           \/
//
//  BlackbirdTests.swift
//  Created by Marco Arment on 11/20/22.
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

@testable import Blackbird
import Foundation
import Loggable
import Semaphore
import Testing

final class BlackbirdTests: IBLoggable {
	var sqliteFilename = ""

	init() throws {
		let dir = FileManager.default.temporaryDirectory.path
		self.sqliteFilename = "\(dir)/test\(Int64.random(in: 0..<Int64.max)).sqlite"
	}

	deinit {
		if sqliteFilename != "", sqliteFilename != ":memory:", FileManager.default.fileExists(atPath: sqliteFilename) {
			for path in Blackbird.Database.allFilePaths(for: sqliteFilename) {
				try? FileManager.default.removeItem(atPath: path)
			}
		}
	}

	@Test
	func valueConversions() throws {
		let n = try #require(Blackbird.Value.fromSQLiteLiteral("NULL"))
		#expect(n == .null)
		#expect(n.intValue == nil)
		#expect(n.doubleValue == nil)
		#expect(n.stringValue == nil)
		#expect(n.dataValue == nil)
		#expect((try Blackbird.Value.fromAny(nil)) == n)
		#expect((try Blackbird.Value.fromAny(NSNull())) == n)

		let i = try #require(Blackbird.Value.fromSQLiteLiteral("123456"))
		#expect(i == .integer(123_456))
		#expect(i.intValue == 123_456)
		#expect(i.doubleValue == 123_456.0)
		#expect(i.stringValue == "123456")
		#expect(i.dataValue == "123456".data(using: .utf8))
		#expect((try Blackbird.Value.fromAny(123_456)) == i)
		#expect((try Blackbird.Value.fromAny(Int(123_456))) == i)
		#expect((try Blackbird.Value.fromAny(Int8(123))) == .integer(123))
		#expect((try Blackbird.Value.fromAny(Int16(12_345))) == .integer(12_345))
		#expect((try Blackbird.Value.fromAny(Int32(123_456))) == i)
		#expect((try Blackbird.Value.fromAny(Int64(123_456))) == i)
		#expect((try Blackbird.Value.fromAny(UInt8(123))) == .integer(123))
		#expect((try Blackbird.Value.fromAny(UInt16(12_345))) == .integer(12_345))
		#expect((try Blackbird.Value.fromAny(UInt32(123_456))) == i)
		#expect(throws: (any Swift.Error).self) { _ = try Blackbird.Value.fromAny(UInt(123_456)) }
		#expect(throws: (any Swift.Error).self) { _ = try Blackbird.Value.fromAny(UInt64(123_456)) }
		#expect((try Blackbird.Value.fromAny(false)) == .integer(0))
		#expect((try Blackbird.Value.fromAny(true)) == .integer(1))

		let d = try #require(Blackbird.Value.fromSQLiteLiteral("123456.789"))
		#expect(d == .double(123_456.789))
		#expect(d.intValue == 123_456)
		#expect(d.doubleValue == 123_456.789)
		#expect(d.stringValue == "123456.789")
		#expect(d.dataValue == "123456.789".data(using: .utf8))
		#expect((try Blackbird.Value.fromAny(123_456.789)) == d)
		#expect((try Blackbird.Value.fromAny(Float(123_456.789))) == .double(123_456.7890625))
		#expect((try Blackbird.Value.fromAny(Double(123_456.789))) == d)

		let s = try #require(Blackbird.Value.fromSQLiteLiteral("'abc\"🌊\"d''éƒ'''"))
		#expect(s == .text("abc\"🌊\"d'éƒ'"))
		#expect(s.intValue == nil)
		#expect(s.doubleValue == nil)
		#expect(s.stringValue == "abc\"🌊\"d'éƒ'")
		#expect(s.dataValue == "abc\"🌊\"d'éƒ'".data(using: .utf8))
		#expect((try Blackbird.Value.fromAny("abc\"🌊\"d'éƒ'")) == s)

		let b = try #require(Blackbird.Value.fromSQLiteLiteral("X\'616263F09F8C8A64C3A9C692\'"))
		#expect(b == .data(try #require("abc🌊déƒ".data(using: .utf8))))
		#expect(b.intValue == nil)
		#expect(b.doubleValue == nil)
		#expect(b.stringValue == "abc🌊déƒ")
		#expect(b.dataValue == "abc🌊déƒ".data(using: .utf8))
		#expect((try Blackbird.Value.fromAny("abc🌊déƒ".data(using: .utf8))) == b)

		let date = Date()
		#expect((try Blackbird.Value.fromAny(date)) == .double(date.timeIntervalSince1970))

		let url = try #require(URL(string: "https://www.marco.org/"))
		#expect((try Blackbird.Value.fromAny(url)) == .text(url.absoluteString))
	}

	@Test
	func openDB() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		try await TestModel.resolveSchema(in: db)
		try await SchemaChangeAddColumnsInitial.resolveSchema(in: db)
		try await SchemaChangeRebuildTableInitial.resolveSchema(in: db)
		await db.close()
	}

	@Test
	func whereIDIN() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename)
		let count = min(TestData.URLs.count, TestData.titles.count, TestData.descriptions.count)

		try await db.transaction { core in
			for i in 0..<count {
				let m = TestModelWithDescription(id: i, url: TestData.URLs[i], title: TestData.titles[i], description: TestData.descriptions[i])
				try m.writeIsolated(to: db, core: core)
			}
		}
		db.debugPrintCachePerformanceMetrics()

		var giantIDBatch = Array(0...(db.maxQueryVariableCount * 2))
		giantIDBatch.shuffle()
		let all = try await TestModelWithDescription.read(from: db, primaryKeys: giantIDBatch)
		#expect(all.count == count)
		db.debugPrintCachePerformanceMetrics()

		var idSet = Set<Int>()
		for m in all {
			idSet.insert(m.id)
		}
		for i in 0..<count {
			#expect(idSet.contains(i))
		}

		let pkOrder = [999, 1, 78, 128, 63, 100_000, 571]
		let sorted = try await TestModelWithDescription.read(from: db, primaryKeys: pkOrder, preserveOrder: true)
		#expect(sorted[0].id == 999)
		#expect(sorted[1].id == 1)
		#expect(sorted[2].id == 78)
		#expect(sorted[3].id == 128)
		#expect(sorted[4].id == 63)
		#expect(sorted[5].id == 571)

		db.debugPrintCachePerformanceMetrics()
	}

	@Test
	func queries() async throws {
		let allFilenames = Blackbird.Database.allFilePaths(for: self.sqliteFilename)
		Self.logger.debug("SQLite filenames:\n\(allFilenames.joined(separator: "\n"))")

		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintQueryParameterValues, .debugPrintEveryReportedChange])
		let count = min(TestData.URLs.count, TestData.titles.count, TestData.descriptions.count)

		try await db.transaction { core in
			for i in 0..<count {
				let m = TestModelWithDescription(id: i, url: TestData.URLs[i], title: TestData.titles[i], description: TestData.descriptions[i])
				try m.writeIsolated(to: db, core: core)
			}
		}

		for i: Int64 in 1..<10 {
			try await MulticolumnPrimaryKeyTest(userID: i, feedID: i, episodeID: i).write(to: db)
		}

		let countReturned = try await TestModelWithDescription.count(in: db)
		#expect(countReturned == 1000)

		let countReturnedMatching = try await TestModelWithDescription.count(in: db, matching: \.$id >= 500)
		#expect(countReturnedMatching == 500)

		let the = try await TestModelWithDescription.read(from: db, sqlWhere: "title LIKE 'the%'")
		#expect(the.count == 231)

		let paramFormat1Results = try await TestModelWithDescription.read(from: db, sqlWhere: "title LIKE ?", "the%")
		#expect(paramFormat1Results.count == 231)

		let paramFormat2Results = try await TestModelWithDescription.read(from: db, sqlWhere: "title LIKE ?", arguments: ["the%"])
		#expect(paramFormat2Results.count == 231)

		let paramFormat3Results = try await TestModelWithDescription.read(from: db, sqlWhere: "title LIKE :title", arguments: [":title": "the%"])
		#expect(paramFormat3Results.count == 231)

		let paramFormat4Results = try await TestModelWithDescription.read(from: db, sqlWhere: "\(\TestModelWithDescription.$title) LIKE :title", arguments: [":title": "the%"])
		#expect(paramFormat4Results.count == 231)

		// Structured queries
		let first100 = try await TestModelWithDescription.read(from: db, orderBy: .ascending(\.$id), limit: 100)
		let matches0a1 = try await TestModelWithDescription.read(from: db, matching: \.$id == 123)
		let matches0a2 = try await TestModelWithDescription.read(from: db, primaryKey: 123)
		let matches0a3 = try await TestModelWithDescription.query(in: db, columns: [\.$title], primaryKey: 123)
		let matches0b = try await TestModelWithDescription.read(from: db, matching: \.$id == 123 && \.$title == "Hi" || \.$id > 2)
		let matches0c = try await TestModelWithDescription.read(from: db, matching: \.$url != nil)
		let matches0d = try await TestModelWithDescription.read(from: db, matching: .valueIn(\.$id, [1, 2, 3]))
		let matches0e = try await TestModelWithDescription.read(from: db, matching: .like(\.$title, "the%"))
		let matches0f = try await TestModelWithDescription.read(from: db, matching: .like(\.$title, "% % % % %"))
		let matches0g = try await TestModelWithDescription.read(from: db, matching: !.valueIn(\.$id, [1, 2, 3]))

		#expect(first100.count == 100)
		#expect(first100.first?.id == 0)
		#expect(first100.last?.id == 99)
		#expect(matches0a1.count == 1)
		#expect(matches0a1.first?.id == 123)
		#expect(matches0a2 != nil)
		#expect(matches0a2?.id == 123)
		#expect(matches0a3 != nil)
		#expect(matches0a3?[\.$title] == matches0a2?.title)
		#expect(matches0b.count == 997)
		#expect(matches0c.count == 1000)
		#expect(matches0d.count == 3)
		#expect(matches0e.count == 231)
		#expect(matches0f.count == 235)
		#expect(matches0g.count == 997)

		try await MulticolumnPrimaryKeyTest.update(in: db, set: [\.$episodeID: 5], forMulticolumnPrimaryKeys: [[1, 1, 1], [2, 2, 2], [3, 1, 1]])
		let multiID1 = try await MulticolumnPrimaryKeyTest.read(from: db, multicolumnPrimaryKey: [1, 1, 5])
		let multiID2 = try await MulticolumnPrimaryKeyTest.read(from: db, multicolumnPrimaryKey: [2, 2, 5])
		let multiID2b = try await MulticolumnPrimaryKeyTest.query(in: db, columns: [\.$userID], multicolumnPrimaryKey: [2, 2, 5])
		let multiID3 = try await MulticolumnPrimaryKeyTest.read(from: db, multicolumnPrimaryKey: [3, 3, 5])
		#expect(multiID1?.episodeID == 5)
		#expect(multiID2?.episodeID == 5)
		#expect(multiID3 == nil)
		#expect(multiID2b != nil)
		#expect(multiID2b?[\.$userID] == multiID2?.userID)

		try await TestModelWithDescription.update(in: db, set: [\.$title: "(new)"], forPrimaryKeys: [1, 2, 3])
		let id1 = try await TestModelWithDescription.read(from: db, id: 1)
		let id2 = try await TestModelWithDescription.read(from: db, id: 2)
		let id3 = try await TestModelWithDescription.read(from: db, id: 3)
		#expect(id1?.title == "(new)")
		#expect(id2?.title == "(new)")
		#expect(id3?.title == "(new)")

		var id42 = try await TestModelWithDescription.read(from: db, id: 42)
		#expect(id42 != nil)
		#expect(id42?.id == 42)

		id42?.url = nil
		try await id42?.write(to: db)

		try #require(await id42?.delete(from: db))
		let id42AfterDelete = try await TestModelWithDescription.read(from: db, id: 42)
		#expect(id42AfterDelete == nil)

		let id43 = try await TestModelWithDescription.read(from: db, matching: \.$id == 43).first
		#expect(id43 != nil)
		#expect(id43?.id == 43)
		try await TestModelWithDescription.delete(from: db, matching: \.$id == 43)
		let id43AfterDelete = try await TestModelWithDescription.read(from: db, matching: \.$id == 43).first
		#expect(id43AfterDelete == nil)

		let matches1 = try await TestModelWithDescription.read(from: db, orderBy: .descending(\.$title), .ascending(\.$id), limit: 1)
		#expect(matches1.first?.title == "the memory palace")

		let matches = try await TestModelWithDescription.read(from: db, matching: \.$title == "Omnibus")
		#expect(matches.count == 1)
		#expect(matches.first?.title == "Omnibus")

		let rows = try await TestModelWithDescription.query(in: db, columns: [\.$id, \.$title, \.$url], matching: \.$title == "Omnibus")
		#expect(rows.count == 1)
		#expect(rows.first?.count == 3)

		let omnibusID = try #require(rows.first?[\.$id])
		#expect(rows.first?[\.$url] != nil)
		#expect(rows.first?[\.$title] == "Omnibus")

		try await TestModelWithDescription.update(in: db, set: [\.$url: nil], matching: \.$id == omnibusID)

		let rowsWithNilURL = try await TestModelWithDescription.query(in: db, columns: [\.$id, \.$url], matching: \.$url == nil)
		#expect(rowsWithNilURL.first?[\.$id] == omnibusID)
		#expect(rowsWithNilURL.first?[\.$url] == nil)

		try await TestModelWithDescription.delete(from: db, matching: \.$url == nil)
		let leftovers1 = try await TestModelWithDescription.read(from: db, matching: \.$url == nil)
		let leftovers2 = try await TestModelWithDescription.read(from: db, matching: \.$id == omnibusID)
		#expect(leftovers1.isEmpty)
		#expect(leftovers2.isEmpty)

		db.debugPrintCachePerformanceMetrics()
	}

	@Test
	func updateExpressions() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange, .debugPrintQueryParameterValues])

		try await TestModelForUpdateExpressions(id: 1, i: 1, d: 1.5).write(to: db)
		try await TestModelForUpdateExpressions(id: 2, i: 2, d: 2.5).write(to: db)
		try await TestModelForUpdateExpressions(id: 3, i: 3, d: 3.5).write(to: db)

		try await TestModelForUpdateExpressions.update(in: db, set: [\.$i: \.$i + 100], matching: \.$id == 1)

		let testModel1 = try await TestModelForUpdateExpressions.read(from: db, id: 1)
		let testModel2 = try await TestModelForUpdateExpressions.read(from: db, id: 2)
		let testModel3 = try await TestModelForUpdateExpressions.read(from: db, id: 3)

		#expect(testModel1?.id == 1)
		#expect(testModel1?.i == 101)
		#expect(testModel2?.id == 2)
		#expect(testModel2?.i == 2)
		#expect(testModel3?.id == 3)
		#expect(testModel3?.i == 3)

		try await TestModelForUpdateExpressions.update(in: db, set: [\.$d: \.$i + 10], matching: \.$id == 2)

		let a = try await TestModelForUpdateExpressions.read(from: db, id: 2)
		#expect(a?.i == 2)
		#expect(a?.d == 12)

		try await TestModelForUpdateExpressions.update(in: db, set: [\.$i: !\.$i], matching: \.$id == 2)
		let a2 = try await TestModelForUpdateExpressions.read(from: db, id: 2)
		#expect(a2?.i == 0)

		try await TestModelForUpdateExpressions.update(in: db, set: [\.$i: !\.$i], matching: \.$id == 2)
		let a3 = try await TestModelForUpdateExpressions.read(from: db, id: 2)
		#expect(a3?.i == 1)

		try await TestModelForUpdateExpressions.update(in: db, set: [
			\.$d: 5.5,
			\.$i: \.$i * 10,
		], matching: \.$id == 2)
		let a4 = try await TestModelForUpdateExpressions.read(from: db, id: 2)
		#expect(a4?.i == 10)
		#expect(a4?.d == 5.5)
	}

	@Test
	func columnTypes() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange, .debugPrintQueryParameterValues])
		try await TypeTest.resolveSchema(in: db)

		let now = Date()

		let tt = TypeTest(id: Int64.max, typeIntNull: nil, typeIntNotNull: Int64.min, typeTextNull: nil, typeTextNotNull: "textNotNull!", typeDoubleNull: nil, typeDoubleNotNull: Double.pi, typeDataNull: nil, typeDataNotNull: try #require("dataNotNull!".data(using: .utf8)), typeIntEnum: .two, typeIntEnumNullWithValue: .one, typeStringEnum: .one, typeStringEnumNullWithValue: .two, typeIntNonZeroEnum: .two, typeIntNonZeroEnumNullWithValue: .two, typeStringNonEmptyEnum: .one, typeStringNonEmptyEnumNullWithValue: .two, typeURLNull: nil, typeURLNotNull: try #require(URL(string: "https://marco.org/")), typeDateNull: nil, typeDateNotNull: now)
		try await tt.write(to: db)

		let read = try await TypeTest.read(from: db, id: Int64.max)
		#expect(read != nil)
		#expect(read?.id == Int64.max)
		#expect(read?.typeIntNull == nil)
		#expect(read?.typeIntNotNull == Int64.min)
		#expect(read?.typeTextNull == nil)
		#expect(read?.typeTextNotNull == "textNotNull!")
		#expect(read?.typeDoubleNull == nil)
		#expect(read?.typeDoubleNotNull == Double.pi)
		#expect(read?.typeDataNull == nil)
		#expect(read?.typeDataNotNull == "dataNotNull!".data(using: .utf8))
		#expect(read?.typeIntEnum == .two)
		#expect(read?.typeIntEnumNull == nil)
		#expect(read?.typeIntEnumNullWithValue == .one)
		#expect(read?.typeStringEnum == .one)
		#expect(read?.typeStringEnumNull == nil)
		#expect(read?.typeStringEnumNullWithValue == .two)
		#expect(read?.typeIntNonZeroEnum == .two)
		#expect(read?.typeIntNonZeroEnumWithDefault == .one)
		#expect(read?.typeIntNonZeroEnumNull == nil)
		#expect(read?.typeIntNonZeroEnumNullWithValue == .two)
		#expect(read?.typeStringNonEmptyEnum == .one)
		#expect(read?.typeStringNonEmptyEnumWithDefault == .two)
		#expect(read?.typeStringNonEmptyEnumNull == nil)
		#expect(read?.typeStringNonEmptyEnumNullWithValue == .two)
		#expect(read?.typeURLNull == nil)
		#expect(read?.typeURLNotNull == URL(string: "https://marco.org/"))
		#expect(read?.typeDateNull == nil)
		#expect(read?.typeDateNotNull.timeIntervalSince1970 == now.timeIntervalSince1970)

		let results1 = try await TypeTest.read(from: db, sqlWhere: "typeIntEnum = ?", TypeTest.RepresentableIntEnum.one)
		#expect(results1.count == 0)

		let results2 = try await TypeTest.read(from: db, sqlWhere: "typeIntEnum = ?", TypeTest.RepresentableIntEnum.two)
		#expect(results2.count == 1)
		#expect(results2.first?.id == Int64.max)

		let results3 = try await TypeTest.read(from: db, sqlWhere: "typeStringEnum = ?", TypeTest.RepresentableStringEnum.two)
		#expect(results3.count == 0)

		let results4 = try await TypeTest.read(from: db, sqlWhere: "typeStringEnum = ?", TypeTest.RepresentableStringEnum.one)
		#expect(results4.count == 1)
		#expect(try #require(results4.first?.id == Int64.max))
	}

	@Test
	func jsonSerialization() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		let count = min(TestData.URLs.count, TestData.titles.count, TestData.descriptions.count)
		try await db.transaction { core in
			for i in 0..<count {
				let m = TestModelWithDescription(id: i, url: TestData.URLs[i], title: TestData.titles[i], description: TestData.descriptions[i])
				try m.writeIsolated(to: db, core: core)
			}
		}

		let the = try await TestModelWithDescription.read(from: db, sqlWhere: "title LIKE 'the%'")
		#expect(the.count == 231)

		let results = [
			TestModel(id: 1, title: TestData.randomTitle, url: TestData.randomURL, nonColumn: TestData.randomString(length: 4)),
			TestModel(id: 2, title: TestData.randomTitle, url: TestData.randomURL, nonColumn: TestData.randomString(length: 4)),
			TestModel(id: 3, title: TestData.randomTitle, url: TestData.randomURL, nonColumn: TestData.randomString(length: 4)),
			TestModel(id: 4, title: TestData.randomTitle, url: TestData.randomURL, nonColumn: TestData.randomString(length: 4)),
		]

		let encoder = JSONEncoder()
		let json = try encoder.encode(results)
		Self.logger.debug("json: \(String(data: json, encoding: .utf8), default: "<INVALID JSON>")")

		let decoder = JSONDecoder()
		let decoded = try decoder.decode([TestModel].self, from: json)
		#expect(decoded == results)

		for i in 0..<3 {
			let m1 = results[i]
			let m2 = decoded[i]
			#expect(m1.id == m2.id)
			#expect(m1.title == m2.title)
			#expect(m1.url == m2.url)
			#expect(m1.nonColumn == m2.nonColumn)
		}
	}

	@Test
	func multiStatements() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		try await TestModel.resolveSchema(in: db)
		try await db.execute("PRAGMA user_version = 234; UPDATE TestModel SET url = NULL")
		let userVersion = try await db.query("PRAGMA user_version").first?["user_version"]
		#expect(userVersion != nil)
		#expect(userVersion?.intValue == 234)
	}

	private func runHeavyWorkload(sqliteFilename: String) async throws {
		let db = try Blackbird.Database(path: sqliteFilename)

		// big block of writes to populate the DB
		try await db.transaction { core in
			for i in 0..<1000 {
				let t = TestModel(id: Int64(i), title: TestData.randomTitle, url: TestData.randomURL, nonColumn: TestData.randomDescription)
				try t.writeIsolated(to: db, core: core)
			}
		}

		// random reads/writes interleaved
		for _ in 0..<500 {
			// Attempt 10 random reads
			for _ in 0..<10 {
				_ = try await TestModel.read(from: db, id: Int64.random(in: 0..<1000))
			}

			// Random UPDATE
			if var r = try await TestModel.read(from: db, id: Int64.random(in: 0..<1000)) {
				r.title = TestData.randomTitle
				try await r.write(to: db)
			}

			// Random INSERT
			let t = TestModel(id: TestData.randomInt64(), title: TestData.randomTitle, url: TestData.randomURL, nonColumn: TestData.randomDescription)
			try await t.write(to: db)
		}

		db.debugPrintCachePerformanceMetrics()
		await db.close()
	}

	@Test
	func heavyWorkload() async throws {
		try await self.runHeavyWorkload(sqliteFilename: self.sqliteFilename)
	}

	@Test
	func memoryDB() async throws {
		try await self.runHeavyWorkload(sqliteFilename: ":memory:")
	}

	@Test
	func transactionRollback() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])

		let id = TestData.randomInt64()
		let originalTitle = TestData.randomTitle
		let t = TestModel(id: id, title: originalTitle, url: TestData.randomURL, nonColumn: TestData.randomString(length: 32))
		try await t.write(to: db)

		try await db.transaction { _ in
		}

		let retVal0 = try await db.transaction { _ in
			"test0"
		}
		#expect(retVal0 == "test0")

		let retVal1Void = try await db.cancellableTransaction { _ in
			throw Blackbird.Error.cancelTransaction
		}
		switch retVal1Void {
			case .rolledBack: #expect(Bool(true))
			case .committed: Issue.record("Expected rollback")
		}

		let cancelTransaction = true
		let retVal1 = try await db.cancellableTransaction { core in
			var t = t
			t.title = "new title"
			try t.writeIsolated(to: db, core: core)

			let title = try core.query("SELECT title FROM TestModel WHERE id = ?", id).first?["title"]?.stringValue
			#expect(title == "new title")

			if (cancelTransaction) {
				throw Blackbird.Error.cancelTransaction
			} else {
				return "Test"
			}
		}

		switch retVal1 {
			case .rolledBack: #expect(Bool(true))
			case .committed: Issue.record("Expected rollback")
		}

		let title = try #require(await db.query("SELECT title FROM TestModel WHERE id = ?", id).first?["title"]?.stringValue)
		#expect(title == originalTitle)

		let retVal2 = try await db.cancellableTransaction { core in
			var t = t
			t.title = "new title"
			try t.writeIsolated(to: db, core: core)

			let title = try core.query("SELECT title FROM TestModel WHERE id = ?", id).first?["title"]?.stringValue
			#expect(title == "new title")

			return "Test"
		}

		switch retVal2 {
			case .rolledBack: Issue.record("Expected commit")
			case .committed: #expect(Bool(true))
		}

		let title2 = try #require(await db.query("SELECT title FROM TestModel WHERE id = ?", id).first?["title"]?.stringValue)
		#expect(title2 == "new title")
	}

	@Test
	func concurrentAccessToSameDBFile() async throws {
		let mem1 = try Blackbird.Database.inMemoryDatabase(options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		#expect(throws: Never.self) { try Blackbird.Database.inMemoryDatabase() }
		try await mem1.execute("PRAGMA user_version = 1") // so mem1 doesn't get deallocated until after this

		let db1 = try Blackbird.Database(path: self.sqliteFilename)
		#expect(throws: (any Swift.Error).self) { try Blackbird.Database(path: self.sqliteFilename) }
		await db1.close()
		#expect(throws: Never.self) { try Blackbird.Database(path: self.sqliteFilename) } // should be OK to reuse a path after .close()

		await #expect(throws: (any Swift.Error).self) { try await db1.execute("PRAGMA user_version = 1") } // test throwing errors for accessing a closed DB
	}

	@Test
	func codingKeys() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])

		let id = TestData.randomInt64()
		let title = TestData.randomTitle
		let desc = TestData.randomDescription

		let t = TestCodingKeys(id: id, title: title, description: desc)
		try await t.write(to: db)

		let readBack = try await TestCodingKeys.read(from: db, id: id)
		#expect(readBack != nil)
		#expect(readBack?.id == id)
		#expect(readBack?.title == title)
		#expect(readBack?.description == desc)

		let jsonEncoder = JSONEncoder()
		let data = try jsonEncoder.encode(readBack)
		let decoder = JSONDecoder()
		let decoded = try decoder.decode(TestCodingKeys.self, from: data)
		#expect(decoded.id == id)
		#expect(decoded.title == title)
		#expect(decoded.description == desc)

		let custom = try decoder.decode(TestCustomDecoder.self, from: try #require("""
		    {"idStr":"123","nameStr":"abc","thumbStr":"https://google.com/"}
		""".data(using: .utf8)))
		#expect(custom.id == 123)
		#expect(custom.name == "abc")
		#expect(custom.thumbnail == URL(string: "https://google.com/"))

		try await custom.write(to: db)
	}

	@Test
	func schemaChangeAddPrimaryKeyColumn() async throws {
		let userID = TestData.randomInt64()
		let feedID = TestData.randomInt64()
		let episodeID = TestData.randomInt64()

		var db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		try await SchemaChangeAddPrimaryKeyColumnInitial(userID: userID, feedID: feedID, subscribed: true).write(to: db)
		await db.close()

		db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		let newInstance = SchemaChangeAddPrimaryKeyColumnChanged(userID: userID, feedID: feedID, episodeID: episodeID, subscribed: false)
		try await newInstance.write(to: db)

		let firstInstance = try await SchemaChangeAddPrimaryKeyColumnChanged.read(from: db, multicolumnPrimaryKey: [userID, feedID, 0])
		let secondInstance = try await SchemaChangeAddPrimaryKeyColumnChanged.read(from: db, multicolumnPrimaryKey: [userID, feedID, episodeID])
		let thirdInstance = try await SchemaChangeAddPrimaryKeyColumnChanged.read(from: db, multicolumnPrimaryKey: ["userID": userID, "feedID": feedID, "episodeID": episodeID])

		#expect(firstInstance != nil)
		#expect(secondInstance != nil)
		#expect(thirdInstance != nil)
		#expect(firstInstance?.episodeID == 0)
		#expect(secondInstance?.episodeID == episodeID)
		#expect(thirdInstance?.episodeID == episodeID)
		#expect(firstInstance?.subscribed == true)
		#expect(secondInstance?.subscribed == false)
		#expect(thirdInstance?.subscribed == false)
	}

	@Test
	func schemaChangeAddColumns() async throws {
		let id = TestData.randomInt64()
		let title = TestData.randomTitle

		var db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		try await SchemaChangeAddColumnsInitial(id: id, title: title).write(to: db)
		await db.close()

		db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		let newInstance = SchemaChangeAddColumnsChanged(id: TestData.randomInt64(not: id), title: TestData.randomTitle, description: "Custom", url: TestData.randomURL, art: TestData.randomData(length: 2048))
		try await newInstance.write(to: db)

		let modifiedInstance = try await SchemaChangeAddColumnsChanged.read(from: db, id: id)
		#expect(modifiedInstance != nil)
		#expect(modifiedInstance?.title == title)

		let readNewInstance = try await SchemaChangeAddColumnsChanged.read(from: db, id: newInstance.id)
		#expect(readNewInstance != nil)
		#expect(readNewInstance?.description == "Custom")
	}

	@Test
	func schemaChangeDropColumns() async throws {
		let id = TestData.randomInt64()
		let title = TestData.randomTitle

		var db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		try await SchemaChangeAddColumnsChanged(id: id, title: title, description: "Custom", url: TestData.randomURL, art: TestData.randomData(length: 2048)).write(to: db)
		await db.close()

		db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		let newInstance = SchemaChangeAddColumnsInitial(id: TestData.randomInt64(not: id), title: TestData.randomTitle)
		try await newInstance.write(to: db)

		let modifiedInstance = try await SchemaChangeAddColumnsInitial.read(from: db, id: id)
		#expect(modifiedInstance != nil)
		#expect(modifiedInstance?.title == title)
	}

	@Test
	func schemaChangeAddIndex() async throws {
		let id = TestData.randomInt64()
		let title = TestData.randomTitle

		var db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		try await SchemaChangeAddIndexInitial(id: id, title: title).write(to: db)
		await db.close()

		db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		let newInstance = SchemaChangeAddIndexChanged(id: TestData.randomInt64(not: id), title: TestData.randomTitle)
		try await newInstance.write(to: db)

		let modifiedInstance = try await SchemaChangeAddIndexChanged.read(from: db, id: id)
		#expect(modifiedInstance != nil)
		#expect(modifiedInstance?.title == title)
	}

	@Test
	func schemaChangeDropIndex() async throws {
		let id = TestData.randomInt64()
		let title = TestData.randomTitle

		var db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		try await SchemaChangeAddIndexChanged(id: id, title: title).write(to: db)
		await db.close()

		db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		let newInstance = SchemaChangeAddIndexInitial(id: TestData.randomInt64(not: id), title: TestData.randomTitle)
		try await newInstance.write(to: db)

		let modifiedInstance = try await SchemaChangeAddIndexInitial.read(from: db, id: id)
		#expect(modifiedInstance != nil)
		#expect(modifiedInstance?.title == title)
	}

	@Test
	func schemaChangeRebuildTable() async throws {
		let id = TestData.randomInt64()
		let title = TestData.randomTitle

		var db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		try await SchemaChangeRebuildTableInitial(id: id, title: title, flags: 15).write(to: db)
		await db.close()

		db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		let newInstance = SchemaChangeRebuildTableChanged(id: TestData.randomInt64(not: id), title: TestData.randomTitle, flags: "{1,0}", description: TestData.randomDescription)
		try await newInstance.write(to: db)

		let modifiedInstance = try await SchemaChangeRebuildTableChanged.read(from: db, id: id)
		#expect(modifiedInstance != nil)
		#expect(modifiedInstance?.title == title)
		#expect(modifiedInstance?.description == "")
		#expect(modifiedInstance?.flags == "15")
	}

	@Test
	func columnChanges() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange])
		let db2 = try Blackbird.Database.inMemoryDatabase()

		var t = TestModel(id: TestData.randomInt64(), title: "Original Title", url: TestData.randomURL)
		#expect(t.$id.hasChanged(in: db))
		#expect(t.$title.hasChanged(in: db))
		#expect(t.$url.hasChanged(in: db))
		#expect(t.changedColumns(in: db) == Blackbird.ColumnNames(["id", "title", "url"]))
		#expect(t.$id.hasChanged(in: db2))
		#expect(t.$title.hasChanged(in: db2))
		#expect(t.$url.hasChanged(in: db2))
		#expect(t.changedColumns(in: db2) == Blackbird.ColumnNames(["id", "title", "url"]))

		try await t.write(to: db)

		#expect(!t.$id.hasChanged(in: db))
		#expect(!t.$title.hasChanged(in: db))
		#expect(!t.$url.hasChanged(in: db))
		#expect(t.changedColumns(in: db).isEmpty)
		#expect(t.$id.hasChanged(in: db2))
		#expect(t.$title.hasChanged(in: db2))
		#expect(t.$url.hasChanged(in: db2))
		#expect(t.changedColumns(in: db2) == Blackbird.ColumnNames(["id", "title", "url"]))

		t.title = "Updated Title"

		#expect(!t.$id.hasChanged(in: db))
		#expect(t.$title.hasChanged(in: db))
		#expect(!t.$url.hasChanged(in: db))
		#expect(t.changedColumns(in: db) == Blackbird.ColumnNames(["title"]))

		try await t.write(to: db)

		#expect(!t.$id.hasChanged(in: db))
		#expect(!t.$title.hasChanged(in: db))
		#expect(!t.$url.hasChanged(in: db))
		#expect(t.changedColumns(in: db).isEmpty)

		var t2 = try #require(await TestModel.read(from: db, id: t.id))
		#expect(!t2.$id.hasChanged(in: db))
		#expect(!t2.$title.hasChanged(in: db))
		#expect(!t2.$url.hasChanged(in: db))
		#expect(t2.changedColumns(in: db).isEmpty)

		t2.title = "Third Title"
		#expect(!t2.$id.hasChanged(in: db))
		#expect(t2.$title.hasChanged(in: db))
		#expect(!t2.$url.hasChanged(in: db))
		#expect(t2.changedColumns(in: db) == Blackbird.ColumnNames(["title"]))

		try await t2.write(to: db)

		#expect(!t.$id.hasChanged(in: db))
		#expect(!t.$title.hasChanged(in: db))
		#expect(!t.$url.hasChanged(in: db))
		#expect(t.changedColumns(in: db).isEmpty)
	}

	@Test
	func changeNotifications() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintEveryReportedChange, .debugPrintQueryParameterValues])

		try await TestModel.resolveSchema(in: db)
		try await TestModelWithDescription.resolveSchema(in: db)

		actor ChangeState {
			var expectedTable: String? = nil
			var expectedKeys: Blackbird.PrimaryKeyValues? = nil
			var expectedColumnNames: Blackbird.ColumnNames? = nil
			var callCount = 0

			func setExpectedTable(_ v: String?) { self.expectedTable = v }
			func setExpectedKeys(_ v: Blackbird.PrimaryKeyValues?) { self.expectedKeys = v }
			func setExpectedColumnNames(_ v: Blackbird.ColumnNames?) { self.expectedColumnNames = v }
			func setExpectedKeysAndColumnNames(_ k: Blackbird.PrimaryKeyValues?, _ c: Blackbird.ColumnNames?) {
				self.expectedKeys = k
				self.expectedColumnNames = c
			}

			func getExpectedKeysAndColumnNames() -> (Blackbird.PrimaryKeyValues?, Blackbird.ColumnNames?) {
				(self.expectedKeys, self.expectedColumnNames)
			}

			func incrementCallCount() { self.callCount += 1 }
		}
		let state = ChangeState()

		var listeners: [Task<Void, Never>] = []
		defer {
			for listener in listeners {
				listener.cancel()
			}
		}

		listeners.append(Task {
			for await change in TestModel.changeSequence(in: db) {
				if let expectedTable = await state.expectedTable {
					#expect(expectedTable == change.type.tableName, "Change listener called for incorrect table")
				}
				await state.incrementCallCount()
			}
		})

		listeners.append(Task {
			for await change in TestModelWithDescription.changeSequence(in: db) {
				let (expectedKeys, expectedColumnNames) = await state.getExpectedKeysAndColumnNames()
				#expect(expectedKeys == change.primaryKeys)
				#expect(expectedColumnNames == change.columnNames)

				await state.incrementCallCount()
			}
		})

		var expectedChangeNotificationsCallCount = 0

		await state.setExpectedTable("TestModelWithDescription")

		// Batched change notifications
		let count = min(TestData.URLs.count, TestData.titles.count, TestData.descriptions.count)

		func megaYield() async {
			for _ in 0..<count {
				await Task.yield()
			}
		}

		try await db.transaction { core in
			var expectedBatchedKeys = Blackbird.PrimaryKeyValues()
			for i in 0..<count {
				expectedBatchedKeys.insert([.integer(Int64(i))])
				let m = TestModelWithDescription(id: i, url: TestData.URLs[i], title: TestData.titles[i], description: TestData.descriptions[i])
				try m.writeIsolated(to: db, core: core)
			}
			await state.setExpectedKeysAndColumnNames(expectedBatchedKeys, Blackbird.ColumnNames(["id", "url", "title", "description"]))
		}
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Individual change notifications
		var m = try #require(await TestModelWithDescription.read(from: db, id: 64))
		m.title = "Edited title!"
		await state.setExpectedKeysAndColumnNames(Blackbird.PrimaryKeyValues([[.integer(64)]]), Blackbird.ColumnNames(["title"]))
		try await m.write(to: db)
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Unspecified/whole-table change notifications, with structured column info
		await state.setExpectedKeysAndColumnNames(Blackbird.PrimaryKeyValues(Array(0..<count).map { [try! Blackbird.Value.fromAny($0)] }), Blackbird.ColumnNames(["url"]))
		try await TestModelWithDescription.update(in: db, set: [\.$url: nil], matching: .all)
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Unspecified/whole-table delete notifications, with structured column info
		await state.setExpectedKeysAndColumnNames(Blackbird.PrimaryKeyValues(Array(0..<5).map { [try! Blackbird.Value.fromAny($0)] }), nil)
		try await TestModelWithDescription.delete(from: db, matching: \.$id < 5)
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Unspecified/whole-table change notifications, with structured column info and primary keys
		await state.setExpectedKeysAndColumnNames([[7], [8], [9]], Blackbird.ColumnNames(["url"]))
		try await TestModelWithDescription.update(in: db, set: [\.$url: nil], forPrimaryKeys: [7, 8, 9])
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Unspecified/whole-table change notifications, structured, but affecting 0 rows -- no change notification expected
		await state.setExpectedKeysAndColumnNames(nil, nil)
		try await TestModelWithDescription.update(in: db, set: [\.$url: nil], matching: .all)
		await megaYield()
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Unspecified/whole-table change notifications
		await state.setExpectedKeysAndColumnNames(nil, nil)
		try await TestModelWithDescription.query(in: db, "UPDATE $T SET url = NULL")
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Column-name merging
		await state.setExpectedKeysAndColumnNames(Blackbird.PrimaryKeyValues([[.integer(31)], [.integer(32)]]), Blackbird.ColumnNames(["title", "description"]))
		try await db.transaction { core in
			var t1 = try TestModelWithDescription.readIsolated(from: db, core: core, id: 31)!
			t1.title = "Edited title!"
			var t2 = try TestModelWithDescription.readIsolated(from: db, core: core, id: 32)!
			t2.description = "Edited description!"

			try t1.writeIsolated(to: db, core: core)
			try t2.writeIsolated(to: db, core: core)
		}
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Merging with insertions
		await state.setExpectedKeysAndColumnNames(Blackbird.PrimaryKeyValues([[.integer(40)], [.integer(Int64(count) + 1)]]), Blackbird.ColumnNames(["id", "title", "description", "url"]))
		try await db.transaction { core in
			var t1 = try TestModelWithDescription.readIsolated(from: db, core: core, id: 40)!
			t1.title = "Edited title!"
			try t1.writeIsolated(to: db, core: core)

			let t2 = TestModelWithDescription(id: count + 1, title: "New entry", description: "New description")
			try t2.writeIsolated(to: db, core: core)
		}
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Merging with deletions
		await state.setExpectedKeysAndColumnNames(Blackbird.PrimaryKeyValues([[.integer(50)], [.integer(51)]]), Blackbird.ColumnNames(["id", "title", "description", "url"]))
		try await db.transaction { core in
			var t1 = try TestModelWithDescription.readIsolated(from: db, core: core, id: 50)!
			t1.title = "Edited title!"
			try t1.writeIsolated(to: db, core: core)

			let t2 = try TestModelWithDescription.readIsolated(from: db, core: core, id: 51)!
			try t2.deleteIsolated(from: db, core: core)
		}
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// Merging with table-wide updates
		await state.setExpectedKeysAndColumnNames(nil, nil)
		try await db.transaction { core in
			var t1 = try TestModelWithDescription.readIsolated(from: db, core: core, id: 60)!
			t1.title = "Edited title!"
			try t1.writeIsolated(to: db, core: core)

			try TestModelWithDescription.queryIsolated(in: db, core: core, "UPDATE $T SET description = ? WHERE id = 61", "Test description")
		}
		await megaYield()
		expectedChangeNotificationsCallCount += 1
		#expect(await state.callCount == expectedChangeNotificationsCallCount)

		// ------- Should be the last test in this func since it deletes the entire table -------
		// The SQLite truncate optimization: https://www.sqlite.org/lang_delete.html#the_truncate_optimization
		await state.setExpectedTable(nil)
		await state.setExpectedKeysAndColumnNames(nil, nil)
		try await TestModelWithDescription.query(in: db, "DELETE FROM $T")
		await megaYield()
		expectedChangeNotificationsCallCount += 2 // will trigger a full-database change notification, so it'll report 2 table changes: TestModel and TestModelWithDescription
		#expect(await state.callCount == expectedChangeNotificationsCallCount)
	}

	@Test
	func keyPathInterpolation() {
		let str = "SELECT \(\TestModel.$title)"
		#expect(str == "SELECT title")
	}

	@Test
	func optionalColumn() async throws {
		let db = try Blackbird.Database.inMemoryDatabase(options: [.debugPrintEveryQuery, .debugPrintQueryParameterValues])

		let testDate = Date()
		let testURL = try #require(URL(string: "https://github.com/marcoarment/Blackbird"))
		let testData = "Hi".data(using: .utf8)
		try await TestModelWithOptionalColumns(id: 1, date: Date(), name: "a").write(to: db)
		try await TestModelWithOptionalColumns(id: 2, date: Date(), name: "b", value: "2").write(to: db)
		try await TestModelWithOptionalColumns(id: 3, date: Date(), name: "c", value: "3", otherValue: 30).write(to: db)
		try await TestModelWithOptionalColumns(id: 4, date: Date(), name: "d", value: "4", optionalDate: testDate).write(to: db)
		try await TestModelWithOptionalColumns(id: 5, date: Date(), name: "e", value: "5", optionalURL: testURL).write(to: db)
		try await TestModelWithOptionalColumns(id: 6, date: Date(), name: "f", value: "6", optionalData: testData).write(to: db)

		let t1 = try #require(await TestModelWithOptionalColumns.read(from: db, id: 1))
		let t2 = try #require(await TestModelWithOptionalColumns.read(from: db, id: 2))
		let t3 = try #require(await TestModelWithOptionalColumns.read(from: db, id: 3))
		let t4 = try #require(await TestModelWithOptionalColumns.read(from: db, id: 4))
		let t5 = try #require(await TestModelWithOptionalColumns.read(from: db, id: 5))
		let t6 = try #require(await TestModelWithOptionalColumns.read(from: db, id: 6))

		#expect(t1.name == "a")
		#expect(t2.name == "b")
		#expect(t3.name == "c")
		#expect(t4.name == "d")
		#expect(t5.name == "e")
		#expect(t6.name == "f")

		#expect(t1.value == nil)
		#expect(t2.value == "2")
		#expect(t3.value == "3")
		#expect(t4.value == "4")
		#expect(t5.value == "5")
		#expect(t6.value == "6")

		#expect(t1.otherValue == nil)
		#expect(t2.otherValue == nil)
		#expect(t3.otherValue == 30)
		#expect(t4.otherValue == nil)
		#expect(t5.otherValue == nil)
		#expect(t6.otherValue == nil)

		#expect(t1.optionalDate == nil)
		#expect(t2.optionalDate == nil)
		#expect(t3.optionalDate == nil)
		#expect(abs(try #require(t4.optionalDate?.timeIntervalSince(testDate))) < 0.001)
		#expect(t5.optionalDate == nil)
		#expect(t6.optionalDate == nil)

		#expect(t1.optionalURL == nil)
		#expect(t2.optionalURL == nil)
		#expect(t3.optionalURL == nil)
		#expect(t4.optionalURL == nil)
		#expect(t5.optionalURL == testURL)
		#expect(t6.optionalURL == nil)

		#expect(t1.optionalData == nil)
		#expect(t2.optionalData == nil)
		#expect(t3.optionalData == nil)
		#expect(t4.optionalData == nil)
		#expect(t5.optionalData == nil)
		#expect(t6.optionalData == testData)

		let random = try await TestModelWithOptionalColumns.read(from: db, matching: .literal("id % 5 = ?", 3))
		#expect(random.count == 1)
		#expect(random.first?.id == 3)

		try await TestModelWithOptionalColumns.delete(from: db, matching: .all)
		let results = try await TestModelWithOptionalColumns.read(from: db, matching: .all)
		#expect(results.count == 0)
	}

	@Test
	func uniqueIndex() async throws {
		let db = try Blackbird.Database.inMemoryDatabase(options: [.debugPrintEveryQuery, .debugPrintQueryParameterValues])

		let testDate = Date()
		try await TestModelWithUniqueIndex(id: 1, a: "a1", b: 100, c: testDate).write(to: db)
		try await TestModelWithUniqueIndex(id: 2, a: "a2", b: 200, c: testDate).write(to: db)

		var caughtExpectedError = false
		do {
			try await TestModelWithUniqueIndex(id: 3, a: "a2", b: 200, c: testDate).write(to: db)
		} catch Blackbird.Database.Error.uniqueConstraintFailed {
			caughtExpectedError = true
		}
		#expect(caughtExpectedError)

		let allBefore = try await TestModelWithUniqueIndex.read(from: db, sqlWhere: "1 ORDER BY id")
		#expect(allBefore.count == 2)

		#expect(allBefore[0].id == 1)
		#expect(allBefore[0].a == "a1")
		#expect(allBefore[0].b == 100)

		#expect(allBefore[1].id == 2)
		#expect(allBefore[1].a == "a2")
		#expect(allBefore[1].b == 200)

		try await TestModelWithUniqueIndex(id: 3, a: "a2", b: 201, c: testDate).write(to: db)

		let all = try await TestModelWithUniqueIndex.read(from: db, sqlWhere: "1 ORDER BY id")
		#expect(all.count == 3)

		#expect(all[0].id == 1)
		#expect(all[0].a == "a1")
		#expect(all[0].b == 100)

		#expect(all[1].id == 2)
		#expect(all[1].a == "a2")
		#expect(all[1].b == 200)

		#expect(all[2].id == 3)
		#expect(all[2].a == "a2")
		#expect(all[2].b == 201)
	}

	// To test bug #25: https://github.com/marcoarment/Blackbird/issues/25
	@Test
	func concurrentTransactions() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename)

		try await withThrowingTaskGroup { tg in
			for i in 0..<1000 {
				tg.addTask {
					try await db.transaction { core in
						try await Task.sleep(nanoseconds: UInt64(arc4random_uniform(10_000)))
						try TestModel(id: Int64(i), title: TestData.randomTitle, url: TestData.randomURL).writeIsolated(to: db, core: core)
					}
				}
			}

			try await tg.waitForAll()
		}
	}

	@Test(CacheLimit(testModel: 10_000))
	func cache() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename)

		// big block of writes to populate the DB
		let lastURL = try await db.transaction { core in
			var lastURL: URL?
			for i in 0..<1000 {
				let t = TestModel(id: Int64(i), title: TestData.randomTitle, url: TestData.randomURL, nonColumn: TestData.randomDescription)
				try t.writeIsolated(to: db, core: core)
				lastURL = t.url
			}
			return try #require(lastURL)
		}

		db.resetCachePerformanceMetrics(tableName: TestModel.tableName)
		var t = try #require(await TestModel.read(from: db, id: 1))
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.misses == 0)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.hits == 1)

		db.resetCachePerformanceMetrics(tableName: TestModel.tableName)
		t.title = "new"
		try await t.write(to: db)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.writes == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.rowInvalidations == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.tableInvalidations == 0)

		db.resetCachePerformanceMetrics(tableName: TestModel.tableName)
		t = try #require(await TestModel.read(from: db, id: 1))
		#expect(t.title == "new")
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.misses == 0)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.hits == 1)

		db.resetCachePerformanceMetrics(tableName: TestModel.tableName)
		try await db.query("UPDATE TestModel SET title = 'new2' WHERE id = 1")
		t = try #require(await TestModel.read(from: db, id: 1))
		#expect(t.title == "new2")
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.misses == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.hits == 0)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.rowInvalidations == 0)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.tableInvalidations == 1)

		db.resetCachePerformanceMetrics(tableName: TestModel.tableName)
		try await TestModel.update(in: db, set: [\.$title: "new2"], matching: \.$id == 1)
		t = try #require(await TestModel.read(from: db, id: 1))
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.misses == 0)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.hits == 1)

		db.resetCachePerformanceMetrics(tableName: TestModel.tableName)
		try await TestModel.update(in: db, set: [\.$title: "new3"], matching: \.$id < 10)
		t = try #require(await TestModel.read(from: db, id: 1))
		#expect(t.title == "new3")
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.misses == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.hits == 0)

		db.resetCachePerformanceMetrics(tableName: TestModel.tableName)
		var titleMatch = try await TestModel.query(in: db, columns: [\.$title], matching: \.$url == lastURL)
		#expect(!titleMatch.isEmpty)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.misses == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.hits == 0)
		titleMatch = try await TestModel.query(in: db, columns: [\.$title], matching: \.$url == lastURL)
		#expect(!titleMatch.isEmpty)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.misses == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.hits == 1)

		t.id = 9998
		try await t.write(to: db)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.queryInvalidations == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.rowInvalidations == 0)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.tableInvalidations == 0)

		try await TestModel.update(in: db, set: [\.$id: 9999], matching: \.$id == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.queryInvalidations == 1)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.rowInvalidations == 0)
		#expect(db.cachePerformanceMetricsByTableName()[TestModel.tableName]?.tableInvalidations == 0)
	}

	@Test(CacheLimit(testModel: 10_000))
	func cacheSpeed() async throws {
		let startTime = Date()
		try await queries()
		try await heavyWorkload()
		try await changeNotifications()
		let duration = abs(startTime.timeIntervalSinceNow)
		Self.logger.debug("took \(duration) seconds")

		//        measure {
		//            let exp = expectation(description: "Finished")
		//            Task {
		//                let startTime = Date()
		//                try await testHeavyWorkload()
		//                let duration = startTime.timeIntervalSinceNow
		//                print("took \(duration) seconds")
		//                exp.fulfill()
		//            }
		//            wait(for: [exp], timeout: 200.0)
		//        }
	}

	@Test
	func fts() async throws {
		let options: Blackbird.Database.Options = [.debugPrintEveryQuery, .requireModelSchemaValidationBeforeUse]

		let db1 = try Blackbird.Database(path: self.sqliteFilename, options: options)
		let resolution1 = try await FTSModel.resolveSchema(in: db1)
		#expect(resolution1.contains(.createdTable))
		#expect(resolution1.contains(.migratedFullTextIndex))
		#expect(!resolution1.contains(.migratedTable))

		let count = min(TestData.URLs.count, TestData.titles.count, TestData.descriptions.count)

		try await db1.transaction { core in
			for i in 0..<count {
				let m = FTSModel(id: i, title: TestData.titles[i], url: TestData.URLs[i], description: TestData.descriptions[i], keywords: TestData.descriptions[(i + 2) % count].lowercased(), category: i % 10)
				try m.writeIsolated(to: db1, core: core)
			}
		}

		let results1 = try await FTSModel.fullTextSearch(from: db1, matching: .match("tech"), options: .default)
		#expect(results1.count == 38)
		await db1.close()

		let db2 = try Blackbird.Database(path: self.sqliteFilename, options: options)
		let resolution2 = try await FTSModel.resolveSchema(in: db2)
		#expect(!resolution2.contains(.createdTable))
		#expect(!resolution2.contains(.migratedFullTextIndex))
		#expect(!resolution2.contains(.migratedTable))
		try await FTSModel.optimizeFullTextIndex(in: db2)
		let results2a = try await FTSModel.fullTextSearch(from: db2, matching: .match(column: \.$title, "podcast"), options: .default)
		#expect(results2a.count == 111)
		let results2b = try await FTSModel.fullTextSearch(from: db2, matching: .match(column: \.$title, "podcast") && \.$category == 1, options: .init(scoreMultipleColumn: \.$category))
		#expect(results2b.count == 10)
		await db2.close()

		let db3 = try Blackbird.Database(path: self.sqliteFilename, options: options)
		let resolution3 = try await FTSModelAfterMigration.resolveSchema(in: db3)
		#expect(!resolution3.contains(.createdTable))
		#expect(resolution3.contains(.migratedFullTextIndex))
		#expect(!resolution3.contains(.migratedTable))

		let results3 = try await FTSModelAfterMigration.fullTextSearch(from: db3, matching: .match(column: \.$keywords, "finance"), options: .default)
		#expect(results3.count == 18)
		await db3.close()

		let db4 = try Blackbird.Database(path: self.sqliteFilename, options: options)
		let resolution4 = try await FTSModelAfterDeletion.resolveSchema(in: db4)
		#expect(!resolution4.contains(.createdTable))
		#expect(resolution4.contains(.migratedFullTextIndex))
		#expect(!resolution4.contains(.migratedTable))
		await db4.close()

		let db5 = try Blackbird.Database(path: self.sqliteFilename, options: options)
		let resolution5 = try await FTSModelAfterDeletion.resolveSchema(in: db5)
		#expect(!resolution5.contains(.createdTable))
		#expect(!resolution5.contains(.migratedFullTextIndex))
		#expect(!resolution5.contains(.migratedTable))
	}

	@Test
	func backup() async throws {
		let db = try Blackbird.Database(path: self.sqliteFilename)
		for i in 0..<1000 {
			try await TestModel(id: Int64(i), title: TestData.randomTitle, url: TestData.randomURL).write(to: db)
		}
		let backupFilePath = self.sqliteFilename + ".backup"
		Self.logger.debug("Creating backup at \(backupFilePath)")

		defer {
			for path in Blackbird.Database.allFilePaths(for: backupFilePath) {
				try? FileManager.default.removeItem(atPath: path)
			}
		}

		try await db.core.backup(to: backupFilePath, pagesPerStep: 100, printProgress: true)

		let backupDb = try Blackbird.Database(path: backupFilePath)

		let modelsInDb = try await TestModel.read(from: db)
		let modelsInBackupDb = try await TestModel.read(from: backupDb)

		#expect(modelsInDb == modelsInBackupDb)

		await db.close()
		await backupDb.close()
	}

	/* Tests duplicate-index detection. Throws fatal error on success.
	 func testDuplicateIndex() async throws {
	     var db = try Blackbird.Database(path: sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintQueryParameterValues])
	     try await DuplicateIndexesModel(id: 1, title: "Hi").write(to: db)
	     await db.close()

	     db = try Blackbird.Database(path: sqliteFilename, options: [.debugPrintEveryQuery, .debugPrintQueryParameterValues])
	     try await DuplicateIndexesModel(id: 2, title: "Hi").write(to: db)
	 }
	 */
}
