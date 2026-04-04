import Foundation
@testable import Ironbird
import Testing

struct WithoutRowIDTests {
	@Test
	func sql() {
		let withoutRowIDTable = SchemaGenerator.shared.table(for: WithoutRowIDTestModel.self)
		let withoutRowIDSQL = withoutRowIDTable.createTableStatement(type: WithoutRowIDTestModel.self)
		#expect(withoutRowIDSQL.hasSuffix(" WITHOUT ROWID"))

		let normalTable = SchemaGenerator.shared.table(for: TestModel.self)
		let normalSQL = normalTable.createTableStatement(type: TestModel.self)
		#expect(!normalSQL.contains("WITHOUT ROWID"))
	}

	@Test
	func crud() async throws {
		let db = try Ironbird.Database(path: ":memory:")

		let row1 = WithoutRowIDTestModel(postID: 1, tagID: 10)
		let row2 = WithoutRowIDTestModel(postID: 1, tagID: 20)
		let row3 = WithoutRowIDTestModel(postID: 2, tagID: 10)

		try await row1.write(to: db)
		try await row2.write(to: db)
		try await row3.write(to: db)

		let post1Tags = try await WithoutRowIDTestModel.read(from: db, matching: \.$postID == 1)
		#expect(Set(post1Tags) == Set([row1, row2]))

		let tag10Rows = try await WithoutRowIDTestModel.read(from: db, matching: \.$tagID == 10)
		#expect(Set(tag10Rows) == Set([row1, row3]))

		try await row1.delete(from: db)
		let afterDelete = try await WithoutRowIDTestModel.read(from: db, matching: \.$postID == 1)
		#expect(afterDelete == [row2])

		let total = try await WithoutRowIDTestModel.count(in: db)
		#expect(total == 2)
	}

	@Test
	func requiresPrimaryKey() async {
		// A WITHOUT ROWID model with no explicit primaryKey and no column named "id"
		// must fatalError during schema generation
		await #expect(processExitsWith: .failure) {
			_ = WithoutRowIDNoPrimaryKeyModel.table
		}
	}

	enum MigrationDirection: CaseIterable {
		case falseToTrue
		case trueToFalse
	}

	@Test(arguments: MigrationDirection.allCases)
	func migration(_ direction: MigrationDirection) async throws {
		let filename = "\(FileManager.default.temporaryDirectory.path)/test\(Int64.random(in: 0..<Int64.max)).sqlite"
		defer {
			for path in Ironbird.Database.allFilePaths(for: filename) {
				try? FileManager.default.removeItem(atPath: path)
			}
		}

		let rows = [
			WithoutRowIDMigrationRow(postID: 1, tagID: 10),
			WithoutRowIDMigrationRow(postID: 1, tagID: 20),
			WithoutRowIDMigrationRow(postID: 2, tagID: 10),
		]

		// Write rows using the "before" schema
		let db1 = try Ironbird.Database(path: filename)
		for row in rows {
			switch direction {
				case .falseToTrue: try await WithoutRowIDMigrationWithRowID(postID: row.postID, tagID: row.tagID).write(to: db1)
				case .trueToFalse: try await WithoutRowIDMigrationWithoutRowID(postID: row.postID, tagID: row.tagID).write(to: db1)
			}
		}
		await db1.close()

		// Reopen with the "after" schema, triggering the migration
		let db2 = try Ironbird.Database(path: filename)

		let migratedRows: [WithoutRowIDMigrationRow]
		let createSQL: String
		switch direction {
			case .falseToTrue:
				let read = try await WithoutRowIDMigrationWithoutRowID.read(from: db2)
				migratedRows = read.map { WithoutRowIDMigrationRow(postID: $0.postID, tagID: $0.tagID) }
			case .trueToFalse:
				let read = try await WithoutRowIDMigrationWithRowID.read(from: db2)
				migratedRows = read.map { WithoutRowIDMigrationRow(postID: $0.postID, tagID: $0.tagID) }
		}

		// Verify that all rows survived the migration
		#expect(Set(migratedRows) == Set(rows))

		// Verify that the WITHOUT ROWID setting was applied in the database
		createSQL = try await db2.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
										WithoutRowIDMigrationWithoutRowID.tableName).first?["sql"]?.stringValue ?? ""

		switch direction {
			case .falseToTrue: #expect(createSQL.range(of: "WITHOUT ROWID", options: .caseInsensitive) != nil)
			case .trueToFalse: #expect(createSQL.range(of: "WITHOUT ROWID", options: .caseInsensitive) == nil)
		}

		await db2.close()
	}
}
