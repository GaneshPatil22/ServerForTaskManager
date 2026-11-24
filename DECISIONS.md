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

### 2026-11-24 — S2: Supabase token verification

**Packages, checked against source and release tags today:** jwt-kit 5.9.1
and async-http-client 1.37.1 (the client that fetches the JWKS). swift-crypto
5.1.2 is pinned for **tests only**, where it generates RSA keys; it was
already in the graph through jwt-kit. **hummingbird-auth is not used.** It has
no JWT support, and its middleware can't express "the keys are unreachable,
answer 503". The middleware is about 40 lines in `App/AuthMiddleware.swift`.

**What Supabase says, checked in its docs today:** tokens are signed ES256
or RS256; `iss` is `<project>/auth/v1`; `aud` is `authenticated` for a
signed-in user or `anon`; `sub` is the user's UUID; the JWKS is cached at
Supabase's edge for 10 minutes, and the docs warn against caching longer.

**Checks, in order:** the header must say ES256 or RS256 and carry a `kid`
(HS256 and `none` are refused before any key is touched); the `kid` must be in
the JWKS, refetching once if not; the key's algorithm must match the header;
the signature; then `iss`, `aud`, `exp` and `nbf` with 30s leeway,
`role = authenticated`, `is_anonymous`, and `sub` must be a UUID.

**Two things found in jwt-kit's source, not its docs:**
1. A token with an unknown `kid` is quietly checked against the *default* key
   rather than failing (`JWTKeyCollection.getSigner`). It is still safe,
   because the signature must match, but jwt-kit cannot tell us when to
   refetch. The server checks the `kid` itself.
2. Its `JWKS` decoder rejects the whole key set if any one key has a type it
   doesn't know. Found by a test, not by reading. One odd key from Supabase
   would have meant every login failing. Keys are now decoded one at a time
   and unusable ones are skipped.

**Policy choices to review:**
- **Anonymous sign-ins are refused** (`allowAnonymous = false`). An anonymous
  account is free to create, and each one can spend the shared free-tier
  quota. A single flag changes this.
- **Revocation takes up to 10 minutes**, the same as Supabase's own edge
  cache. Rotating a key in is picked up at once: an unknown `kid` triggers a
  refetch, at most once every 30s, so junk tokens can't flood Supabase.
- **If Supabase is unreachable,** the last good keys stay in use for up to an
  hour, then requests fail closed with **503, not 401**. A 401 would make the
  apps log everyone out over an outage that isn't theirs.
- The token is never logged, only the reason it was refused.

**Verified:** 25 verifier tests with real ES256 and RS256 keys generated in
the test, and a fake JWKS endpoint that rotates, revokes and fails. 6
middleware tests. Two mutations were caught: with the issuer check removed,
and with the refetch rate limit removed.

**Not in S2:** wiring auth into the running app. There are no protected
routes yet; they arrive with S3, which also makes `SUPABASE_URL` required
at startup. The tests have never seen a real Supabase token, because there
is no project yet. First thing once there is: sign in and check one real
token end to end.

### 2026-11-24 — Anonymous Supabase users stay refused
Confirmed by Ganesh. `allowAnonymous = false` is the decision, not just a
default.

### 2026-11-24 — S3a: API contract, spec first

`Sources/API/openapi.yaml` (OpenAPI 3.1) is the source of truth. It is
generated and compiled by swift-openapi-generator 1.14.4 and runtime 1.13.4,
which proves the spec is valid and the generator accepts it. That gives 18
operations in `APIProtocol`. No handlers yet: this is the review gate.
swift-openapi-hummingbird 2.1.0, now under `hummingbird-project`, is added
in S3b when handlers exist.

**The generator does not enforce `pattern`, `minimum`, `maxLength` or
`maxItems`.** Its own feature list (`Supported-OpenAPI-features.md` at 1.14.4)
marks them unsupported. The spec states them for clients, but every handler
must check them in code: ULID format, text length, page limit. A test per rule.

**Contract decisions to review:**
1. **The client generates capture ids** (ULIDs). The id is the idempotency
   key: resending it returns the stored capture with 200. No separate
   `Idempotency-Key` header.
2. **`capturedAt` comes from the client** (offline phones), and a future time
   is replaced by the server's. A capture is never refused for its timestamp.
   Refusing one risks losing it on the client.
3. **Capture text is capped at 20,000 characters.** About 330 lines of 60
   characters. Longer pastes need splitting by the client.
4. **Another user's id gives 404, never 403**, so ids cannot be probed.
5. **One `/v1/plan` call** returns next, ranked, quick wins and blocked in one
   compute pass and one round trip, instead of four endpoints.
6. **Clearing a field** (e.g. removing a due date) is not in v1's `ItemUpdate`.
7. **No delete endpoints at all.** Captures are append-only; items end
   through `status`. Account deletion (the DPDP open point from S1) stays open.

**Needs a schema change later:** rejecting a suggested edge must stop it from
being suggested again. The current `edges` table cannot record a rejection.
That is migration M0002, in S5.

