import API
import Auth
import Foundation
import Hummingbird
import Logging
import OpenAPIHummingbird
import OpenAPIRuntime
import ServiceLifecycle
import Storage
import Worker
import BrainHarness
import BrainProduction

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
    let enrichment: any EnrichmentEnqueuing
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
    let enricher = Enricher(
        database: database, router: await makeModelRouter(database: database, logger: logger),
        logger: logger)
    // Created before migrating, so the queue's own migrations are included.
    let queue = await EnrichmentQueue.make(
        database: database, enricher: enricher, logger: logger)
    let workers = Environment().get("WORKER_CONCURRENCY").flatMap(Int.init) ?? 4

    let gate = StartupGate()
    var app = Application(
        router: try buildRouter(
            Dependencies(database: database, verifier: verifier, enrichment: queue)),
        configuration: .init(
            address: .hostname(arguments.hostname, port: arguments.port),
            serverName: "brain-server"),
        services: [
            DatabaseService(database: database),
            AfterStartup(gate: gate, services: await queue.services(workers: workers)),
        ],
        logger: logger)
    // Single VM, single instance: migrating on startup is safe and keeps
    // deploys to one step. Revisit if a second instance ever runs. Nothing
    // that touches the database runs before this finishes.
    app.beforeServerStarts {
        try await database.migrate()
        await gate.open()
    }
    return app
}

/// Brain's production ladder, live, with daily budgets kept in Postgres.
/// Without `GOOGLE_AI_API_KEY`, enrichment runs on rules alone (T0), and says
/// so loudly at startup rather than quietly.
func makeModelRouter(database: Database, logger: Logger) async -> ModelRouter? {
    guard let apiKey = Environment().get("GOOGLE_AI_API_KEY"), !apiKey.isEmpty else {
        logger.warning("GOOGLE_AI_API_KEY not set: enrichment uses rules only (T0), no models")
        return nil
    }
    for stale in ProductionRouter.staleLimits(now: Date()) {
        logger.warning("free-tier limit not re-verified recently", metadata: ["limit": "\(stale)"])
    }
    let ledger = BudgetLedger(store: PostgresBudgetStore(database: database))
    return await ProductionRouter.make(apiKey: apiKey, ledger: ledger, mode: .live)
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
    try APIHandler(
        database: dependencies.database, enrichment: dependencies.enrichment,
        clock: dependencies.clock
    )
    .registerHandlers(
        on: api, configuration: .init(dateTranscoder: BrowserFriendlyDates()),
        middlewares: [ErrorHandlingMiddleware()])
    return router
}

/// Keeps the connection pool running for the life of the app.
struct DatabaseService: Service {
    let database: Database
    func run() async throws {
        await database.run()
    }
}
