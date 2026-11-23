import API
import Auth
import Foundation
import Hummingbird
import Logging
import OpenAPIHummingbird
import OpenAPIRuntime
import ServiceLifecycle
import Storage

/// Shared by the executable and the tests, so both build the same application.
protocol AppArguments {
    var hostname: String { get }
    var port: Int { get }
    var logLevel: Logger.Level? { get }
}

/// What the app talks to. Production builds these from the environment;
/// tests pass a test database and a fake token verifier.
struct Dependencies: Sendable {
    let database: Database
    let verifier: any TokenVerifying
    var clock: @Sendable () -> Date = { Date() }
}

func buildApplication(_ arguments: some AppArguments) async throws -> some ApplicationProtocol {
    let logger = makeLogger(arguments)
    // Both fail at startup if their environment is missing: a server that
    // starts without a database or without auth is worse than one that won't.
    let database = Database(configuration: try .fromEnvironment(), logger: logger)
    let verifier = TokenVerifier(
        configuration: try .fromEnvironment(), fetcher: HTTPJWKSFetcher(url: try jwksURL()),
        logger: logger)
    var app = Application(
        router: try buildRouter(Dependencies(database: database, verifier: verifier)),
        configuration: .init(
            address: .hostname(arguments.hostname, port: arguments.port),
            serverName: "brain-server"),
        services: [DatabaseService(database: database)],
        logger: logger)
    // Single VM, single instance: migrating on startup is safe and keeps
    // deploys to one step. Revisit if a second instance ever runs.
    app.beforeServerStarts { try await database.migrate() }
    return app
}

private func jwksURL() throws -> String {
    try AuthConfiguration.fromEnvironment().jwksURL
}

func makeLogger(_ arguments: some AppArguments) -> Logger {
    var logger = Logger(label: "brain-server")
    logger.logLevel =
        arguments.logLevel
        ?? Environment().get("LOG_LEVEL").flatMap { Logger.Level(rawValue: $0) }
        ?? .info
    return logger
}

func buildRouter(_ dependencies: Dependencies) throws -> Router<AppRequestContext> {
    let router = Router(context: AppRequestContext.self)
    router.addMiddleware {
        LogRequestsMiddleware(.info)
    }
    // Liveness only, and the one route without a token.
    router.get("/health") { _, _ -> HTTPResponse.Status in
        .ok
    }
    let api = router.group().add(middleware: AuthMiddleware(verifier: dependencies.verifier))
    try APIHandler(database: dependencies.database, clock: dependencies.clock)
        .registerHandlers(on: api, middlewares: [ErrorHandlingMiddleware()])
    return router
}

/// Keeps the connection pool running for the life of the app.
struct DatabaseService: Service {
    let database: Database
    func run() async throws {
        await database.run()
    }
}
