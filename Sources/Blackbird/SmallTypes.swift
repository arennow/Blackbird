//  SPDX-License-Identifier: MIT
//  Copyright 2026 Aaron Rennow
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

/// A reference-type box allowing `~Copyable` values (such as `Mutex`) to be stored
/// as properties of Copyable types like structs.
///
/// The canonical usage is `Box<Mutex<T>>`, where the `Box` provides stable heap
/// storage and the `Mutex` provides thread-safe access.
final class Box<Wrapped: ~Copyable> {
	let value: Wrapped
	init(_ value: consuming Wrapped) { self.value = value }
}

extension Box: Sendable where Wrapped: Sendable {}

/// A wrapper around the raw SQLite database connection handle (`OpaquePointer`).
///
/// Declared `@unchecked Sendable` because SQLite connections opened with `SQLITE_OPEN_NOMUTEX`
/// are safe to pass across isolation boundaries when access is externally serialized — in this
/// codebase, that serialization is provided by the `Database.Core` actor.
struct SQLiteDBHandle: @unchecked Sendable {
	let pointer: OpaquePointer
	init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

/// A wrapper around a raw SQLite prepared-statement handle (`OpaquePointer`).
///
/// Declared `@unchecked Sendable` for the same reason as `SQLiteDBHandle`: prepared-statement
/// handles derived from a `SQLITE_OPEN_NOMUTEX` connection are safe to pass across isolation
/// boundaries when access is externally serialized. In this codebase that serialization is
/// provided by the `Database.Core` actor, which is the *only* context that ever holds or uses
/// a `PreparedStatement` (and therefore this wrapper).
struct SQLiteStatementHandle: @unchecked Sendable {
	let pointer: OpaquePointer
	init(_ pointer: OpaquePointer) { self.pointer = pointer }
}
