import ServiceLifecycle

/// Opens once migrations have run. The job worker polls tables that do not
/// exist until then, so it waits here; the HTTP server waits too, because
/// `beforeServerStarts` is where the gate is opened.
actor StartupGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Runs the given services only after the gate opens.
struct AfterStartup: Service {
    let gate: StartupGate
    let services: [any Service]

    func run() async throws {
        await gate.wait()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for service in services {
                group.addTask { try await service.run() }
            }
            try await group.waitForAll()
        }
    }
}