**Build order inside the steps:** S3b implements me, captures, items (read),
goals. S4 adds questions and the enrichment that fills items. S5 adds plan,
edges and item edits with corrections.

### 2026-11-24 — S3b: the first endpoints

Implemented: `me` (get, timezone), `captures` (create, list, get), `items`
(list, get), `goals` (list, create, update). The S4 and S5 operations answer
**501 `not_implemented`**, so clients can be built against the whole spec now.
swift-openapi-hummingbird 2.1.0 added.

**How the pieces fit:**
- The generated handlers get no Hummingbird context, so `AuthMiddleware` puts
  the user in a task-local (`RequestUser`) and the handler reads it. That
  works because both run in the same task.
- `ErrorHandlingMiddleware` (OpenAPIRuntime) is registered. Without it, a
  malformed body is a 500. With it, the runtime's own mapping gives 400. A
  test covers this; removing the middleware makes it fail.
- Expected failures are returned as the spec's `Problem` responses, never
  thrown. Another user's id and an id that never existed give byte-identical
  404s, and a test compares the two bodies.
- The user's row is created on first sight and cached per process (`KnownUsers`).
  Rows are never deleted, so the cache can't go stale.
- **Migrations run on startup**, before the server listens. That is safe on a
  single VM with one instance. If a second instance ever runs, migration moves
  to a separate deploy step.
- The server refuses to start without the `DATABASE_*` variables and
  `SUPABASE_URL`. There are no defaults that could point production at
  something local.

**Every limit the generator does not enforce is checked in code, each with a
test:** ULID ids, which must be exactly uppercase (a lowercase ULID would
otherwise be a second spelling of the same id); text and title lengths,
counted in Unicode characters, so 20,000 Devanagari characters are allowed;
`limit` between 1 and 500; `after` must be a ULID; IANA timezone names.

**Test setup change:** both test targets now share one `TestDatabase` target.
They run in one process, and two separate schema resets would have wiped each
other's data.

**Verified:** `make ci` green. 66 tests: storage 15, auth 25, app 26. Three
mutations caught: future time not clamped, lenient ULID check, error
middleware removed. The real binary was also started against the dev
database. It migrated on startup, answered `/health` with 200, and gave 401
for no token and for an HS256 token.

**Not done yet:** a capture is stored, but nothing enriches it. Its status
stays `raw` until the S4 worker exists. Real Supabase tokens are still
unverified, because there is no project yet.

### 2026-11-24 — S4a: Brain 0.5.0, daily budget counters in Postgres

Brain pinned to **0.5.0** (`44fb123`). The CI-mode build, resolving Brain
from that tag on GitHub, was checked.

**`PostgresBudgetStore`** implements Brain's `BudgetStore` (migration
`M0002_BudgetCounters`):
- **Check-and-charge is atomic.** One transaction locks the model's row, then
  the user's row, always in that order, so two callers can't both pass a
  check, and can't deadlock each other. **Checked that this matters:** with
  `FOR UPDATE` removed, both concurrency tests fail on every run, which
  reproduces Brain's "40 callers past a limit of 5".
- **Same answers as Brain.** A scripted sequence runs through Brain's
  `InMemoryBudgetStore` and ours, and every answer must match, including
  which limit refused.
- **Keyed by `ProviderDay.key`**, Pacific calendar day, following DST. A test
  pins midnight on both sides of the 2026-11-01 change.
- **Fail-closed.** `reserve` can't throw, so if Postgres is unreachable the
  call is *refused*: enrichment waits, and the capture is safe. The refusal
  reuses `requestsPerDay` because the protocol has no "store unavailable"
  case; the error log says what really happened. Worth a dedicated case in
  Brain eventually; not blocking.
- **Not user data.** These are deployment-wide counters, so this is the one
  storage type outside `UserStore`. `user_key` only enforces fair share and is
  never read back to anyone.

**Accepted from Brain, recorded so it isn't re-asked:**
- No refunds: a charged request stays charged.
- `classifyType` never routes to T3. The questions endpoint stays empty until
  `judgeLink` exists.
- Gemma and Flash-Lite limits can no longer be verified from Google's public
  page. `ProductionRouter.staleLimits(now:)` will be logged at startup (S4b).

**Blocker for S4b:** `BrainProduction` is a target but not a *product* in
Brain's `Package.swift`, so the server can't import `ProductionRouter`.
Brain needs to add `.library(name: "BrainProduction", ...)` and tag 0.5.1.

Old daily rows are kept: about two rows per model per day is negligible.
Pruning can come later if it ever matters.

### 2026-11-24 — S4b: the enrichment worker

Brain pinned to **0.5.1** (`963f7fd`), which exports `BrainProduction`. CI-mode
build from that tag checked. swift-jobs 1.4.0 and swift-jobs-postgres 1.5.0,
re-checked against their tags today. swift-jobs-postgres needs macOS 15, so the
package minimum moved from 14 to 15. That doesn't matter on Linux.

