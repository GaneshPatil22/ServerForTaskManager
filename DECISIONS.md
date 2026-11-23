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

### 2026-11-24 — S1: data layer

**Packages, checked against source and release tags today.** postgres-nio
1.33.3 and **postgres-migrations 1.2.0**. The second one is new to the plan:
`hummingbird-postgres` 1.1.0 turned out to hold only a key-value persist
driver, and migrations live in this separate package from the same org.
`hummingbird-postgres` is not used yet. Postgres image `postgres:17.12-alpine`:
Supabase's docs show 17 as the current major version (self-hosted image
`supabase/postgres:17.6.1.084`). I could not find a docs page saying new hosted
projects start on 17, so that gets checked with `select version()` once the
project exists.

**The isolation boundary is built in three layers:**
1. Every primary key is `(user_id, id)`, and every foreign key includes
   `user_id`. The database cannot store a row that points at another user's
   row. This also means the same id can exist for two users, so one user can't
   probe for another's ids by colliding with them.
2. `UserStore` is the only place SQL is written, and every query filters on
   `user_id`. The Postgres client is internal to the `Storage` module, so the
   rest of the server cannot write a query without going through
   `Database.scoped(to: UserID)`.
3. The cross-user isolation suite. **I checked that it can fail:** with the
   `user_id` filter removed from `edges()`, 2 of its 5 tests failed.

**Invariants the database enforces even against raw SQL:** captures are
never deleted or edited except `status` (trigger, invariant 2); corrections
are append-only (trigger); `confirmed` requires `source = 'user'` (check,
invariant 3); `serves` points at a goal and every other kind at an item; no
self-loops; no duplicate edges; ids must be ULIDs. **Cycles are not checked
by the database.** That stays with Brain's graph code (guard 6).

**RLS** is enabled on every table with no policies. On Supabase that blocks
the auto-generated data API (`anon`, `authenticated`). It does not restrict
the server, which connects as the table owner. This matches ADR-0007.

**Deliberately not in S1:**
- Tables for pending T3 questions and the budget ledger. Their shape depends on
  the enrichment worker (S4) and Brain's ledger storage hook, so they come with
  S4.
- `embedding` on items. There is no ml-service yet (B5).
- TLS. The client is TLS-off for local Docker; connecting to Supabase needs
  TLS, which comes with S6.
- Wiring the database into the running app. That comes with the first
  endpoint that reads data (S3).

**Open point for later.** Captures can never be deleted, but India's DPDP
Act gives users a right to erasure. Account deletion will need an explicit,
audited path around the trigger. This is recorded, not designed.

**Small things worth knowing:**
- Timestamps round-trip at microsecond precision, so a `Date` with
  sub-microsecond detail will not compare equal after storage. Tests use whole
  seconds.
- Each migration's CHECK lists are frozen. `SchemaDriftTests` fails if Brain
  adds an enum case, and the fix is a new migration.
