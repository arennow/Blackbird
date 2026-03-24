#if UUIDID
	import MacroToolkit
	import SwiftCompilerPlugin
	import SwiftSyntax
	import SwiftSyntaxBuilder
	import SwiftSyntaxMacros

	@main
	struct UUIDIDPlugin: CompilerPlugin {
		let providingMacros: [Macro.Type] = [
			UUIDIDMacro.self,
		]
	}

	public struct UUIDIDMacro: MemberMacro {
		public static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax, conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
			let visibility = declaration.isPublic ? "public" : "internal"

			guard let identifier = declaration.asProtocol(NamedDeclSyntax.self)?.name.text else {
				let diagnostic = DiagnosticBuilder(for: declaration)
					.message("Can't generate UUIDID on extensions")
					.build()
				context.diagnose(diagnostic)
				return []
			}

			return ["""
			\(raw: visibility) struct ID: UUIDID, Codable, Hashable, IronbirdColumnWrappable, IronbirdStorableAsText {
				\(raw: visibility) typealias OwningType = \(raw: identifier)

				private let string: String

				\(raw: visibility) static var temporary: Self { Self.mock(lowByte: 0) }

				\(raw: visibility) static func mock(lowByte: UInt8) -> Self {
					self.init(rawString: String(format: "0x%0x", lowByte))
				}

				\(raw: visibility) static func random() -> Self {
					self.init(rawString: UUID().uuidString)
				}

				\(raw: visibility) var isTemporary: Bool {
					self == Self.temporary
				}

				\(raw: visibility) var ifNonTemporary: Self? {
					self.isTemporary ? nil : self
				}

				\(raw: visibility) init(rawString: String) {
					self.string = rawString
				}

				\(raw: visibility) init(from uuid: UUID) {
					self.string = uuid.uuidString
				}

				\(raw: visibility) init(from decoder: any Decoder) throws {
					let container = try decoder.singleValueContainer()
					self.init(rawString: try container.decode(String.self))
				}

				\(raw: visibility) func encode(to encoder: any Encoder) throws {
					var container = encoder.singleValueContainer()
					try container.encode(self.string)
				}

				\(raw: visibility) static func from(unifiedRepresentation: String) -> Self {
					Self(rawString: unifiedRepresentation)
				}

				\(raw: visibility) static func fromValue(_ value: Ironbird.Value) -> Self? {
					value.stringValue.map(Self.init(rawString:))
				}

				\(raw: visibility) func unifiedRepresentation() -> String {
					self.string
				}
			}
			"""]
		}
	}

#else // UUIDID feature not enabled

	@main
	struct ProForma {
		static func main() {}
	}

#endif // UUIDID
