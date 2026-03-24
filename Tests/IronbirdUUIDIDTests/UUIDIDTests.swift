#if UUIDID
	import IronbirdUUIDIDMacros
	import SwiftSyntaxMacros
	import SwiftSyntaxMacrosTestSupport
	import Testing

	let testMacros: [String: Macro.Type] = [
		"UUIDID": UUIDIDMacro.self,
	]

	struct UUIDIDTests {
		@Test
		func basicStructExpansion() {
			assertMacroExpansion("""
								 @UUIDID
								 struct Foo {
								 }
								 """,
								 expandedSource: """
								 struct Foo {

								 	internal struct ID: UUIDID, Codable, Hashable, IronbirdColumnWrappable, IronbirdStorableAsText {
								 		internal typealias OwningType = Foo

								 		private let string: String

								 		internal static var temporary: Self { Self.mock(lowByte: 0) }

								 		internal static func mock(lowByte: UInt8) -> Self {
								 			self.init(rawString: String(format: "0x%0x", lowByte))
								 		}

								 		internal static func random() -> Self {
								 			self.init(rawString: UUID().uuidString)
								 		}

								 		internal var isTemporary: Bool {
								 			self == Self.temporary
								 		}

								 		internal var ifNonTemporary: Self? {
								 			self.isTemporary ? nil : self
								 		}

								 		internal init(rawString: String) {
								 			self.string = rawString
								 		}

								 		internal init(from uuid: UUID) {
								 			self.string = uuid.uuidString
								 		}

								 		internal init(from decoder: any Decoder) throws {
								 			let container = try decoder.singleValueContainer()
								 			self.init(rawString: try container.decode(String.self))
								 		}

								 		internal func encode(to encoder: any Encoder) throws {
								 			var container = encoder.singleValueContainer()
								 			try container.encode(self.string)
								 		}

								 		internal static func from(unifiedRepresentation: String) -> Self {
								 			Self(rawString: unifiedRepresentation)
								 		}

								 		internal static func fromValue(_ value: Ironbird.Value) -> Self? {
								 			value.stringValue.map(Self.init(rawString:))
								 		}

								 		internal func unifiedRepresentation() -> String {
								 			self.string
								 		}
								 	}
								 }
								 """,
								 macros: testMacros)
		}

		@Test func publicStructExpansion() {
			assertMacroExpansion("""
								 @UUIDID
								 public struct Bar {
								 }
								 """,
								 expandedSource: """
								 public struct Bar {

								 	public struct ID: UUIDID, Codable, Hashable, IronbirdColumnWrappable, IronbirdStorableAsText {
								 		public typealias OwningType = Bar

								 		private let string: String

								 		public static var temporary: Self { Self.mock(lowByte: 0) }

								 		public static func mock(lowByte: UInt8) -> Self {
								 			self.init(rawString: String(format: "0x%0x", lowByte))
								 		}

								 		public static func random() -> Self {
								 			self.init(rawString: UUID().uuidString)
								 		}

								 		public var isTemporary: Bool {
								 			self == Self.temporary
								 		}

								 		public var ifNonTemporary: Self? {
								 			self.isTemporary ? nil : self
								 		}

								 		public init(rawString: String) {
								 			self.string = rawString
								 		}

								 		public init(from uuid: UUID) {
								 			self.string = uuid.uuidString
								 		}

								 		public init(from decoder: any Decoder) throws {
								 			let container = try decoder.singleValueContainer()
								 			self.init(rawString: try container.decode(String.self))
								 		}

								 		public func encode(to encoder: any Encoder) throws {
								 			var container = encoder.singleValueContainer()
								 			try container.encode(self.string)
								 		}

								 		public static func from(unifiedRepresentation: String) -> Self {
								 			Self(rawString: unifiedRepresentation)
								 		}

								 		public static func fromValue(_ value: Ironbird.Value) -> Self? {
								 			value.stringValue.map(Self.init(rawString:))
								 		}

								 		public func unifiedRepresentation() -> String {
								 			self.string
								 		}
								 	}
								 }
								 """,
								 macros: testMacros)
		}

		@Test func nestedStructExpansion() {
			assertMacroExpansion("""
								 enum Container {
								 	@UUIDID
								 	struct Inner {}
								 }
								 """,
								 expandedSource: """
								 enum Container {
								 	struct Inner {

								 		internal struct ID: UUIDID, Codable, Hashable, IronbirdColumnWrappable, IronbirdStorableAsText {
								 			internal typealias OwningType = Inner

								 			private let string: String

								 			internal static var temporary: Self { Self.mock(lowByte: 0) }

								 			internal static func mock(lowByte: UInt8) -> Self {
								 				self.init(rawString: String(format: "0x%0x", lowByte))
								 			}

								 			internal static func random() -> Self {
								 				self.init(rawString: UUID().uuidString)
								 			}

								 			internal var isTemporary: Bool {
								 				self == Self.temporary
								 			}

								 			internal var ifNonTemporary: Self? {
								 				self.isTemporary ? nil : self
								 			}

								 			internal init(rawString: String) {
								 				self.string = rawString
								 			}

								 			internal init(from uuid: UUID) {
								 				self.string = uuid.uuidString
								 			}

								 			internal init(from decoder: any Decoder) throws {
								 				let container = try decoder.singleValueContainer()
								 				self.init(rawString: try container.decode(String.self))
								 			}

								 			internal func encode(to encoder: any Encoder) throws {
								 				var container = encoder.singleValueContainer()
								 				try container.encode(self.string)
								 			}

								 			internal static func from(unifiedRepresentation: String) -> Self {
								 				Self(rawString: unifiedRepresentation)
								 			}

								 			internal static func fromValue(_ value: Ironbird.Value) -> Self? {
								 				value.stringValue.map(Self.init(rawString:))
								 			}

								 			internal func unifiedRepresentation() -> String {
								 				self.string
								 			}
								 		}
								 	}
								 }
								 """,
								 macros: testMacros)
		}
	}
#endif // UUIDID
