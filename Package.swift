// swift-tools-version: 6.2
import PackageDescription

// Brain comes from a local checkout during development (instant iteration)
// and from a pinned tag in CI (reproducible). See Brain ADR-0003.
// SwiftPM names a path dependency after its folder and a git one after its URL,
// so the product references below must use whichever identity is active.
let brainFromGit = Context.environment["BRAIN_FROM_GIT"] == "1"
let brainTag: Version = "0.6.0"
let brain: Package.Dependency =
    brainFromGit
    ? .package(url: "https://github.com/GaneshPatil22/BrainForTaskManager.git", exact: brainTag)
    : .package(path: "../Brain")
let brainPackage = brainFromGit ? "BrainForTaskManager" : "Brain"

let package = Package(
    name: "Server",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "brain-server", targets: ["App"])
    ],
    dependencies: [
        // Versions verified against GitHub release tags on 2026-11-24.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.3"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.7"),
        .package(
            url: "https://github.com/hummingbird-project/postgres-migrations.git", exact: "1.2.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", exact: "5.9.1"),
        .package(url: "https://github.com/hummingbird-project/swift-jobs.git", exact: "1.4.0"),
        .package(
            url: "https://github.com/hummingbird-project/swift-jobs-postgres.git", exact: "1.5.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator.git", exact: "1.14.4"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", exact: "1.13.4"),
        .package(
            url: "https://github.com/hummingbird-project/swift-openapi-hummingbird.git",
            exact: "2.1.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.37.1"),
        // Tests only: RSA key generation for the RS256 cases. Already in the
        // graph through jwt-kit; pinned to the version that resolves.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.2"),
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
                .product(name: "BrainHarness", package: brainPackage),
                .product(name: "JobsPostgres", package: "swift-jobs-postgres"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        // The HTTP contract. `openapi.yaml` is the source of truth; types and
        // the server protocol are generated from it at build time.
        .target(
            name: "API",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        // Supabase token verification (ADR-0007). No Hummingbird here: the
        // HTTP middleware lives in App, this is just "token in, UserID out".
        .target(
            name: "Auth",
            dependencies: [
                "Storage",
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        // Background enrichment: swift-jobs on Postgres, Brain's pipeline,
        // and the sweeper that guarantees no capture is left unenriched.
        .target(
            name: "Worker",
            dependencies: [
                "Storage",
                .product(name: "BrainCore", package: brainPackage),
                .product(name: "BrainHarness", package: brainPackage),
                .product(name: "BrainPipeline", package: brainPackage),
                .product(name: "BrainProduction", package: brainPackage),
                .product(name: "Jobs", package: "swift-jobs"),
                .product(name: "JobsPostgres", package: "swift-jobs-postgres"),
            ]
        ),
        // Test helpers shared by every test target: one migrated test database
        // per test process. Not part of the server product.
        .target(
            name: "TestDatabase",
            dependencies: ["Storage", .product(name: "BrainCore", package: brainPackage)],
            path: "Tests/TestDatabase"
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                "API",
                "Auth",
                "Storage",
                "Worker",
                .product(name: "BrainHarness", package: brainPackage),
                .product(name: "BrainProduction", package: brainPackage),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "BrainCore", package: brainPackage),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                "Auth",
                "Storage",
                "Worker",
                "TestDatabase",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "BrainCore", package: brainPackage),
            ]
        ),
        .testTarget(
            name: "AuthTests",
            dependencies: [
                "Auth",
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "WorkerTests",
            dependencies: [
                "Worker",
                "Storage",
                "TestDatabase",
                .product(name: "BrainCore", package: brainPackage),
                .product(name: "Jobs", package: "swift-jobs"),
            ]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: [
                "Storage",
                "TestDatabase",
                .product(name: "BrainHarness", package: brainPackage),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "BrainCore", package: brainPackage),
            ]
        ),
    ]
)
