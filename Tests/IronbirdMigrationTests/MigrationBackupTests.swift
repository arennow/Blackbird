import Dirs
import Foundation
import Ironbird
import IronbirdMigration
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MigrationBackupTests {
	let tempDir: Dir
	let dbPath: String

	init() throws {
		let tempDirPath = NSTemporaryDirectory() + UUID().uuidString
		self.dbPath = tempDirPath + "/test.sqlite"
		self.tempDir = try RealFSInterface().createDir(at: tempDirPath)
	}

	@Test func cleansUpBackupsAfterSuccessfulMigration() async throws {
		defer { try? self.tempDir.delete() }

		// First run: no pre-existing DB file, so nothing to back up
		let result1 = try await MigrationRunner.migrateAndOpen(path: self.dbPath,
															   through: [BasicMigrationTests.Mig1()])
		#expect(result1.migrationsAppliedCount == 1)
		await result1.db.close()

		// Second run: DB exists, Mig2 is needed; backup is created and cleaned up on success
		let result2 = try await MigrationRunner.migrateAndOpen(path: self.dbPath,
															   through: [BasicMigrationTests.Mig1(), BasicMigrationTests.Mig2()])
		#expect(result2.migrationsAppliedCount == 1)
		#expect(self.backupFiles().isEmpty)
		await result2.db.close()

		// Third run: same migrations again; nothing to do, no backup files from a no-op
		let result3 = try await MigrationRunner.migrateAndOpen(path: self.dbPath,
															   through: [BasicMigrationTests.Mig1(), BasicMigrationTests.Mig2()])
		#expect(result3.migrationsAppliedCount == 0)
		#expect(self.backupFiles().isEmpty)
		await result3.db.close()
	}

	@Test func skipsBackupWhenRequested() async throws {
		defer { try? self.tempDir.delete() }

		// Set up DB with Mig1 + Mig2
		let result1 = try await MigrationRunner.migrateAndOpen(path: self.dbPath,
															   through: [BasicMigrationTests.Mig1(), BasicMigrationTests.Mig2()])
		await result1.db.close()

		// A failing migration with skip mode should leave no backup files
		do {
			_ = try await MigrationRunner.migrateAndOpen(path: self.dbPath,
														 through: [BasicMigrationTests.Mig1(), BasicMigrationTests.Mig2(), BasicMigrationTests.Mig3_Failing()],
														 backupMode: .skip)
			Issue.record("Expected migration to fail")
		} catch {
			#expect(self.backupFiles().isEmpty)
		}
	}

	@Test func preservesBackupsOnFailure() async throws {
		defer { try? self.tempDir.delete() }

		// Set up DB with Mig1 + Mig2
		let result1 = try await MigrationRunner.migrateAndOpen(path: self.dbPath,
															   through: [BasicMigrationTests.Mig1(), BasicMigrationTests.Mig2()])
		await result1.db.close()

		// Attempt with a failing migration
		let migrationError = await #expect(throws: MigrationRunner.MigrationFailure.self) {
			try await MigrationRunner.migrateAndOpen(path: self.dbPath,
													 through: [BasicMigrationTests.Mig1(), BasicMigrationTests.Mig2(), BasicMigrationTests.Mig3_Failing()])
		}

		#expect(migrationError?.backupFiles.isEmpty == false)
		#expect(!self.backupFiles().isEmpty)
	}

	@Test func copiesCompanionFilesIfPresent() async throws {
		defer { try? self.tempDir.delete() }

		// Prime the DB with Mig1 so companion WAL/SHM files may be present, then
		// run Mig2 — the backup step copies whatever companion files exist.
		let result1 = try await MigrationRunner.migrateAndOpen(path: self.dbPath,
															   through: [BasicMigrationTests.Mig1()])
		await result1.db.close()

		// Plant a synthetic WAL sibling so we can assert it gets backed up.
		let walFile = try self.tempDir.newOrExistingFile(at: "test.sqlite-wal")
		try walFile.replaceContents(Data("wal".utf8))

		let result2 = try await MigrationRunner.migrateAndOpen(path: self.dbPath,
															   through: [BasicMigrationTests.Mig1(), BasicMigrationTests.Mig2()])
		// On success, all backups are cleaned up
		#expect(result2.migrationsAppliedCount == 1)
		#expect(self.backupFiles().isEmpty)
		await result2.db.close()
	}
}

private extension MigrationBackupTests {
	/// Returns all `.pre-migration-backup` files currently in the temp directory.
	func backupFiles() -> [File] {
		(try? self.tempDir.children().files.filter { $0.name.hasSuffix(".pre-migration-backup") }) ?? []
	}
}
