import Dirs
import Foundation
import Ironbird

/// Utilities for backing up SQLite database files before migrations run.
public enum Backup {
	/// Controls whether a backup is made before running migrations.
	public enum Mode: Sendable {
		/// Copy the database and its WAL/SHM companion files before migrating.
		case backup
		/// Skip the backup step.
		case skip
	}

	static let companionSuffixes = ["-wal", "-shm"]

	static func copyDatabaseFiles(for mainFile: File) throws -> [File] {
		let possibleCompanionFilenames = self.companionSuffixes.map { mainFile.name + $0 }

		let parent = try mainFile.parent

		var filesToBackUp = [mainFile]
		for siblingFile in try parent.children().files {
			if possibleCompanionFilenames.contains(siblingFile.name) {
				filesToBackUp.append(siblingFile)
			}
		}

		var backupFiles = Array<File>()
		for sourceFile in filesToBackUp {
			let backupName = sourceFile.name + ".pre-migration-backup"
			if let existing = parent.file(at: backupName) {
				try existing.delete()
			}
			try sourceFile.copy(to: parent.path.appending(backupName))
			backupFiles.append(try parent.fs.file(at: parent.path.appending(backupName)))
		}

		return backupFiles
	}

	static func deleteBackupFiles(_ files: [File]) throws {
		for file in files {
			try file.delete()
		}
	}
}
