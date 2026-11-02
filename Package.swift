// swift-tools-version: 6.0

import PackageDescription

// CryptoKit's API on Linux, for the passphrase-sealed logins in Android-compatible backups. Only
// when the manifest is evaluated on Linux: Apple platforms import CryptoKit itself, and xtool packs
// a resource bundle for every target in the graph, including swift-crypto's Linux-only ones that
// never get built for iOS, and fails on the first one missing.
#if os(Linux)
let cryptoPackage: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]
let cryptoProduct: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
    // AES-CBC, which CryptoKit leaves out; Apple platforms use CommonCrypto for it instead.
    .product(name: "_CryptoExtras", package: "swift-crypto"),
]
#else
let cryptoPackage: [Package.Dependency] = []
let cryptoProduct: [Target.Dependency] = []
#endif

let package = Package(
    name: "Anilili",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        // xtool packs the single library product as the app; see xtool.yml.
        .library(
            name: "Anilili",
            targets: ["Anilili"]
        ),
    ],
    dependencies: cryptoPackage,
    targets: [
        // Catalogue, providers and parsing. Foundation and swift-crypto only, so its tests run on Linux under WSL
        // where there is no SwiftUI.
        .target(
            name: "AnililiCore",
            dependencies: ["MaterialColorUtilities"] + cryptoProduct
        ),
        // Google's material-color-utilities (Apache-2.0), vendored from its `swift/` folder at the
        // commit in UPSTREAM, because SwiftPM can't depend on a package that isn't at a repo's root.
        // The Android app themes itself with materialkolor, a port of the same library, so the two
        // apps generate the same colours from the same seed.
        .target(
            name: "MaterialColorUtilities",
            exclude: ["LICENSE", "UPSTREAM"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The SwiftUI app. Everything in it is behind `canImport(UIKit)`.
        //
        // Swift 5 mode for now: this target cannot be compiled on Linux, so strict-concurrency
        // diagnostics stay warnings until it has been built once against the iOS SDK. Core, which
        // is built and tested here, keeps Swift 6.
        .target(
            name: "Anilili",
            dependencies: ["AnililiCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AnililiCoreTests",
            dependencies: ["AnililiCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
