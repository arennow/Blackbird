This project is migrating toward Swift 6 strict concurrency. Only make changes that maintain or improve concurrency safety. Prefer compiler-provable safety over assumptions or runtime checking.

The SQLite database is initialized with `SQLITE_OPEN_NOMUTEX`, which means the database handle and objects derived from it are safe to share across threads, so long as they're never used at the same time

After making changes, make sure the tests pass and no new warnings are generated