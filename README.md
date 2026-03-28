# Ironbird

A SQLite database wrapper and model layer, using Swift concurrency and `Codable`, with no other dependencies.

Philosophy:

* Prioritize speed of development over all else.
* No code generation.
* No schema definitions.
* Automatic migrations.
* Async by default.
* Use Swift’s type system and key-paths instead of strings whenever possible.
 
## Project Origin

Ironbird is fork of Marco Arment's excellent [Blackbird](https://github.com/marcoarment/Blackbird) library. This project differs from Marco's in a few ways:

- It supports explicit migrations in addition to implicit migrations **(coming soon)**
- Models can optionally use the typesafe `IronbirdUUID` macro **(coming soon)**
- It's in the Swift 6 language mode with full modern Swift Concurrency
- I removed the SwiftUI-specific featureset (see the FAQ entry)

## IronbirdModel

A protocol to store structs in the [SQLite](https://www.sqlite.org/)-powered [Ironbird.Database](#ironbirddatabase), with compiler-checked key-paths for common operations.

Here's how you define a table:

```swift
import Ironbird

struct Post: IronbirdModel {
    @IronbirdColumn var id: Int
    @IronbirdColumn var title: String
    @IronbirdColumn var url: URL?
}
```

That's it. No `CREATE TABLE`, no separate table-definition logic, no additional steps.

And __automatic migrations__. Want to add or remove columns or indexes, or start using more of Ironbird's features such as custom `enum` columns, unique indexes, or custom primary keys? Just change the code:

```swift
struct Post: IronbirdModel {
    static var primaryKey: [IronbirdColumnKeyPath] = [ \.$guid, \.$id ]

    static var indexes: [[IronbirdColumnKeyPath]] = [
        [ \.$title ],
        [ \.$publishedDate, \.$format ],
    ]

    static var uniqueIndexes: [[IronbirdColumnKeyPath]] = [
        [ \.$guid ],
    ]
    
    enum Format: Int, IronbirdIntegerEnum {
        case markdown
        case html
    }
    
    @IronbirdColumn var id: Int
    @IronbirdColumn var guid: String
    @IronbirdColumn var title: String
    @IronbirdColumn var publishedDate: Date?
    @IronbirdColumn var format: Format
    @IronbirdColumn var url: URL?
    @IronbirdColumn var image: Data?
}
```

…and Ironbird will automatically migrate the table to the new schema at runtime.

### Queries

Write instances safely and easily to a [Ironbird.Database](#ironbird-database):

```swift
let post = Post(id: 1, title: "What I had for breakfast")
try await post.write(to: db)
```

Perform queries in many different ways, preferring structured queries using key-paths for compile-time checking, type safety, and convenience:

```swift
// Fetch by primary key
let post = try await Post.read(from: db, id: 2)

// Or with a WHERE condition, using compiler-checked key-paths:
let posts = try await Post.read(from: db, matching: \.$title == "Sports")

// Select custom columns, with row dictionaries typed by key-path:
for row in try await Post.query(in: db, columns: [\.$id, \.$image], matching: \.$url != nil) {
    let postID = row[\.$id]       // returns Int
    let imageData = row[\.$image] // returns Data?
}
```

SQL is never required, but it's always available:

```swift
try await Post.query(in: db, "UPDATE $T SET format = ? WHERE date < ?", .html, date)

let posts = try await Post.read(from: db, sqlWhere: "title LIKE ? ORDER BY RANDOM()", "Sports%")

for row in try await Post.query(in: db, "SELECT MAX(id) AS max FROM $T WHERE url = ?", url) {
    let maxID = row["max"]?.intValue
}
```

Monitor for row- and column-level changes with Combine:

```swift
for await change in Post.changeSequence(in: db) {
    if change.hasPrimaryKeyChanged(7) {
        print("Post 7 has changed")
    }

    if change.hasColumnChanged(\.$title) {
        print("A title has changed")
    }
}

// Or monitor a single column by key-path:
for await _ in Post.changeSequence(in: db, columns: [\.$title]) {
    print("A post's title changed")
}

// Or listen for changes for a specific primary key:
for await _ in Post.changeSequence(in: db, primaryKey: 3, columns: [\.$title]) {
    print("Post 3's title changed")
}
```

## Ironbird.Database

A lightweight async wrapper around [SQLite](https://www.sqlite.org/) that can be used with or without [IronbirdModel](#IronbirdModel).

```swift
let db = try Ironbird.Database(path: "/tmp/db.sqlite")

// SELECT with parameterized queries
for row in try await db.query("SELECT id FROM posts WHERE state = ?", 1) {
    let id = row["id"]?.intValue
    // ...
}

// Run direct queries
try await db.execute("UPDATE posts SET comments = NULL")

// Transactions with synchronous queries
try await db.transaction { core in
    try core.query("INSERT INTO posts VALUES (?, ?)", 16, "Sports!")
    try core.query("INSERT INTO posts VALUES (?, ?)", 17, "Dewey Defeats Truman")
}
```

## Wishlist for future Swift-language capabilities

* __Static type reflection for cleaner schema detection:__ Swift currently has no way to reflect a type's properties without creating an instance — [Mirror](https://developer.apple.com/documentation/swift/mirror) only reflects property names and values of given instances. If the language adds static type reflection in the future, my schema detection wouldn't need to rely on a hack using a Decoder to generate empty instances.

* __KeyPath to/from String, static reflection of a type's KeyPaths:__ With the abilities to get a type's available KeyPaths (without some [awful hacks](https://forums.swift.org/t/getting-keypaths-to-members-automatically-using-mirror/21207)) and create KeyPaths from strings at runtime, many of my hacks using Codable could be replaced with KeyPaths, which would be cleaner and probably much faster.

* __Method to get CodingKeys enum names and custom values:__ It's currently impossible to get the names of `CodingKeys` cases without resorting to [this awful hack](https://forums.swift.org/t/getting-the-name-of-a-swift-enum-value/35654/18). Decoders must know these names to perform proper decoding to arbitrary types that may have custom `CodingKeys` declared. If this hack ever stops working, IronbirdModel cannot support custom `CodingKeys`.

* __Cleaner protocol name (`Ironbird.Model`):__ Protocols can't contain dots or be nested within another type.

* __Nested struct definitions inside protocols__ could make a lot of my "IronbirdModel…" names shorter.

## Linux Support

Ironbird compiles and passes all tests on Linux (Ubuntu). To build on Linux, install `libsqlite3-dev`:

```bash
sudo apt install libsqlite3-dev
```

Some features are unavailable on Linux:

- **File change monitoring (`Ironbird.Database.Options.monitorForExternalChanges`):** This option is only available on Darwin and is not compiled into Linux builds. It enables detection of changes made to a database file by _other processes_ or _other SQLite connections within the same process_ — useful when multiple apps share a database, or when syncing tools like iCloud or Dropbox modify the file on disk. On Darwin, Ironbird uses `DispatchSourceFileSystemObject` (a kernel-level file descriptor watch via `O_EVTONLY`) to detect these writes and invalidate the cache accordingly. A Linux implementation using `inotify` would be straightforward to add in the future.
- **Performance logging (OSLog/Instruments):** The `PerformanceLogger` is a no-op on Linux. Performance profiling via Instruments is a Darwin-only feature.
- **Low-memory cache flushing:** `DispatchSourceMemoryPressure` is unavailable on Linux, so the cache does not automatically flush under memory pressure. The cache otherwise works normally.

## FAQ

### Why don't you have a SwiftUI property wrapper?
I consider that to be an anti-feature. Fetching data directly into the view layer makes it hard-to-impossible to test the behavior (and therefore much less likely that you'll add testing as your feature grows in complexity). It also opens up a significant avenue for hard-to-detect bugs: any number of things can cause a view-updating SwiftUI property wrapper to not actually update the view it's installed on (or to do so too much). But an `@Observable` class held as `@State` in a SwiftUI view relies only on Apple to maintain the code to propertly update views when the data changes _and_ it's trivially unit testable, so I consider that to be the proper way to fetch data to populate a view. If this feature is important to you, it exists in the project Ironbird was forked from, [Blackbird](https://github.com/marcoarment/Blackbird), or feel free to make your own fork.

### Birds aren't iron???
I wanted a name not unrelated to [the base library's](https://github.com/marcoarment/Blackbird) name, but distinct from it. Since many of my changes are about making the library more testable and predictable, I picked something solid-sounding, and what's [more solid](https://en.wikipedia.org/wiki/Diamond) [than iron](https://en.wikipedia.org/wiki/Steel)?