**A capture is never lost, and the queue doesn't have to be perfect for that.**
`push` can't join our transaction (no connection parameter), so the capture's
own status is the outbox:
1. The capture is committed. Then a job is pushed, best effort.
2. A sweeper runs every minute (swift-jobs scheduler). It requeues captures
   that are `raw` past 2 minutes (job lost), `enriching` past 10 minutes
   (worker died), or `failed` without an item. Each is tried at most 5 times
   and kept regardless.
3. Duplicate jobs are harmless. `claimCapture` lets exactly one worker take a
   capture. `saveEnrichment` writes the item, its links and the status in one
   transaction, refusing if an item already exists. **Each layer alone
   prevents a duplicate item.** With the claim check removed, still one item.
   With both removed, the concurrency test fails.

**Guard 6 on the server too.** Every suggested link passes `BrainGraph.addEdge`
(cycle, self-loop, endpoint and `serves` rules) before it can be stored.
Brain's links today all point at the new item, so a cycle can't occur yet.
The check is there for when they can.

**A Brain behaviour handled here:** when a capture has nothing usable, Brain
still creates an item but marks the capture `failed`. Retrying that would make
a second item each time, so the worker never retries a capture that already
has an item.

**Models:** with `GOOGLE_AI_API_KEY` set, `ProductionRouter.make(mode: .live)`
runs with the Postgres budget store, and stale free-tier limits are logged at
startup. Without it, enrichment is rules only (T0), with a startup warning.
Fair share is Brain's `fairShare` over decision-1's daily pool, sized by users
who captured in the last 24 hours.

**Startup order:** the HTTP server and the worker both wait until migrations
finish (`StartupGate`), because the worker polls tables that don't exist until
then.

**Privacy:** the worker logs tiers, unresolved fields and token counts.
`trace.notes` can quote the capture text and is never logged.

**Verified:** 84 tests (storage 21, auth 25, app 27, worker 11), including
the real Postgres queue end to end. Three mutations: two caught, one (claim
check alone) correctly *not* caught, because the transactional save is a
second, independent guard. The real binary: a capture inserted as "lost" was
found by the sweeper and enriched by the worker, T0 only: typed `task`, due
date from "tomorrow".

**Seen, not ours:** postgres-migrations 1.2.0 logs each job-queue migration
twice, under both groups. It logs its cumulative to-apply list per group.
Checked in `_hb_pg_migrations` that each was applied exactly once.

**Not done yet:**
- The model path has not run live on the server. There's no key in this
  environment, and Brain's tests cover the router itself.
- Questions (T3) aren't stored. Nothing produces them today (S4c).
- Budget exhaustion makes Brain degrade to T0 and still mark the capture
  `enriched`. It isn't retried for a better answer the next day. That's
  Brain's design; noted in case it matters later.

### 2026-11-24 — Questions (T3) fold into S5
Agreed with Ganesh. Nothing produces questions today: `classifyType` never
routes to T3. Their storage and endpoints get built in S5, alongside
`judgeLink`, which is what will ask them. Until then, `listQuestions` and
`answerQuestion` keep answering 501.

### 2026-11-24 — S5: plan, links, item edits (questions still waiting on Brain)

**S5a, `GET /v1/plan`.** One `Brain.compute` pass over the user's graph in
their timezone: next, ranked, quick wins, blocked. No model involved.

**S5b, links.**
- **Rejected links stay as rows** (`M0004`, a `rejected` flag) and are left
  out of every read and of the graph. The existing unique (user, from, to,
  kind) index then stops the worker's `ON CONFLICT DO NOTHING` from ever
  re-suggesting one, with no extra lookup.
- **Every graph-changing write** (user links and the worker's save) takes the
  user's row lock and checks with `BrainGraph.addEdge` inside the same
  transaction. **Measured:** without the lock, two simultaneous opposite links
  stored a cycle on every run. With it, exactly one survives.
- **Corrections both ways.** Confirming and rejecting a suggestion each record
  a correction against the tier that made it. B6 learns from right answers as
  well as wrong ones.
- Writing a link the worker had only suggested confirms that suggestion. A
  user can also make a link they once rejected; the row is brought back.
- 409 `cycle`, 400 `self_link` and `wrong_target`, 404 for another user's
  endpoints.

**S5c, `PATCH /v1/items/{id}`.** One transaction, item row locked.
- A field that really changes becomes the user's (confidence 1,
  `decidedBy: user`) and records a correction against its previous tier.
- A title change is a correction too (titles are derived at T0).
- Status is not a correction: finishing an item is the user's call, not a
  tier's mistake.
- A value sent unchanged changes nothing. A goal that isn't the user's rolls
  the whole edit back (404).

**Found while building:** postgres-nio 1.33.3 wraps anything thrown inside
`withTransaction` in `PostgresTransactionError`. Code matching on `PSQLError`
silently misses it. A test caught this: a foreign goal gave 500 instead of 404.
`sqlState(of:)` now unwraps it.

