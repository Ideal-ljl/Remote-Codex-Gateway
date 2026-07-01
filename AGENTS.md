# Repository Engineering Standards

This repository is trimmed for one purpose: running the remote Codex gateway
with account rotation, quota thresholds, terminal device auth, and config-driven
deployment.

## 1. Project Shape
- `deploy/remote-codex-gateway/`: install/start/login/key/config scripts for
  remote servers.
- `crates/service/`: HTTP/RPC service, gateway routing, protocol adapters,
  account/API key/usage domains, and runtime sync.
- `crates/core/`: SQLite migrations, storage primitives, auth helpers, and core
  usage/account data structures.
- `crates/rusqlite/`: bundled SQLite compatibility layer used by the service.

## 2. Ownership Boundaries
- Keep remote package behavior in `deploy/remote-codex-gateway/`.
- Keep gateway/protocol/account behavior in `crates/service/`.
- Put schema and persistence foundation changes in `crates/core/`, especially
  SQLite migrations and reusable storage helpers.
- Avoid expanding central entrypoints with unrelated orchestration. New
  substantial logic should move into focused modules or domain helpers.

## 3. Settings and Persistence
- User-facing remote gateway behavior should be controlled by
  `deploy/remote-codex-gateway/config.env`.
- New `CODEXMANAGER_*` or `REMOTE_GATEWAY_*` environment variables require
  documentation updates in the root README and package README.
- SQLite schema changes belong in `crates/core/migrations/` and should include
  storage-level tests when behavior is non-trivial.

## 4. Rust Service Rules
- Keep gateway/protocol changes localized under `crates/service/src/gateway/`
  and `crates/service/src/http/` unless shared service state is genuinely needed.
- Protocol adapter changes must consider `/v1/responses`, `/v1/chat/completions`,
  streaming SSE, non-streaming JSON, tools, and `tool_calls`.
- Prefer typed request/response structs and existing storage helpers over ad hoc
  JSON or string manipulation.
- Web access, roles, billing/account mode, and API key ownership are security
  boundaries; do not weaken checks for UI convenience.

## 5. Validation
- Script changes: run `bash -n` on touched shell scripts and `git diff --check`.
- Rust/service changes: run `cargo test -p codexmanager-service`, or the
  narrowest relevant package test only when the change is clearly isolated.
- Gateway/protocol changes require targeted regression coverage for streaming,
  non-streaming, tools, and both supported OpenAI-style endpoints.
- If a validation step cannot run in the current environment, record the exact
  command and the reason it was not executed.

## 6. Documentation
- Keep `README.md` and `deploy/remote-codex-gateway/README.md` aligned with
  deployment modes, environment variables, and install/build commands.
