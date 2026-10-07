# carolina-codes-jruby

Agent entry for this finished read-only v1 API: **JRuby 10.0 LTS** and **Sinatra** on **JDK 27 CRaC Warp**.

The forkable starter (`carolina-codes-api-starter`) supplied the original contract. This repository is the implementation. Treat [DECISIONS.md](DECISIONS.md) as binding. Read [MEMORY.md](MEMORY.md) before changing boot, checkpoint, or tests. Update the matching file when a durable choice or a non-obvious correction changes. Accepted decisions are binding. Do not store secrets, tokens, private hostnames, or credentials in either file.

## Contract

The HTTP contract is the CMS repo (`github.com/brightball/carolina-codes`): `priv/api/openapi.yaml` and `priv/api/AGENTS.md`. This repo does not ship a local `openapi.yaml`.

This repository is its own git root. Do not fold it into the CMS remote. Do not assume a sibling checkout (`../elixir` or another language tree) is present.

- Query PostgreSQL `v1_*` views only (`v1_years`, `v1_speakers`, `v1_talks`, `v1_sponsors`, `v1_sponsorships`, `v1_year_sponsors`). Never query Ash tables.
- Wrap lists as `{ "data": [ ... ] }`. Unknown slugs return 404 `{ "error": "not_found" }`.
- `GET /health` returns `{ "ok": true }` and does not read the catalog. `GET /` returns identity (language, framework, endpoints).
- Public routes: `GET /health`, `GET /`, `GET /v1/years`, `GET /v1/speakers`, `GET /v1/speakers?year=`, `GET /v1/speakers/:slug`, `GET /v1/speakers/:year/:slug`, `GET /v1/sponsors`, `GET /v1/sponsors?year=`, `GET /v1/sponsors/:slug`, and `GET /v1/sponsors/:year/:slug`.
- Register once on boot with `POST {CAROLINA_URL}/internal/api-endpoints/register` and `Authorization: Bearer {POLYGLOT_REGISTER_TOKEN}`. No heartbeat. If `CAROLINA_URL` is unset or the POST fails, log and keep serving.
- Ordinary JSON. Leave Ash JSON:API unimplemented.

## Environment

| Variable | Example | Role |
| --- | --- | --- |
| `DATABASE_URL` | `postgres://postgres:postgres@127.0.0.1:5432/carolina_dev` | CMS SQL views |
| `CAROLINA_URL` | `http://127.0.0.1:4000` | CMS base URL. Register no-ops when unset or down. |
| `POLYGLOT_REGISTER_TOKEN` | `dev` | Bearer token for register |
| `PUBLIC_BASE_URL` | `http://127.0.0.1:4003` | URL the CMS will call |
| `PORT` | `4003` | Listen port |

Live HTTP against the views needs Postgres 16 and those variables. Handler tests do not.

## Runtime

Production restart is CRaC Warp on the JDK 27 overlay. Image build runs `jruby --nocache --checkpoint`. `bin/start` runs `jruby --nocache --restore` and cold-starts Puma if restore fails. `config.ru` calls `acquire_after_restore!` after restore. Checkpoint does not open a listen socket, a JDBC pool, or CMS registration. See [DECISIONS.md](DECISIONS.md) and [MEMORY.md](MEMORY.md).

## Tests and gates

`handler_test.rb` drives the shipped Sinatra app (`require_relative "app"`, `Rack::MockRequest`, `Sinatra::Application`) with a fake catalog. Handler tests do not need Postgres. MRI can run them when JRuby is absent. Do not name test helpers `get` or `post`.

The same five commands run locally, in pre-commit, and in Gitea (`.gitea/workflows/precommit.yml`):

- `make test`
- `make sast` (Semgrep `p/ruby`)
- `make audit` (bundler-audit)
- `make gitleaks`
- `make style` (RuboCop)

`make check` runs all five. `make hooks` installs pre-commit. Emergency skip: `SKIP=tests,sast,audit,gitleaks,style git commit`.

## Layout

| Path | Role |
| --- | --- |
| `app.rb` | Sinatra routes, catalog, registration |
| `config.ru` | Acquire the catalog and register after restore, then run |
| `bin/crac_checkpoint.rb` | Image-build checkpoint |
| `bin/start` | Restore, or cold-start Puma |
| `config/puma.rb` | Puma 8, single process, IPv6 bind |
| `handler_test.rb` | Fake-catalog handler tests and gate structure |
| `Dockerfile` | JRuby 10.0 LTS on the JDK 27 CRaC overlay |
| `Makefile` | The five quality gates |
| `Gemfile` / `Gemfile.lock` | Sinatra, Puma, Sequel, jdbc-postgres |
| `fly.toml` | Fly app settings |
| `DECISIONS.md` | Accepted decisions |
| `MEMORY.md` | Non-obvious corrections |

Starter-only layout is not this repo: a replaceable `Dockerfile`, `src/`, a local `openapi.yaml`, Compose Postgres 18, `db/*.sql`, and `tests/test_catalog.py`.

## Maintaining these notes

[DECISIONS.md](DECISIONS.md) holds durable choices (status, context, decision, consequences). Git history is the changelog. [MEMORY.md](MEMORY.md) holds corrections that names alone get wrong. Update the matching file when a durable choice or a non-obvious correction changes. Accepted decisions are binding. Do not store secrets in either file.