**S5d, questions: not built, waiting on Brain.** `Capability.judgeLink` exists
in Brain 0.5.1, but nothing routes it. The pipeline never calls it, and
`ProductionRouter` says `Rung` needs a predicate first. The two endpoints keep
answering 501.

**Verified:** `make ci` green, 104 tests. Mutation: user lock removed → cycle
race reproduced every run.

### 2026-11-24 — S6a: TLS, Docker image, local end-to-end run

**Supabase project** `evhhbfrlkxtlgnhnsipf`. Its JWKS serves one ES256 P-256
key (checked today), so ADR-0007's asymmetric signing is on and matches the
verifier. **MCP:** the existing Supabase MCP is signed in to a different
account and can't see this project. A separate `supabase-brain` MCP was
added: project-scoped, `read_only=true`, local to this folder. It is
read-only because the server owns the schema through its own migrations.
The user still has to authenticate it (`/mcp`).

**Database TLS.** `DATABASE_TLS` is required, with no default: `disable`
(local Docker only) or `verify-full`, which checks the certificate chain and
the hostname (postgres-nio uses the configured host as the TLS server name).
`DATABASE_CA_FILE` optionally pins Supabase's own root certificate. There is
no "encrypt without verifying" mode: it protects against nobody.
swift-nio-ssl 2.37.7 (latest today) is now a direct dependency.

**Connection to Supabase:** the shared pooler in **session mode** (IPv4,
port 5432). The direct connection is IPv6-only on the free tier, and
transaction mode doesn't fit a long-running server.

**Docker image** (`Dockerfile`): Brain comes from its pinned tag, release
build with static Swift stdlib, on `ubuntu:noble`, running as a non-root user.
- `tzdata`, without which every IANA timezone fails.
- `ca-certificates`.
- `libcurl4`. Found by actually running the image: the first one couldn't
  start (`libcurl.so.4` missing; a dependency links FoundationNetworking).
  `ldd` then confirmed nothing else is missing.
- `Tests/` is copied into the build stage only, because `Package.swift`
  declares a target there.

**Verified in the Linux container (arm64):** health 200, 401 without a
token, the worker enriched a capture ("tomorrow" resolved in Asia/Kolkata).

**Local end-to-end:** `make run` loads `.env` (gitignored), with local
Postgres and the real Supabase project for sign-in. The Website already
proxies `/v1` to 127.0.0.1:8080, so no CORS is needed in dev. **CORS will be
needed** once web and API live on different origins in production.

**Supabase Auth limit to remember:** the built-in email sender only sends to
members of the Supabase organisation, with a small hourly cap. Fine for
testing; real users need custom SMTP before launch.

### 2026-11-24 — First real end-to-end run: every capture refused (fixed)

The first capture from the website in http mode got **400**. Cause: the OpenAPI
runtime's default date parser (`.iso8601`) rejects fractional seconds, and
browsers always send them (`new Date().toISOString()` → `…T10:00:00.123Z`).
All server tests had used whole seconds, so none caught it.

Fix (`BrowserFriendlyDates`): dates are **accepted with or without fractional
seconds and always sent with milliseconds**. A second bug turned up on the way:
`.123` came back as `.122`. Postgres keeps microseconds, `Date` is a `Double`
(so `.123` is really `.12299999…`), and Foundation's formatter *truncates*
fractions. Milliseconds are now computed as an integer and written out by hand.

A test reproduces the browser's format and checks it survives both the
response and a read back through Postgres.

**Wire format change:** dates now always carry three fractional digits
(`…T11:06:40.000Z`). Clients that parse dates are unaffected; any client that
compared date *strings* exactly would need updating.

Captures refused before this fix are held in the website's outbox, marked
refused (its policy for 400), not lost.

### 2026-11-24 — Questions answer "none" instead of 501

Reverses the 501 part of "Questions (T3) fold into S5", with Ganesh's OK.
`GET /v1/questions` returns **200 with an empty list**, and answering any id
returns **404**. Nothing creates questions until Brain routes `judgeLink`, so
"there are none" is the true answer, not "not implemented". The 501 also
showed as a red console error in every browser on every page load, and no
client code can hide that. The contract is unchanged; when Brain asks real
questions, the same endpoint starts returning them and clients need no change.

### 2026-11-24 — Brain pinned to 0.6.0

The Brain session described 0.6.0 as a behaviour change only (`Edge`
unchanged: more suggested links, and "before" links pointing the right way).
It assumed a `from:` requirement. The server pins `exact:` (ADR-0003), so
nothing moves until the pin does, which is the point.

**Found:** local builds use `../Brain` by path, which was already at 0.6.0,
while CI and Docker built 0.5.1. Local testing and CI were on different Brain
versions without anyone choosing it. Now both are 0.6.0.

**Verified on 0.6.0:** all 110 tests pass against the local checkout and in CI
mode, resolving the GitHub tag (`8f23d60`). No server change was needed.

