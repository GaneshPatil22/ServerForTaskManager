import Hummingbird
import Logging

/// Shared by the executable and the tests, so both build the same application.
protocol AppArguments {
    var hostname: String { get }
    var port: Int { get }
    var logLevel: Logger.Level? { get }
}

func buildApplication(_ arguments: some AppArguments) async throws -> some ApplicationProtocol {
    let environment = Environment()
    var logger = Logger(label: "brain-server")
    logger.logLevel =
        arguments.logLevel
        ?? environment.get("LOG_LEVEL").flatMap { Logger.Level(rawValue: $0) }
        ?? .info

    return Application(
        router: buildRouter(),
        configuration: .init(
            address: .hostname(arguments.hostname, port: arguments.port),
            serverName: "brain-server"
        ),
        logger: logger
    )
}

func buildRouter() -> Router<AppRequestContext> {
    let router = Router(context: AppRequestContext.self)
    router.addMiddleware {
        LogRequestsMiddleware(.info)
    }
    // Liveness only: answers 200 while the process can serve requests.
    // Database readiness becomes a separate check once there is a database (S1).
    router.get("/health") { _, _ -> HTTPResponse.Status in
        .ok
    }
    return router
}
