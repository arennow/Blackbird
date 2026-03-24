#if UUIDID
	import Ironbird

	@attached(member, names: named(ID))
	public macro UUIDID() = #externalMacro(module: "IronbirdUUIDIDMacros", type: "UUIDIDMacro")

	public protocol UUIDID: Sendable {
		associatedtype OwningType

		static var temporary: Self { get }
		static func mock(lowByte: UInt8) -> Self
		static func random() -> Self

		var isTemporary: Bool { get }
		var ifNonTemporary: Self? { get }
	}

	public extension UUIDID {
		var owningType: Any.Type {
			OwningType.self
		}
	}
#endif // UUIDID
