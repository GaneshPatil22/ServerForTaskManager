import ArgumentParser
import Hummingbird
import Logging

/// `brain-server` serves by default, so the container's
/// `brain-server --hostname 0.0.0.0 --port 8080` is unchanged. Operator
/// commands are subcommands of the same binary, run with `docker exec`.
@main
struct App: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brain-server",
        subcommands: [Serve.self, ExportCorrections.self],
        defaultSubcommand: Serve.self)
}

struct Serve: AsyncParsableCommand, AppArguments {
    static let configuration = CommandConfiguration(abstract: "Run the API and the worker.")

    @Option(name: .shortAndLong)
    var hostname: String = "127.0.0.1"

    @Option(name: .shortAndLong)
    var port: Int = 8080

    @Option(name: .shortAndLong)
    var logLevel: Logger.Level?

    func run() async throws {
        let app = try await buildApplication(self)
        try await app.runService()
    }
}

extension Logger.Level: @retroactive ExpressibleByArgument {}
