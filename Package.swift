// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Blackbird",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v11),
        .tvOS(.v18),
    ],
    products: [
        .library(
            name: "Blackbird",
            targets: ["Blackbird"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sideeffect-io/AsyncExtensions.git", .upToNextMajor(from: "0.5.3")),
        .package(url: "https://github.com/groue/Semaphore.git", .upToNextMajor(from: "0.0.4")),
    ],
    targets: [
        .target(
            name: "Blackbird",
            dependencies: [
                "AsyncExtensions",
                "Semaphore",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BlackbirdTests",
            dependencies: [
				"Blackbird",
				"Semaphore",
				],
	            swiftSettings: [
	                .enableExperimentalFeature("StrictConcurrency"),
	            ]
				),
    ],
    swiftLanguageModes: [.v5]
)
