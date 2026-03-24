// swift-tools-version: 6.1

import CompilerPluginSupport
import PackageDescription

let package = Package(name: "Ironbird",
					  platforms: [
					  	.macOS(.v15),
					  	.iOS(.v18),
					  	.watchOS(.v11),
					  	.tvOS(.v18),
					  ],
					  products: [
					  	.library(name: "Ironbird",
								   targets: ["Ironbird"]),
					  	.library(name: "IronbirdUUIDID",
								   targets: ["IronbirdUUIDID"]),
					  	.library(name: "IronbirdMigration",
								   targets: ["IronbirdMigration"]),
					  ],
					  traits: [
					  	.default(enabledTraits: ["UUIDID", "Migration"]),
					  	.trait(name: "UUIDID"),
					  	.trait(name: "Migration"),
					  ],
					  dependencies: [
					  	.package(url: "https://github.com/sideeffect-io/AsyncExtensions.git", .upToNextMajor(from: "0.5.3")),
					  	.package(url: "https://github.com/groue/Semaphore.git", .upToNextMajor(from: "0.0.4")),
					  	.package(url: "https://github.com/arennow/Loggable.git", branch: "2.0.0-beta"),
					  	.package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"603.0.0"),
					  	.package(url: "https://github.com/stackotter/swift-macro-toolkit.git", .upToNextMajor(from: "0.6.0")),
					  	.package(url: "https://github.com/arennow/Dirs.git", .upToNextMinor(from: "0.15.0")),
					  ],
					  targets: [
					  	.target(name: "Ironbird",
								  dependencies: [
								  	"AsyncExtensions",
								  	"Semaphore",
								  	"Loggable",
								  ],
								  swiftSettings: [
								  	.enableUpcomingFeature("MemberImportVisibility"),
								  ]),
					  	.macro(name: "IronbirdUUIDIDMacros",
								 dependencies: [
								 	.product(name: "SwiftSyntaxMacros", package: "swift-syntax", condition: .when(traits: ["UUIDID"])),
								 	.product(name: "SwiftCompilerPlugin", package: "swift-syntax", condition: .when(traits: ["UUIDID"])),
								 	.product(name: "MacroToolkit", package: "swift-macro-toolkit", condition: .when(traits: ["UUIDID"])),
								 ]),
					  	.target(name: "IronbirdUUIDID",
								  dependencies: [
								  	"Ironbird",
								  	.target(name: "IronbirdUUIDIDMacros", condition: .when(traits: ["UUIDID"])),
								  ]),
					  	.testTarget(name: "IronbirdTests",
									  dependencies: [
									  	"Ironbird",
									  	"Semaphore",
									  ],
									  swiftSettings: [
									  	.enableUpcomingFeature("MemberImportVisibility"),
									  ]),
					  	.testTarget(name: "IronbirdUUIDIDTests",
									  dependencies: [
									  	.target(name: "IronbirdUUIDID", condition: .when(traits: ["UUIDID"])),
									  	.target(name: "IronbirdUUIDIDMacros", condition: .when(traits: ["UUIDID"])),
									  	.product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax", condition: .when(traits: ["UUIDID"])),
									  ]),
					  	.target(name: "IronbirdMigration",
								  dependencies: [
								  	"Ironbird",
								  	.product(name: "Dirs", package: "Dirs", condition: .when(traits: ["Migration"])),
								  ]),
					  	.testTarget(name: "IronbirdMigrationTests",
									  dependencies: [
									  	.target(name: "IronbirdMigration", condition: .when(traits: ["Migration"])),
									  ]),
					  ])