**Lesson:** before taking a Brain tag, check `git -C ../Brain describe --tags`
against `brainTag`. They should match; if not, local results don't describe CI.

### 2026-11-24 — S6b: Oracle VM, surveyed before changing anything

Decided by Ganesh: host on the existing Oracle VM; API at
**brain-api.corelearnly.com**; the website on the same VM; Google AI key now.

**The VM as it is** (read-only survey): Ampere ARM64, **1 OCPU, 5.8 GB RAM**,
2 GB swap (0.5 GB used), 28 GB disk free, Ubuntu 22.04, **no IPv6**. Eleven
containers (n8n, Immich, Vaultwarden, Glance, BookOrbit and their databases),
about 1.8 GB together. **One shared Caddy** (v2.11.3, in `~/n8n`, config
`~/n8n/conf/Caddyfile`) owns 80 and 443 and serves five `*.corelearnly.com`
sites with automatic HTTPS. Apps join the external network `proxy_net` and
publish no ports. DNS has one A record per subdomain, no wildcard.

**What that changes:**
- **Half the planned machine** (ADR-0001 assumed 2 OCPU / 8–12 GB). Running is
  fine; compiling Swift there is not. Images are built on the Mac (also arm64)
  and streamed over with `docker save | ssh docker load`. No registry, no tokens.
  `WORKER_CONCURRENCY=2`, `mem_limit: 512m`, log rotation 3 × 10 MB.
- **No IPv6:** the Supabase session pooler (IPv4) is the only option.
- **Caddy is shared by five live sites.** A bad Caddyfile takes all of them
  down. Every change: back up, `caddy validate`, then `caddy reload`.

**Deployment files are versioned** in `deploy/oracle/` (compose file and env
template). The filled `.env.production` is gitignored and goes to
`~/brain/.env` with `chmod 600`. The image tag is the git commit it was built
from.

**Noticed, not changed:** Caddy runs unpinned `caddy:latest` and every site
depends on it. Pinning it is Ganesh's call, since it's part of the n8n setup.

**Done so far:** D1, image `brain-server:b4caf59` loaded on the VM (it gained
curl and a Docker health check, verified healthy). D2, `~/brain` (mode 700)
with the compose file. Nothing started; no existing container touched.

### 2026-11-24 — Supabase project moved to Mumbai; its CA is required

**Measured first:** the VM is in `ap-mumbai-1` (instance metadata). The first
Supabase project was in Tokyo, and TCP connects from the VM to its pooler took
**128–142 ms**. Requests run queries in sequence (plan ≈ 4, item edit ≈ 6), so
distance alone would have added 0.3–0.7 s to every screen. Supabase can't move
a project between regions, and the old one held one test login, so Ganesh
created **`rqxvzishfcthajxejvvn` in ap-south-1**. Its JWKS is ES256, email
sign-in is on, anonymous sign-ins are off. Server `.env`, `.env.production`,
the deploy template, the Website's `.env.local`, and the `supabase-brain` MCP
all point at it now.

**The CA file is required, not optional, for Supabase.** A TLS handshake from
the Mac: with Supabase's `prod-ca-2021.crt`, the chain and hostname
(`*.pooler.supabase.com`) verify (code 0). With system roots only, they fail
(code 19: Supabase signs with its own root). `verify-full` without the file
therefore fails closed.

### 2026-11-24 — S6b: live at https://brain-api.corelearnly.com

- **D3, start.** `.env` sent over SSH with `umask 077` set before any byte is
  written (mode 600), plus the Supabase CA. `docker compose up -d`. Migrated
  against Supabase over verify-full TLS on first start. Healthy in 25 s; uses
  **6.4 MB**.
- **Data API exposure, checked from outside.** The publishable key gets
  `permission denied` (42501) on every table, including `_hb_pg_migrations`,
  which has no RLS. The new project doesn't grant `anon` on tables created
  directly, so RLS is the second layer, not the first. Run the security
  advisor once the `supabase-brain` MCP is logged in.
- **D5, Caddy.** Timestamped backup (`Caddyfile.bak-20261124-061852`), one
  block appended (`reverse_proxy brain-server:8080`, 1 MB body limit),
  `caddy validate`, then `caddy reload`. The "not formatted" warning points
  at line 2 of the existing file, not ours. Rollback: restore the backup and
  reload.
- **D6, smoke test.** Let's Encrypt certificate, HTTP→HTTPS 308, `/health` 200,
  `/v1/me` without a token 401, a full HTTPS request in 47 ms from the Mac. All
  five existing sites still return 200.

**Not yet verified in production:** a real signed-in request. That needs the
website served from the VM (D7, same origin) or CORS.

### 2026-11-24 — S6b D7: website live at https://brain.corelearnly.com

