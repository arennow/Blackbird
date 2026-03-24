import Ironbird

/// A single, versioned schema migration to be applied to a database.
public protocol Migration: Sendable {
	/// The migration's version number. Migrations are applied in ascending order and each version must be unique.
	var version: Int { get }

	/// Models whose tables should be materialized before `run(db:core:)` is called.
	var modelsToMaterializeBefore: Array<any IronbirdModel.Type> { get }
	/// Performs the migration inside an already-open transaction.
	func run(db: Ironbird.Database, core: isolated Ironbird.Database.Core) throws
	/// Models whose tables should be materialized after `run(db:core:)` completes.
	var modelsToMaterializeAfter: Array<any IronbirdModel.Type> { get }
}

public extension Migration {
	var modelsToMaterializeBefore: Array<any IronbirdModel.Type> { [] }
	var modelsToMaterializeAfter: Array<any IronbirdModel.Type> { [] }
}
