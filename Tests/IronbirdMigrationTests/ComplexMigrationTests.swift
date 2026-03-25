import Ironbird
import IronbirdMigration
import Testing

struct ComplexMigrationTests {
	@Test
	func splitsTable() async throws {
		let db = Ironbird.Database.inMemoryDatabase()

		let personBefore = Person1(id: 0,
								   name: "Aaron",
								   favoriteColor: "red",
								   favoriteAnimal: "cat",
								   favoriteFood: "taquitos")
		try await personBefore.write(to: db)

		try await MigrationRunner.migrate(db, through: [Mig1()])

		let personAfter = try #require(await Person2.read(from: db, id: 0))
		#expect(personAfter.name == "Aaron")

		let favorites = try await Favorite1.read(from: db,
												 matching: \.$personID == 0,
												 orderBy: .ascending(\.$key))
		let favDict = Dictionary(favorites.map { ($0.key, $0.value) }, uniquingKeysWith: {
			Issue.record("duplicate key; values: '\($0)' and '\($1)'")
			return $1
		})

		#expect(favDict == [
			"animal": "cat",
			"color": "red",
			"food": "taquitos",
		])
	}
}

extension ComplexMigrationTests {
	struct Person1: IronbirdModel {
		static var tableName: String { "Person" }

		@IronbirdColumn var id: Int
		@IronbirdColumn var name: String
		@IronbirdColumn var favoriteColor: String
		@IronbirdColumn var favoriteAnimal: String
		@IronbirdColumn var favoriteFood: String
	}

	struct Person2: IronbirdModel {
		static var tableName: String { "Person" }

		@IronbirdColumn var id: Int
		@IronbirdColumn var name: String
	}

	struct Favorite1: IronbirdModel {
		static var tableName: String { "Favorite" }

		@IronbirdColumn var id: Int
		@IronbirdColumn var personID: Int
		@IronbirdColumn var key: String
		@IronbirdColumn var value: String
	}

	struct Mig1: Migration {
		var version: Int { 1 }

		var modelsToMaterializeBefore: Array<any IronbirdModel.Type> { [
			Person1.self, Favorite1.self,
		] }

		func run(db: Ironbird.Database, core: isolated Ironbird.Database.Core) throws {
			try core.execute("INSERT INTO Favorite (personID, key, value) SELECT id, 'color', favoriteColor from Person")
			try core.execute("INSERT INTO Favorite (personID, key, value) SELECT id, 'animal', favoriteAnimal from Person")
			try core.execute("INSERT INTO Favorite (personID, key, value) SELECT id, 'food', favoriteFood from Person")
		}

		var modelsToMaterializeAfter: Array<any IronbirdModel.Type> { [
			Person2.self, Favorite1.self,
		] }
	}
}
