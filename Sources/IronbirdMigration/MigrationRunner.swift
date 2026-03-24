import Dirs
import Foundation
import Ironbird

public enum MigrationRunner {
	/// Opens a database at `path`, applies any pending migrations, and returns the open database.
	///
	/// If `backupMode` is `.backup`, copies of the database files are made before any migration runs.
	/// On failure, throws `MigrationFailure`, whose `backupFiles` property contains those copies so
	/// the caller can recover or surface them to the user.
	public static func migrateAndOpen(path: String,
									  options: Ironbird.Database.Options = [],
									  through migrations: Array<any Migration>,
									  backupMode: Backup.Mode = .backup) async throws -> MigrationSuccess
	{
		var migrations = migrations
		try Self.uniqueAndSortVersions(in: &migrations)

		var backupFiles: Array<File>
		if backupMode == .backup, let mainFile = try RealFSInterface().rootDir.file(at: path) {
			backupFiles = try Backup.copyDatabaseFiles(for: mainFile)
		} else {
			backupFiles = []
		}
		defer { try? Backup.deleteBackupFiles(backupFiles) }

		let db = try Ironbird.Database(path: path, options: options)

		do {
			let count = try await Self.runMigrations(db, migrations: migrations)
			return MigrationSuccess(db: db, migrationsAppliedCount: count)
		} catch var error as MigrationFailure {
			var backupFilesForError = Array<File>()
			swap(&backupFiles, &backupFilesForError)
			error.backupFiles = backupFilesForError
			throw error
		}
	}

	/// Applies any pending migrations to an already-open database and returns the number applied.
	@discardableResult
	public static func migrate(_ db: Ironbird.Database,
							   through migrations: Array<any Migration>) async throws -> Int
	{
		var migrations = migrations
		try Self.uniqueAndSortVersions(in: &migrations)
		return try await Self.runMigrations(db, migrations: migrations)
	}

	/// The result of a successful `migrateAndOpen` call.
	public struct MigrationSuccess: Sendable {
		/// The open, fully-migrated database.
		public let db: Ironbird.Database
		/// The number of migrations that were applied during this run (0 if the database was already up-to-date).
		public let migrationsAppliedCount: Int
	}

	/// Thrown when two or more migrations share the same `version` number.
	public struct DuplicateVersionError: Error, Equatable {
		/// The duplicated version number.
		public let version: Int
	}

	/// Thrown when a migration fails. If a backup was made, `backupFiles` contains the pre-migration copies.
	public struct MigrationFailure: Error, Equatable {
		public static func == (lhs: Self, rhs: Self) -> Bool {
			guard lhs.backupFiles == rhs.backupFiles,
				  type(of: lhs.error) == type(of: rhs.error)
			else { return false }

			return lhs.error.localizedDescription == rhs.error.localizedDescription
		}

		/// The underlying error that caused the migration to fail.
		public let error: any Error
		/// Pre-migration backup files for the database. Empty when `backupMode` was `.skip`.
		public var backupFiles: Array<File>
	}
}

extension MigrationRunner {
	@discardableResult
	private static func runMigrations(_ db: Ironbird.Database,
									  migrations: Array<any Migration>) async throws -> Int
	{
		var migrations = migrations
		try Self.uniqueAndSortVersions(in: &migrations)

		guard let lastMigration = migrations.last else { return 0 }

		let lastMigrationVersion = (try await Self.getLastMigrationVersion(db: db)) ?? Int.min

		let neededMigrations = migrations.filter { $0.version > lastMigrationVersion }
		guard !neededMigrations.isEmpty else { return 0 }

		do {
			try await db.transaction { core in
				try Self.apply(neededMigrations, db: db, core: core)
				try MigrationState(lastMigrationVersion: lastMigration.version).writeIsolated(to: db, core: core)
			}
		} catch {
			throw MigrationFailure(error: error, backupFiles: [])
		}

		return neededMigrations.count
	}
}

extension MigrationRunner {
	static func getLastMigrationVersion(db: Ironbird.Database) async throws -> Int? {
		try await MigrationState.read(from: db, id: MigrationState.singletonID)?.lastMigrationVersion
	}

	static func apply(_ migrations: Array<any Migration>, db: Ironbird.Database, core: isolated Ironbird.Database.Core) throws {
		for migration in migrations {
			try core.transaction { core in
				try Self.materialize(migration.modelsToMaterializeBefore, db: db, core: core)
				try migration.run(db: db, core: core)
				try Self.materialize(migration.modelsToMaterializeAfter, db: db, core: core)
			}
		}
	}

	private static func materialize(_ tables: Array<any IronbirdModel.Type>, db: Ironbird.Database, core: isolated Ironbird.Database.Core) throws {
		core.resetResolvedTables()
		for affectedModel in tables {
			_ = try affectedModel.readIsolated(from: db, core: core, sqlWhere: "1 = 2")
		}
	}
}

extension MigrationRunner {
	static func uniqueAndSortVersions(in migrations: inout Array<any Migration>) throws {
		migrations.sort { $0.version < $1.version }

		var seen = Set<Int>()
		for migration in migrations {
			let (inserted, _) = seen.insert(migration.version)
			if !inserted {
				throw DuplicateVersionError(version: migration.version)
			}
		}
	}
}

struct MigrationState: IronbirdModel {
	static let singletonID: Int = 1

	@IronbirdColumn var id: Int = Self.singletonID
	@IronbirdColumn var lastMigrationVersion: Int
}
