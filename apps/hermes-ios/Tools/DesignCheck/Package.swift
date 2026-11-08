// swift-tools-version: 6.0
// The design checker (design-rules 9.4): run by HermesUI's build phase (scripts/design-check.sh),
// it fails the build when a screen styles itself instead of composing HermesUI.
import PackageDescription

let package = Package(
    name: "DesignCheck",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "design-check", targets: ["design-check"])],
    dependencies: [
        // Matches the toolchain's Swift 6.4 (swift-syntax 604).
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "604.0.0"),
    ],
    targets: [
        .target(name: "DesignCheckCore", dependencies: [
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        .executableTarget(name: "design-check", dependencies: ["DesignCheckCore"]),
        .testTarget(name: "DesignCheckTests", dependencies: ["DesignCheckCore"], resources: [.copy("Fixtures")]),
    ]
)
