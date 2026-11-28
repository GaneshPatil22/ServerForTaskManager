# Brain server

> **Dump anything. It organises it, finds what depends on what, and tells you
> the one thing to do next.**

This repo is the **HTTP API and the background worker**. It owns everything
Brain deliberately does not: identity, storage, scheduling, retries and the
public contract.

Brain itself is linked in as a Swift package — there is no service call
between them.

---

## The product, in one page

A person types whatever is in their head. Each dump becomes an **item** with a
type, a due date, a size and a category; dependencies are found between items;
the plan is ranked; the user confirms one big task for the day.

**The one rule:**

> **AI proposes. Deterministic code verifies and decides. The human confirms.**

**Explicitly not this product** — expense tracking, subscriptions, gym/health,
social features, collaboration.

**The three repos**, built in this order:

| Repo | Role |
|---|---|
| [Brain](https://github.com/GaneshPatil22/BrainForTaskManager) | Understands a capture. Ranks the graph. No I/O. |
| **Server** (this one) | HTTP API, Postgres, auth, background worker. |
| [Website](https://github.com/GaneshPatil22/WebAppForTaskManager) | React PWA. Captures offline, draws what this returns. |

Product, architecture and accepted ADRs live in `../Brain/docs/`.
Server-specific decisions — including every deploy and its rollback tag — are
in `DECISIONS.md`.

---

## What this server is responsible for

- **Identity.** Verifying Supabase access tokens against the project's JWKS,
  and turning one into a `UserID`.
- **Storage.** Postgres, where the schema itself enforces the domain
  invariants rather than trusting application code.
- **The contract.** `Sources/API/openapi.yaml` is the source of truth for
  every endpoint, and both this server's types and the website's are generated
  from it.
- **Durability.** A capture is committed before the response is sent, and the
  sweeper guarantees it is eventually enriched even if its job is lost.
- **Scheduling.** A job queue, retries, and the per-user share of the daily
  model budget.

It is **not** responsible for understanding a capture or ordering a plan.
Both of those are calls into Brain.

---

## Run it

    make help     # every target
    make db-up    # local Postgres in Docker, waits until it is actually ready
    make run      # the API and the worker, on http://127.0.0.1:8080
    make ci       # db-up + lint + test. If this passes, CI passes.

First time:

    cp .env.example .env     # then fill it in

The minimum that boots against the local Docker Postgres:

```sh
DATABASE_HOST=127.0.0.1
DATABASE_PORT=54329
DATABASE_USER=brain
DATABASE_PASSWORD=brain
DATABASE_NAME=brain_dev
DATABASE_TLS=disable
SUPABASE_URL=https://<your-project>.supabase.co
GOOGLE_AI_API_KEY=          # empty is fine: rules only (T0), no model calls
WORKER_CONCURRENCY=4
```

Three things worth knowing before the first run:

- **There are no defaults for configuration.** A missing `DATABASE_*` variable
  is a deliberate hard failure. A server that starts pointing at the wrong
  database is worse than one that will not start.
- **Auth is always real**, even locally. There is no local Supabase: the
  database is Docker on your machine, identity comes from the real project.
- **No API key is not an error.** Without `GOOGLE_AI_API_KEY` the worker runs
  on rules alone, says so loudly at startup, and captures still become items.

Brain is resolved from `../Brain` locally and from its pinned git tag when
`BRAIN_FROM_GIT=1` (CI and the Docker image). Current pin: **0.11.0**.

Check it:

    curl -i http://127.0.0.1:8080/health   # 200, the only route without a token
    curl -i http://127.0.0.1:8080/v1/me    # 401, as it should be

---

## Layout

| Path | Contents |
|---|---|
| `Sources/API` | `openapi.yaml` and the types generated from it at build time. |
| `Sources/App` | Hummingbird wiring, auth middleware, the handlers. |
| `Sources/Auth` | Supabase token verification. No Hummingbird here: token in, `UserID` out. |
| `Sources/Storage` | The only module that can talk to Postgres. Migrations live here. |
| `Sources/Worker` | The enrichment job, the sweeper, and the call into Brain. |
| `deploy/oracle/` | The production compose file and env template. |
| `DECISIONS.md` | Every step, every deploy, every rollback tag. |

---

## How a capture moves through here

### 1. In — `POST /v1/captures`

`AuthMiddleware` turns the bearer token into a `UserID`, or refuses:

| Situation | Status | Why |
|---|---|---|
| Missing, malformed, expired or wrongly signed token | `401` | Genuinely not allowed; the client signs out. |
| Supabase's keys unreachable | `503` | **We could not check.** A 401 here would log every user out because a third party had a bad five minutes. |

Then `APIHandler.createCapture` validates, clamps a future `capturedAt` to now
(a wrong phone clock must not cost you the thought), and inserts:

```sql
INSERT INTO captures (...) VALUES (...) ON CONFLICT DO NOTHING RETURNING id
```

A row back means `201`. No row means this id is already stored, so the capture
is read back and returned with `200` — which is the correct answer to a retry,
not an error. The client generates the ULID, so it doubles as the idempotency
key.

**Only then** is the enrichment job queued, and queuing is allowed to fail:

```swift
if created { await enrichment.enqueue(user: store.user, capture: stored.id) }
```

A lost job only *delays* enrichment. The sweeper runs every minute and
requeues any capture with no item that is `raw` past its grace period, stuck
in `enriching`, or `failed`.

### 2. Across — into Brain

The worker claims the capture with a single `UPDATE` that is the entire
concurrency control: two workers racing it means exactly one gets a row back.
Then it gathers what Brain needs and calls it:

```swift
let result = await EnrichmentPipeline(timeZone: tz, router: router).enrich(
    capture: capture, graph: try await store.graph(), now: now,
    idGenerator: &ids, requester: try await requester(for: user, now: now))
```

- `store.graph()` rebuilds the graph by replaying every stored edge through
  `BrainGraph.addEdge`, so a stored cycle fails loudly rather than being
  ranked.
- `requester` carries that user's fair share of the daily model pool, sized by
  how many users captured anything in the last 24 hours. The free-tier pool is
  **per Google project, shared across users** — not per key.

### 3. Back — one transaction

Brain's suggested edges are checked **again** here through the graph's own
rules (guard 6, deliberately duplicated), T3 questions are filtered to fields
this server can actually apply an answer to, and then everything lands at once:

```swift
saveEnrichment(capture:status:item:edges:questions:)
```

Capture row locked, bail if an item already exists, insert the item, the
edges, the questions, and advance the capture's status — all or nothing. There
is no window in which an item exists with half its links.

The trace is logged as tiers, confidences and token counts. **Values are never
logged**, and neither are Brain's notes, because a note can quote the capture.

### 4. Out — `GET /v1/plan`

Loads the graph and calls `Brain.compute`. No model participates. Since Brain
0.11.0 the plan excludes `idea` and `note`, and `confirmDailyPlan` refuses to
accept one as the day's big task, so the read and write sides agree.

---

## What the database enforces, not the code

`Sources/Storage/Migrations/M0001_CoreTables.swift` — these are guarantees, not
habits:

1. **Every primary key is `(user_id, id)`, and every foreign key includes
   `user_id`.** A row cannot reference another user's row; the foreign key has
   nothing to match.
2. **Captures are never deleted and never edited.** A trigger raises on
   `DELETE` and permits only `status` to change on `UPDATE`. Corrections are
   append-only.
3. **`confirmed` requires `source = 'user'`.** No model-suggested link can
   ever be stored as confirmed.

Plus a `ulid` domain with a format `CHECK`, so a malformed id cannot be stored
anywhere.

**RLS is enabled on every table with no policies.** That is deliberate: it
denies Supabase's auto-generated data API (`anon`, `authenticated`) all access,
while leaving this server — which connects as the owner — unaffected. The real
boundary is `UserStore`; the `PostgresClient` is internal to the `Storage`
module, so code outside it cannot write a query at all.

Another user's id returns **404, never 403**, so ids cannot be probed.

Migrations are forward-only, numbered `M0001`–`M0007`, and applied in one
transaction at boot. That is safe because exactly one instance runs.

---

## Endpoints

All require `Authorization: Bearer <Supabase access token>` except `/health`.

| Group | Routes |
|---|---|
| Identity | `GET/PATCH /v1/me` |
| Captures | `POST/GET /v1/captures`, `GET /v1/captures/{id}` |
| Items | `GET /v1/items`, `GET/PATCH /v1/items/{id}` |
| Goals | `GET/POST /v1/goals`, `PATCH /v1/goals/{id}`, `/v1/goals/{id}/marks[/{markId}]` |
| Plan | `GET /v1/plan`, `GET/PUT /v1/daily-plans[/{day}]`, `GET /v1/review` |
| Commitments | `/v1/commitments`, `/v1/commitments/{id}/occurrences/{day}`, `GET /v1/occurrences` |
| Journal | `GET /v1/journal`, `PUT/DELETE /v1/journal/{day}` |
| Links | `GET/POST /v1/edges`, `POST /v1/edges/{id}/confirm`, `POST /v1/edges/{id}/reject` |
| Questions (T3) | `GET /v1/questions`, `POST /v1/questions/{id}/answer` |
| Comments | `GET/POST /v1/comments`, `PATCH/DELETE /v1/comments/{id}` |

Comments and count goals are the user's own records. **Brain never reads
them**, never classifies them and never sends them to a model, and count goals
count occurrences — never money.

---

## Production

Live at `https://brain-api.corelearnly.com` and, same-origin with the website,
at `https://brain.corelearnly.com/v1/*`.

The VM is Oracle Ampere, **ARM64, 1 OCPU, 5.8 GB RAM, no IPv6**, in
`ap-mumbai-1`, already running eleven other containers behind one shared Caddy.
Three consequences, each of which explains a choice:

- 1 OCPU cannot compile Swift → images are built on the Mac (also arm64) and
  streamed over with `docker save | ssh docker load`. No registry, no tokens.
- No IPv6 → the Supabase session pooler (IPv4) is the only route in, and
  `verify-full` needs Supabase's own root certificate, so it fails closed
  without the CA file.
- Caddy is shared → a bad Caddyfile takes down every site on the VM. Every
  change is **back up → `caddy validate` → `caddy reload`**.

Deploy:

```sh
BRAIN_FROM_GIT=1 make ci
git checkout -- Package.resolved          # that run rewrites it
docker build -t brain-server:$(git rev-parse --short HEAD) .
docker save brain-server:<sha> | ssh -i KEY ubuntu@HOST docker load
# on the VM, in ~/brain: set BRAIN_IMAGE_TAG=<sha> in .env (mode 600)
docker compose up -d
```

Migrations run on start. Then check **from outside**: `/health` 200, a `/v1/*`
route 401 without a token, the Supabase publishable key refused on every table,
and every other site on the VM still 200.

**Rollback** is the previous `BRAIN_IMAGE_TAG` plus `docker compose up -d`.
That works because every migration so far has been additive — new tables, new
nullable columns — which the previous image simply never reads. A migration
that *changed* a column would need a different plan, written before it ships.

Never commit secrets. `.env` and `.env.production` are gitignored; load them
for one command with `set -a && . ./.env && set +a`.
