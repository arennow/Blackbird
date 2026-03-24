import Ironbird
@testable import IronbirdMigration
import Synchronization
import Testing

struct BasicMigrationTests {
	let db = try! Ironbird.Database.inMemoryDatabase()

	@Test
	func runsSingleMigration() async throws {
		try await self.applyMigrations(Mig1())
		let foo = try await Foo1.read(from: self.db, id: 0)
		#expect(foo?.a == "manual_0")
	}

	@Test
	func runsMultipleMigrations() async throws {
		try await self.applyMigrations(Mig1(), Mig2())
		try await self.assertPostMig2State(Foo2.self)
	}

	func migrateTo2() async throws {
		try await MigrationRunner.migrate(self.db, through: [Mig1(), Mig2()])
	}

	// This generic is required to not violate Ironbird's requirement that
	// only one type be used to access a table per DB (without resetting)
	func assertPostMig2State<F2L: Foo2Like>(_ f2l: F2L.Type) async throws {
		let foo = try await F2L.read(from: self.db, id: 0)
		#expect(foo?.a == "manual_0")
		#expect(foo?.b == "mig2")
	}

	@Test
	func recordsMigrationState() async throws {
		try await self.migrateTo2()
		try await self.assertPostMig2State(Foo2.self)
		let state = try await MigrationState.read(from: self.db, id: MigrationState.singletonID)
		#expect(state?.lastMigrationVersion == 2)
	}

	@Test
	func performsOnlyNewMigrations() async throws {
		try await self.migrateTo2()
		try await self.assertPostMig2State(Foo2.self)

		try await MigrationRunner.migrate(self.db, through: [Mig1(), Mig2(), Mig3()])
		try await self.assertPostMig2State(Foo3.self)

		let foo = try await Foo3.read(from: self.db, id: 0)
		#expect(foo?.c == "mig3")

		let state = try await MigrationState.read(from: self.db, id: MigrationState.singletonID)
		#expect(state?.lastMigrationVersion == 3)
	}

	@Test
	func rejectsDuplicateMigrationVersions() async {
		await #expect(throws: MigrationRunner.DuplicateVersionError(version: 1)) {
			try await MigrationRunner.migrate(self.db, through: [Mig1(), Mig1()])
		}
	}

	@Test
	func noOpOnNoMigrations() async throws {
		try await MigrationRunner.migrate(self.db, through: [])
		try await #expect(self.db.query("SELECT name FROM sqlite_master WHERE type='table'") == [])
	}

	@Test
	func noOpOnNoNewMigrations() async throws {
		try await self.migrateTo2()

		let changes = Mutex(Array<Ironbird.Change>())
		let observationTask = Task {
			for await change in self.db.changeSequence(for: MigrationState.tableName) {
				changes.withLock { $0.append(change) }
			}
		}

		try await self.recordsMigrationState()

		observationTask.cancel()
		let observedChanges = changes.withLock { $0 }
		#expect(observedChanges.count == 0, "\(observedChanges)")
	}

	@Test
	func rollbackOnFailure() async throws {
		try await self.migrateTo2()

		let expectedInnerError = Ironbird.Database.Error.queryError(query: "UPDATE NonExistentTable SET q = z",
																	description: "SQLite error code 1: no such table: NonExistentTable")

		await #expect(throws: MigrationRunner.MigrationFailure(error: expectedInnerError, backupFiles: []),
					  performing: {
					  	try await MigrationRunner.migrate(self.db, through: [Mig1(), Mig2(), Mig3_Failing()])
					  })
		try await self.db.transaction { $0.resetResolvedTables() }
		try await self.assertPostMig2State(Foo2.self)

		let columns = try await self.db.query("SELECT sql FROM sqlite_master WHERE type='table' AND name='Foo'")
			.compactMap { Self.columnNames(from: $0) }
			.flatMap(\.self)

		#expect(columns == ["id", "a", "b"])
	}
}

extension BasicMigrationTests {
	func applyMigrations(_ migrations: any Migration...) async throws {
		try await self.db.transaction { core in
			try MigrationRunner.apply(migrations, db: self.db, core: core)
		}
	}

	static func columnNames(from row: Ironbird.Row) -> Array<String>? {
		// ["sql": Ironbird.Ironbird.Value.text("CREATE TABLE `Foo` (`id` INTEGER NOT NULL DEFAULT 0,`a` TEXT NOT NULL DEFAULT \'\', `b` TEXT NOT NULL DEFAULT \'\',PRIMARY KEY (`id`))")]
		guard let sqlString = row["sql"]?.stringValue else { return nil }
		return sqlString.matches(of: /`(\w+)` ([A-Z]+)/).map { match in
			String(match.1)
		}
	}

	struct Foo1: IronbirdModel {
		static var tableName: String { "Foo" }
		@IronbirdColumn var id: Int
		@IronbirdColumn var a: String
	}

	struct Mig1: Migration {
		var modelsToMaterializeBefore: Array<any IronbirdModel.Type> { [Foo1.self] }
		var version: Int { 1 }
		func run(db: Ironbird.Database, core: isolated Ironbird.Database.Core) throws {
			try core.execute("INSERT INTO Foo (id, a) VALUES (0, 'manual_0')")
			try core.execute("INSERT INTO Foo (id, a) VALUES (1, 'manual_1')")
		}
	}

	protocol Foo2Like: IronbirdModel {
		var a: String { get }
		var b: String { get }
	}

	struct Foo2: IronbirdModel, Foo2Like {
		static var tableName: String { "Foo" }
		@IronbirdColumn var id: Int
		@IronbirdColumn var a: String
		@IronbirdColumn var b: String
	}

	struct Mig2: Migration {
		var modelsToMaterializeBefore: Array<any IronbirdModel.Type> { [Foo2.self] }
		var version: Int { 2 }
		func run(db: Ironbird.Database, core: isolated Ironbird.Database.Core) throws {
			try core.execute("UPDATE Foo SET b = b || 'mig2'")
		}
	}

	struct Foo3: IronbirdModel, Foo2Like {
		static var tableName: String { "Foo" }
		@IronbirdColumn var id: Int
		@IronbirdColumn var a: String
		@IronbirdColumn var b: String
		@IronbirdColumn var c: String
	}

	struct Mig3: Migration {
		var modelsToMaterializeBefore: Array<any IronbirdModel.Type> { [Foo3.self] }
		var version: Int { 3 }
		func run(db: Ironbird.Database, core: isolated Ironbird.Database.Core) throws {
			try core.execute("UPDATE Foo SET c = c || 'mig3'")
		}
	}

	struct Mig3_Failing: Migration {
		var modelsToMaterializeBefore: Array<any IronbirdModel.Type> { [Foo3.self] }
		var version: Int { 3 }
		func run(db: Ironbird.Database, core: isolated Ironbird.Database.Core) throws {
			try core.execute("UPDATE Foo SET b = 'mig3'")
			try core.execute("UPDATE Foo SET c = c || 'mig3'")
			try core.execute("UPDATE NonExistentTable SET q = z")
		}
	}
}
