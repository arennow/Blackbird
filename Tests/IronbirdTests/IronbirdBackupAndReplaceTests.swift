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
@testable import Ironbird
import Testing

final class IronbirdBackupAndReplaceTests {
	var sqliteFilename = ""

	init() throws {
		let dir = FileManager.default.temporaryDirectory.path
		self.sqliteFilename = "\(dir)/test\(Int64.random(in: 0..<Int64.max)).sqlite"
	}

	deinit {
		if sqliteFilename != "", FileManager.default.fileExists(atPath: sqliteFilename) {
			for path in Ironbird.Database.allFilePaths(for: sqliteFilename) {
				try? FileManager.default.removeItem(atPath: path)
			}
		}
	}

	@Test
	func replaceDatabaseFromInMemoryDB() async throws {
		let source = Ironbird.Database.inMemoryDatabase()
		try await TestModel(id: 1, title: "Alpha", url: try #require(URL(string: "https://example.com/a"))).write(to: source)
		try await TestModel(id: 2, title: "Beta", url: try #require(URL(string: "https://example.com/b"))).write(to: source)

		let dest = Ironbird.Database.inMemoryDatabase()
		try await TestModel(id: 99, title: "Original", url: try #require(URL(string: "https://example.com/orig"))).write(to: dest)

		try await dest.replaceDatabase(from: source)

		let rows = try await TestModel.read(from: dest)
		#expect(rows.count == 2)
		#expect(rows.contains { $0.id == 1 && $0.title == "Alpha" })
		#expect(rows.contains { $0.id == 2 && $0.title == "Beta" })
	}

	@Test
	func replaceDatabaseFromFilePath() async throws {
		let source = try Ironbird.Database(path: self.sqliteFilename)
		try await TestModel(id: 10, title: "FromFile", url: try #require(URL(string: "https://example.com/f"))).write(to: source)
		await source.close()

		let dest = Ironbird.Database.inMemoryDatabase()
		try await TestModel(id: 99, title: "WillBeReplaced", url: try #require(URL(string: "https://example.com/x"))).write(to: dest)

		try await dest.replaceDatabase(from: self.sqliteFilename)

		let rows = try await TestModel.read(from: dest)
		#expect(rows.count == 1)
		#expect(rows[0].id == 10)
		#expect(rows[0].title == "FromFile")
	}

	@Test
	func replaceDatabaseFromEmptySource() async throws {
		let dest = Ironbird.Database.inMemoryDatabase()
		try await TestModel(id: 1, title: "Existing", url: try #require(URL(string: "https://example.com/e"))).write(to: dest)

		let emptySource = Ironbird.Database.inMemoryDatabase()

		try await dest.replaceDatabase(from: emptySource)

		let tables = try await dest.query("SELECT name FROM sqlite_master WHERE type='table'")
		#expect(tables.isEmpty)
	}

	@Test
	func replaceDatabaseOverwritesDifferentSchema() async throws {
		let source = Ironbird.Database.inMemoryDatabase()
		try await TestModelWithDescription(id: 1, url: URL(string: "https://example.com"), title: "T", description: "D").write(to: source)

		let dest = Ironbird.Database.inMemoryDatabase()
		try await TestModel(id: 1, title: "Old", url: try #require(URL(string: "https://example.com/old"))).write(to: dest)

		try await dest.replaceDatabase(from: source)

		let rows = try await TestModelWithDescription.read(from: dest)
		#expect(rows.count == 1)
		#expect(rows[0].description == "D")

		// The old TestModel table should not exist
		let tables = try await dest.query("SELECT name FROM sqlite_master WHERE type='table' AND name='TestModel'")
		#expect(tables.isEmpty)
	}

	@Test
	func replaceDatabaseAllowsContinuedUse() async throws {
		let source = Ironbird.Database.inMemoryDatabase()
		try await TestModel(id: 1, title: "Restored", url: try #require(URL(string: "https://example.com/r"))).write(to: source)

		let dest = Ironbird.Database.inMemoryDatabase()

		try await dest.replaceDatabase(from: source)

		let rows = try await TestModel.read(from: dest)
		#expect(rows.count == 1)
		#expect(rows[0].title == "Restored")

		// Insert new data after restore
		try await TestModel(id: 2, title: "PostRestore", url: try #require(URL(string: "https://example.com/pr"))).write(to: dest)
		let allRows = try await TestModel.read(from: dest)
		#expect(allRows.count == 2)
	}
}
