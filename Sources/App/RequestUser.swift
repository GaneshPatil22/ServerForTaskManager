import Storage

/// The signed-in user for the current request.
///
/// Generated OpenAPI handlers receive no Hummingbird context, so
/// `AuthMiddleware` puts the user here and the handler reads it back. Both run
/// in the same task, which is what makes a task-local the right carrier.
enum RequestUser {
    @TaskLocal static var current: UserID?
}