Built and deployed from the Website repo (`make deploy`, see its W2 entry):
static files in `~/n8n/site/brain`, served by the shared Caddy. One Caddy
block: `/v1/*` goes to `brain-server:8080` (1 MB body limit), and everything
else is the single-page app (`try_files {path} /index.html`). `/assets/*`
(hashed names) is cached for a year and immutable; `index.html` is `no-cache`;
zstd/gzip. Website and API share one origin, so no CORS anywhere.

**Verified against the VM** (the Mac's resolver was still caching the
pre-record NXDOMAIN): Let's Encrypt certificate obtained, page 200, deep link
`/today` 200, assets immutable and zstd-compressed, `/v1/me` 401 without a
token. All six other sites 200.

**A false alarm worth remembering.** My first attempt's safety check read
only the **last line** of `caddy validate`. Caddy's log lines arrive in
varying order, so a valid config looked invalid, and the backup was restored
(correctly: nothing was reloaded). The check now looks for "Valid
configuration" anywhere in the output, and prints it. Two backups exist from
this step: `Caddyfile.bak-20261124-063648` and `…-063700`.

**Production end to end is still unverified:** a real sign-in at
brain.corelearnly.com, which needs the redirect URLs set in the Mumbai project.

### 2026-11-24 — Website and server stay together on the VM (not Netlify)

Ganesh's call, after comparing. **Same origin** means no CORS code and no
preflight requests. Users and the server are both in India, so a global CDN
would gain little. The VM going down takes out the API either way, so a
separately hosted website wouldn't be usable. Serving ~700 KB of cached static
files costs the VM almost nothing, and it is already working (`make deploy`).
**Revisit if:** users far from India, preview deploys become wanted, or the VM
gets crowded (then move the API first, not the website).

### 2026-11-24 — Production verified end to end, model path included

