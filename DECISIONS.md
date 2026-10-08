# Decisions

Durable choices for this JRuby API. Each record has a status, context, decision, and consequences. Git history is the changelog. Do not store secrets, tokens, private hostnames, or credentials here.

Accepted decisions are binding. When a durable choice changes, update the record (or add one) in the same change as the code.

## 1. JRuby 10.0 LTS and Sinatra

Status: accepted

Context: The starter ships a replaceable runtime image and an empty `src/` tree. This repository is a finished API in the polyglot fleet.

Decision: Implement the API with JRuby 10.0 LTS (Ruby 3.4 language level) and Sinatra. The Dockerfile, Gemfile, and `app.rb` are the runtime, in place of a stub another language would replace.

Consequences: Production runs on JRuby. MRI 3.4 can run the fake-catalog tests when JRuby is absent. Do not reintroduce a replaceable starter runtime beside this app.

## 2. CRaC Warp on the JDK 27 overlay

Status: accepted

Context: Fly machine restart needs a checkpoint/restore path. At JDK 27 GA there is no `jruby:10.0-jdk27` image and no published `27-jdk-crac` tag. A stock JDK 27 build is not a CRaC runtime. Leyden AOT-only is not the restart path. JDK 21 and `21-jdk-crac` are not the target.

Decision: Production restart is CRaC Warp on a JDK 27 overlay. The image installs the `zulu27` CRaC tarball (`zulu27.28.101-ca-crac-jdk27.0.0`, Warp) on Ubuntu 22.04 and copies JRuby 10.0 LTS from `jruby:10.0`. Checkpoint runs at image build. `bin/start` restores with Warp.

Consequences: Keep the overlay until a real JDK 27 CRaC image tag exists. Do not move production back to JDK 21. Do not drop CRaC for Leyden AOT-only. Warp does not need extra Fly capabilities.

## 3. CMS v1 views

Status: accepted

Context: The starter includes Compose Postgres 18, `db/*.sql`, and imaginary seed data so a fork can boot alone. The live catalog is the CMS database.

Decision: Query PostgreSQL `v1_*` views in the CMS database. Never query Ash tables. This repo does not ship Compose Postgres 18, `db/*.sql`, or a local schema.

Consequences: Handler tests use a fake catalog and do not need Postgres. Live HTTP sets `DATABASE_URL` to the CMS database (local example: Postgres 16, `postgres://postgres:postgres@127.0.0.1:5432/carolina_dev`).

## 4. Register once

Status: accepted

Context: The CMS keeps at most one language API warm and keep-alives that process itself.

Decision: Register once on boot with `POST {CAROLINA_URL}/internal/api-endpoints/register`. Do not heartbeat. If `CAROLINA_URL` is unset or the POST fails, log and keep serving.

Consequences: A missing URL or token skips registration. A failed POST does not stop HTTP. There is no periodic re-register loop.

## 5. Five quality gates

Status: accepted

Context: Local commits, pre-commit, and Gitea must run the same checks. Rails-oriented and unmaintained Ruby scanners do not match this Sinatra app on JRuby 10.

Decision: Five gates, same commands in the Makefile, pre-commit, and Gitea: `make test`, `make sast` (Semgrep `p/ruby`), `make audit` (bundler-audit), `make gitleaks`, and `make style` (RuboCop). SAST is Semgrep `p/ruby`, not Brakeman and not dawnscanner.

Consequences: A new check is added in all three places together. `handler_test.rb` asserts the hook ids and Gitea jobs stay aligned. `make test` runs `handler_test.rb`.

## 6. Warm year listings

Status: accepted

Context: The CMS language picker allows only a short time for the upstream API. A cold catalog read of the year listings misses that budget, so the picker skips an otherwise healthy process.

Decision: Cache year-scoped speaker and sponsor JSON in process (`cached_listing`) and warm it from `acquire_after_restore!`. Fly `min_machines_running` is 0 so idle machines stop. The CMS keeps the selected API warm.

Consequences: `GET /health` still does not read the catalog. The cache is process-local and short-lived. Boot may log a catalog warmup failure and still serve `/health` and still attempt registration.
