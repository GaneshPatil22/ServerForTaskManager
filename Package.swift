// swift-tools-version: 6.2
import PackageDescription

// Brain comes from a local checkout during development (instant iteration)
// and from a pinned tag in CI (reproducible). See Brain ADR-0003.
// SwiftPM names a path dependency after its folder and a git one after its URL,
// so the product references below must use whichever identity is active.
let brainFromGit = Context.environment["BRAIN_FROM_GIT"] == "1"
let brainTag: Version = "0.4.0"
let brain: Package.Dependency =
    brainFromGit
    ? .package(url: "https://github.com/GaneshPatil22/BrainForTaskManager.git", exact: brainTag)
    : .package(path: "../Brain")
let brainPackage = brainFromGit ? "BrainForTaskManager" : "Brain"

let package = Package(
    name: "Server",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "brain-server", targets: ["App"])
    ],
    dependencies: [
        // Versions verified against GitHub release tags on 2026-11-24.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.3"),
        .package(
            url: "https://github.com/hummingbird-project/postgres-migrations.git", exact: "1.2.0"),
        brain,
    ],
    targets: [
        // The only module that talks to Postgres. Its connection is internal:
        // the rest of the server can only reach data through a UserID scope.
        .target(
            name: "Storage",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "PostgresMigrations", package: "postgres-migrations"),
                .product(name: "BrainCore", package: brainPackage),
            ]
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "BrainCore", package: brainPackage),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "BrainCore", package: brainPackage),
            ]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: [
                "Storage",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "BrainCore", package: brainPackage),
            ]
        ),
    ]
)
