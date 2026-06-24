// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JuancodeSpike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
    ],
    targets: [
        .executableTarget(
            name: "JuancodeSpike",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            // Throwaway spike: stay in Swift 5 mode to avoid strict-concurrency
            // friction around AppKit MainActor isolation + the pty read closure.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
