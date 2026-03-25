import Dirs
import Foundation
import Ironbird

public enum MigrationRunner {
	/// Opens a database at `path` and begins migrating it in a `Task`.
	///
	/// Returns the open database immediately along with a `Task` whose value is the number of
	/// migrations applied.  The task holds the database's actor isolation for its entire duration,
	/// so any concurrent operation on the database will naturally wait until migrations finish.
	///
	/// If `backupMode` is `.backup`, copies of the database files are made before any migration runs.
	/// On task failure, the thrown `MigrationFailure`'s `backupFiles` property contains those copies
	/// so the caller can recover or surface them to the user.
	@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
	public static func migrateAndOpen(path: String,
									  options: Ironbird.Database.Options = [],
									  through migrations: Array<any Migration>,
									  backupMode: Backup.Mode = .backup) throws -> (db: Ironbird.Database, migrationTask: Task<Int, any Error>)
	{
		var migrations = migrations
		try Self.uniqueAndSortVersions(in: &migrations)

		let backupFiles: Array<File>
		if backupMode == .backup, let mainFile = try RealFSInterface().rootDir.file(at: path) {
			backupFiles = try Backup.copyDatabaseFiles(for: mainFile)
		} else {
			backupFiles = []
		}

		let db: Ironbird.Database
		do {
			db = try Ironbird.Database(path: path, options: options)
		} catch {
			try? Backup.deleteBackupFiles(backupFiles)
			throw error
		}

		// In order for this function to be safe, the first suspension in this immediate `Task`
		// must acquire `db`'s isolation and hold it until it's done migrating
		// That's the only way we can safely synchronously return `db`: its isolation is
		// already held by `migrationTask`
		let task = Task.immediate {
			var backupFiles = backupFiles
			defer { try? Backup.deleteBackupFiles(backupFiles) }
			do {
				return try await Self.runMigrations(db, migrations: migrations)
			} catch var error as MigrationFailure {
				var backupFilesForError = Array<File>()
				swap(&backupFiles, &backupFilesForError)
				error.backupFiles = backupFilesForError
				throw error
			}
		}

		return (db: db, migrationTask: task)
	}

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
	// This function's first suspension must hold `db`'s isolation for the entire
	// period of the migration in order to avoid breaking a critical invariant in the
	// synchronous version of `migrateAndOpen`
	private static func runMigrations(_ db: Ironbird.Database,
									  migrations: Array<any Migration>) async throws -> Int
	{
		let migrations: Array<any Migration> = try {
			var m = migrations
			try Self.uniqueAndSortVersions(in: &m)
			return m
		}()

		guard let lastMigration = migrations.last else { return 0 }

		do {
			return try await db.transaction { core in
				let lastMigrationVersion = (try MigrationState.readIsolated(from: db, core: core, id: MigrationState.singletonID))?.lastMigrationVersion ?? Int.min

				let neededMigrations = migrations.filter { $0.version > lastMigrationVersion }
				guard !neededMigrations.isEmpty else { return 0 }

				try Self.apply(neededMigrations, db: db, core: core)
				try MigrationState(lastMigrationVersion: lastMigration.version).writeIsolated(to: db, core: core)
				return neededMigrations.count
			}
		} catch {
			throw MigrationFailure(error: error, backupFiles: [])
		}
	}
}

extension MigrationRunner {
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
