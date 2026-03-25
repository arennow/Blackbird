The SQLite database is initialized with `SQLITE_OPEN_NOMUTEX`, which means the database handle and objects derived from it are safe to share across threads, so long as they're never used at the same time

After making changes, make sure the tests pass and no new warnings are generated

Don't fuss over precise whitespace or other formatting. Just make sure things work, and then run `just format` to fix the formatting

Don't use string names for tests (`@Test("", …`); just name the functions clearly. Don't use `@Suite` unless you need to add a trait

Ask any questions you need in order to ensure you have high confidence in your plan