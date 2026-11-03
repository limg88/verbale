// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Verbale",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Verbale", targets: ["Verbale"]),
               .executable(name: "verbale-cli", targets: ["VerbaleCLI"]),
               .executable(name: "verbale-checks", targets: ["VerbaleChecks"])],
    targets: [
        .target(name: "CParakeet", publicHeadersPath: "include"),
        .target(name: "VerbaleCore", dependencies: ["CParakeet"], resources: [.copy("Resources")]),
        .executableTarget(name: "Verbale", dependencies: ["VerbaleCore"]),
        .executableTarget(name: "VerbaleCLI", dependencies: ["VerbaleCore"]),
        .executableTarget(name: "VerbaleChecks", dependencies: ["VerbaleCore"], path: "Tests/VerbaleCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