Ganesh signed in at https://brain.corelearnly.com with **Google** (W3) and
captured seven things. Read from the VM's log: all seven stored and enriched,
with no errors, refusals or budget problems. Six had their type settled by the
rules (T0, `tokens=0`), including a short vague one. Brain files a verbless
capture of eight words or fewer as a `note`, and abstains only when longer.
A deliberately long, verbless capture was the **first live model call**:
`routed=["classifyType"]`, type decided at **T2**, `tokens=200` (estimate,
in line with Brain's ~281 measured for Decision 1), saved.

So every link has run in production: Google sign-in → website → API (same
origin) → Supabase Postgres (verify-full) → worker → Gemini → stored, with the
daily budget kept in Postgres.

**Gap noticed:** the log names the tier but not *which* model answered, or
with what confidence. Worth adding before there are real users to watch.

### 2026-11-24 — Planner step 3 begins: Brain 0.7.0 (P0)

Brain 0.7.0 adds commitments, period goals and the plan's commitments section
(`../Brain/docs/15-planner.md`, accepted by Ganesh today). The pin was
`exact: "0.6.0"`, not `from: "0.5.1"` as the Brain session's note assumed, so
a one-line bump was needed. Verified: `make ci` passes (48 tests, lint clean)
against the local checkout, which is the 0.7.0 tag (`2a9cac3`), and
`BRAIN_FROM_GIT=1 swift build` builds from the tag as Docker does. No server
code changed; plan results are unchanged because no goal has a period yet and
no commitments are passed.

Step 3 decisions, taken on Ganesh's "go with your recommendations":
1. **Corrections export** includes item and capture titles, with users
   pseudonymised; an operator command, not an HTTP endpoint. The T&C must say
   corrections may leave the database for improving Brain.
2. **A skip breaks the streak** (Brain counts only completions); reviews show
   skipped and missed apart. An `excused:` set was requested from Brain.
3. **Moved**: the original day is not a miss; the occurrence shows on the new
   day marked `movedFrom`; completing it counts for the original day.
4. **Deleting a commitment archives it**: it disappears, its history stays.

Still asked of Brain: the answering rung, model and confidence in
`EnrichmentTrace`, so the log can say which model answered.

### 2026-11-24 — P1: corrections export, and confidence in the log

**Corrections export** is an operator subcommand of the same binary:
`docker exec brain-server ./brain-server export-corrections [--since YYYY-MM-DD] > corrections.jsonl`.
`brain-server` with no subcommand still serves, so the container's command is
unchanged. One JSON line per correction: field, tier, before/after, the
target (item / edge / goal) with its title and the capture's text, and titles
for before/after values that are item or goal ids, so a `bigTask` swap is
readable. Users are a 16-hex salted SHA-256 (`CORRECTIONS_EXPORT_SALT`, done
in Postgres, which has `sha256()` built in, so no crypto dependency is
added); the same salt gives the same pseudonym across exports. No HTTP
route: cross-user data never goes near the request path. Tested: context is
joined, the raw user id is absent, pseudonyms are stable per user and differ
between users.

**Log:** `capture enriched` gains `confidence` (per settled field, two
decimals, never the value). The model's name cannot be logged yet:
`EnrichmentTrace` keeps only `routedCapabilities`, and Brain's router is
designed so the pipeline never learns which rung answered. Requested from
Brain.

### 2026-11-24 — P2–P3: planner schema (M0005) and storage

Tables per `Brain/docs/15-planner.md`, none of them `items`:
- `commitments`: the rule as a discriminator plus `rule_weekday` / `rule_day` /
  `rule_n`, one CHECK per shape (day 1–31, n 1–5, weekday 1–7; Brain accepts
  any `Int`, the database refuses `monthlyOnDay(32)`). `minutes` 0–1440.
  `note` ≤ 200 characters, never parsed or summed. `archived` for deletes.
- `occurrences`: `(user, commitment, day)`, state `done | skipped | moved`,
  `moved_to` required for moved and forbidden for skipped. No `missed`; no
  rows generated ahead of time. Reads by range include rows moved *into* it.
- `journal_entries`: one per `(user, day)`, ≤ 2,000 characters.
- `goals`: `period` (CHECK on `2026-11` / `2026-Q4`) and `parent_id` (same
  user, not itself). Whether a parent is a legitimate rollup is the API's
  check (`canRollUp`), as Brain intends.
- `daily_plans`: `(user, day)`, chosen and proposed item, `swapped` (CHECKed
  to equal proposed ≠ chosen). A swap writes a `bigTask` correction against
  T0 in the same transaction, once per change of choice, so a retry adds
  nothing.

**Found and fixed on the way:** postgres-migrations' `_hb_pg_migrations`
table sits in `public` with RLS **off**. Not reachable on the current
Supabase project (it grants `anon` nothing), but it is exactly what the
security advisor flags. M0005 enables RLS on it; the server owns the table,
so it is unaffected. A new catalog test now fails for any `public` table
with RLS off or (user data) without `user_id`, including future ones.

Verified: 41 storage tests, and M0005 applied on the populated dev database
on top of M0004 with rows kept.

### 2026-11-24 — P4: planner API

Contract first (`openapi.yaml`), then handlers (`APIHandler+Planner.swift`).
- `/v1/commitments` CRUD. DELETE archives and sets `endOn` to today, so
  later days never count as missed; history stays.
- `PUT|DELETE /v1/commitments/{id}/occurrences/{day}`: `not_scheduled` if the
  rule does not put it on that day; done refused for a day not yet come
  (`in_future`); moved needs a different `movedTo`. Done after a move keeps
  `moved_to` and counts for the original day (decision 3).
- `GET /v1/occurrences?from&through`: expanded on read (≤ 92 days), with
  moved-in occurrences; place each on `movedTo ?? day`.
- `/v1/journal` (≤ 2,000 characters, one per day, not in the future).
- `/v1/daily-plans`: confirm yesterday/today/tomorrow only; the item must be
  open; a swap is a `bigTask` correction (D4).
- `GET /v1/review`: per commitment expected / done / skipped / moved /
  missed, Brain's hit rate and streak; goals overlapping the range with their
  rolled-up children; journal count; big tasks confirmed and swapped.
- Goals take `period` and `parentId`; `?period=` filters. A bad rollup is
  400 `invalid_rollup`, including moving a quarter so a month child no longer
  fits (Brain's `canRollUp`, which Brain deliberately leaves to the writer).
- `/v1/plan` gains `day`, `commitments` (Brain's section with each
  occurrence's state, plus anything moved into today, marked `movedFrom`),
  `committedMinutes` (only what is still owed: done, skipped and moved-away
  are not) and `bigTask`. `ranked` is untouched: tested that a commitment
  never appears in it.

Clearing an optional field is an explicit `clear: [...]` list, because the
generator decodes an absent field and `null` to the same `nil`.

Tested: the 02:00 IST Monday / Sunday-in-UTC case (an Indian user sees
Monday's ritual, a UTC user Sunday's), the validation codes above,
isolation (another user's commitment is 404 everywhere), streak, move then
done, a review with three misses and no stored rows for them, rollups, the
swap correction, the journal. Also fixed two descriptions in the spec that
YAML flow syntax had silently cut at a comma.

### 2026-11-24 — P5: planner live in production (`brain-server:a15cdd4`)

Built on the Mac (arm64), streamed with `docker save | ssh docker load`,
`BRAIN_IMAGE_TAG=a15cdd4`, `docker compose up -d`. M0005 migrated against
Supabase on start; healthy; 6.3 MB. `CORRECTIONS_EXPORT_SALT` generated
(`openssl rand -hex 24`, never printed) and added to `~/brain/.env` (still
600, backup kept) and the local `.env.production`.

Checked from outside: `/health` 200, website 200, `/v1/plan` and
`/v1/commitments` 401 without a token, and n8n, immich, vault, start and
books all 200. The publishable key gets 401 from the data API on
`commitments`, `occurrences`, `journal_entries`, `daily_plans`, `goals` and
`_hb_pg_migrations`. `export-corrections` runs in the container (0
corrections so far).

**Rollback:** M0005 only adds tables and nullable columns, and the old code
names its columns, so setting `BRAIN_IMAGE_TAG=b4caf59` and
`docker compose up -d` returns to the previous server without touching data.

### 2026-11-24 — S6a: Brain 0.7.0 → 0.9.0, a live behaviour change

Pinned to tag 0.9.0 (`0beb889`, verified on the remote). Source-compatible:
`EnrichmentPipeline(timeZone:router:)` is unchanged, and `EnrichmentFeatures`
was added and removed between tags, never shipped. `make ci` passes with
`BRAIN_FROM_GIT=1` against the tag. What changes in production, all at once:

- **Category escalates to T2** when the rules abstain. Brain measured 67.0% →
  87.3% end-to-end, 90.8% precision on escalations (lexicon 88.0%).
- **Effort escalates to T2**, measured poor (median calibrated confidence
  0.393, 72% under a coin flip). Kept as shipped, Ganesh's call: for 2–3
  months of solo use a guessed size beats "unknown", and he corrects sizes
  by hand. Each edit is a correction against `t2`, so the record of how
  wrong it is accumulates; nothing learns from it until T1 exists.
- **T3 type questions are produced** when every rung abstains (stored by
  S6b, which ships with this pin and not before).
- Three T0 parser fixes (daypart leak, polluted referents, "due N days").
- `EnrichmentResult.pendingReferences` exists and is **deliberately unread**:
  the dependency backfill's first audit was 7 resolutions, 0 correct.

**Quota**, checked against `aistudio.google.com/docs/rate-limits` today:
Gemini Decision 1 free tier is 200 RPM, 50,000 TPM, 10,000 RPD; "applied
per project, not per API key"; RPD resets at midnight Pacific (Brain's
ledger already uses Pacific). Brain's dev split: **425 escalations** over
415 captures (25 type + 271 effort + 129 category, each the measured T0
abstention count), every one answered on the first rung, so about 1.02
Decision 1 requests per capture: about 9,800 captures a day **for all users
together** (the pool is the project's; `fairShare` divides it). Without
effort it would be 154 per 415, about 27,000. Brain's replay also logged 174
cassette-store misses: 87 `unknown` answers (64 effort, 23 category) times
the 2 later rungs. Those were lookups, not requests. **Live they are real
calls**: Brain's schema guard treats an explicit `unknown` like no answer, so
the router asks the next rung (production passes no cassette store,
`Application+build.swift`). Per pool, that is about **0.21 extra requests per
capture to Gemma and 0.21 to Flash-Lite**, and they can chain: Gemma's
`unknown` goes on to Flash-Lite, then to degrade, so the worst case is three
calls for a field that stays unresolved. 64 of the 87 are effort.

**The binding pool is Flash-Lite, not Decision 1.** Brain's rows: Gemma
14,400/day, Flash-Lite **500/day**. At 0.21 per capture, Flash-Lite runs out
at about 2,400 captures a day, which is ample for solo use but is the first
limit hit at scale. It sits last on every ladder, so the scarcest quota gets
the hardest cases. When it runs out the ladder degrades and the field stays
unresolved; nothing fails. Those two rows come from Ganesh's AI Studio
dashboard, not a public page; only Decision 1's is verified against Google's
docs. Stopping the ladder on an explicit `unknown` would remove this spend.
That is a Brain change and Ganesh's call; this entry describes today's
behaviour.

### 2026-11-24 — S6b: T3 questions are stored, answered, and become labels

Brain asks (`UserQuestion`, field `type`) when every tier abstains on a
capture's type. Until now the worker logged "questions not stored yet" and
dropped them. That never fired in production: on Brain 0.7.0 a question was
raised only by a T3 rung, and the production ladder has none. Asking on
abstention arrived after 0.7.0 (Brain `55e99a2`), so this ships with the
0.9.0 pin and not before.

- **M0006 `questions`**, additive (one new table, RLS on). `item_id` is
  NOT NULL and a foreign key (Ganesh's call over the brief's "nullable"):
  every enrichment has an item, a failed capture's included, so a nullable
  column could only ever mean an orphan. One question per item and field.
  `answer` must be one of the stored `options` and `field` must be one the
  server can apply (`type`), both as database CHECKs.
- **Written in the enrichment's transaction.** No item, no question; a
  retried enrichment writes neither.
- **An answer** (one transaction, question and item locked): checked against
  the *stored* options, never the client's; sets the field as the user's
  decision (confidence 1); writes a correction with **tier `t3`**, `before`
  the previous value (normally empty). `t3` is how `export-corrections`
  tells these apart from edits of a model's guess: they are the only labels
  no generator wrote. Same option again: 204, nothing written. A different
  option: 409 `already_answered`, because changing one's mind is an item
  edit, which records its own correction. Not an option: 400
  `not_an_option`. Another user's question: 404, whatever the option.
- **Editing an item's type closes its open question** in the edit's
  transaction, with no second correction.

Rollback: the previous image ignores the table. M0006 changes nothing that
exists.
