// swift-tools-version: 6.0

import PackageDescription
import CompilerPluginSupport

// Host-only code. The compiler plugin is an executable built for the machine
// running the compiler, never for iOS, so this package has no simulator
// consumers: the Modules package depends on this one by path and its
// GRDBMacros declarations library points at the plugin here. Keeping the
// plugin out of the Modules package is what lets the Modules test bundles
// link for the iOS simulator — while the plugin shared that package, its
// object file (built for macOS) was linked into simulator test bundles and
// the link failed.
let package = Package(
    name: "ModulesMacros",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GRDBMacrosPlugin",
            targets: ["GRDBMacrosPlugin"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        .macro(
            name: "GRDBMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/GRDBMacrosPlugin"
        ),
        .testTarget(
            name: "GRDBMacrosTests",
            dependencies: [
                "GRDBMacrosPlugin",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/GRDBMacrosTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
