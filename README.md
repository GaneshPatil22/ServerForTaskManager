# Brain server

HTTP API and background worker for Brain: "Dump anything. It organises it,
finds what depends on what, and tells you the one thing to do next."

Product, architecture and accepted ADRs live in `../Brain/docs/` until a second
component needs them. Server-specific decisions are in `DECISIONS.md`.

## Run

    make help     # every target
    make ci       # what CI runs: lint + test
    make run      # http://127.0.0.1:8080/health

Brain is built from `../Brain` locally and from a pinned tag in CI
(`BRAIN_FROM_GIT=1`).
