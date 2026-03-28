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

import Darwin

/// A readers-writer lock that protects a value of type `Value`.
///
/// Multiple readers may hold the lock concurrently; writers have exclusive access.
/// Use `withReadLock` for read-only access and `withWriteLock` for mutation.
final class ReadersWriterLock<Value>: @unchecked Sendable {
	private var value: Value
	private var lock = pthread_rwlock_t()

	init(_ value: Value) {
		self.value = value
		pthread_rwlock_init(&self.lock, nil)
	}

	deinit {
		pthread_rwlock_destroy(&self.lock)
	}

	/// Acquires a shared read lock and calls `body` with an immutable view of the value.
	/// Multiple `withReadLock` calls may run concurrently.
	func withReadLock<R>(_ body: (Value) throws -> R) rethrows -> R {
		pthread_rwlock_rdlock(&self.lock)
		defer { pthread_rwlock_unlock(&self.lock) }
		return try body(self.value)
	}

	/// Acquires an exclusive write lock and calls `body` with a mutable reference to the value.
	func withWriteLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
		pthread_rwlock_wrlock(&self.lock)
		defer { pthread_rwlock_unlock(&self.lock) }
		return try body(&self.value)
	}
}
