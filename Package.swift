// swift-tools-version: 6.0

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
					  ],
					  dependencies: [
					  	.package(url: "https://github.com/sideeffect-io/AsyncExtensions.git", .upToNextMajor(from: "0.5.3")),
					  	.package(url: "https://github.com/groue/Semaphore.git", .upToNextMajor(from: "0.0.4")),
					  	.package(url: "https://github.com/arennow/Loggable.git", branch: "2.0.0-beta"),
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
					  	.testTarget(name: "IronbirdTests",
									  dependencies: [
									  	"Ironbird",
									  	"Semaphore",
									  ],
									  swiftSettings: [
									  	.enableUpcomingFeature("MemberImportVisibility"),
									  ]),
					  ])
