# DECISIONS: Server

Append-only. Newest at the bottom. Product-wide decisions and ADRs live in
`../Brain/DECISIONS.md` and `../Brain/docs/adr/`; this log is server-only.

---

### 2026-11-24 — S0: scaffold

Hummingbird 2.29.0 and swift-argument-parser 1.8.2, pinned exactly. Every
Hummingbird API used here was checked against the 2.29.0 source, not the
official template (last changed 2024-09). One endpoint, `/health`, which is
liveness only.

**Brain dependency.** `../Brain` by path for development; tag `0.4.0` from git
when `BRAIN_FROM_GIT=1` (CI). Package identity differs between the two
(`Brain` vs `BrainForTaskManager`), so `Package.swift` switches both.

**Deliberately not in S0:**
- Dockerfile and docker-compose. Docker is not installed on the development
  Mac, and a Dockerfile that has never been built is not a deliverable.
  docker-compose (Postgres) comes with S1, the Dockerfile with S6.
- Postgres, jobs, auth and OpenAPI packages. Each arrives in the step that
  uses it, and its version is re-checked then.

**Toolchain gap, recorded rather than hidden:** the host has Swift 6.4.0; CI
uses the `swift:6.4.3-noble` image. Brain has the same gap.

`Package.resolved` is committed (Brain ignores it, as a library should). The
server is an application, so transitive versions are pinned too.
