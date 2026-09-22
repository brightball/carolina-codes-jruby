# Carolina Codes — JRuby API

Read-only Sinatra API on JRuby for the [Carolina Code Conference](https://carolina.codes) polyglot site.

This is a sibling of `carolina-codes-ruby`. It speaks the same v1 contract, including year-scoped routes:

- `GET /v1/speakers?year=2026`
- `GET /v1/speakers/2026/diana-pham`
- `GET /v1/sponsors?year=2026`
- `GET /v1/sponsors/2026/flywheel`

Queries PostgreSQL **v1 views**. Registers with the Elixir site once on boot.

Requires **JRuby 10.0 LTS** (Ruby 3.4 language level) on **JDK 27**. Puma 8 stays in single/threaded mode (`workers 0`, `PUMA_THREADS` default 3). Do not pass `jruby --dev`.

Production (Fly `auto_stop_machines`) uses Azul Zulu **JDK 27 CRaC** (`zulu27.28.101-ca-crac-jdk27.0.0`, Warp) with JRuby’s CRaC flags, not a cold JVM boot. There is no published `27-jdk-crac` image tag at GA, so the Dockerfile overlays that CRaC tarball on Ubuntu 22.04:

- Image build: `jruby --nocache --checkpoint=/app/.jruby.checkpoint` (`-XX:CRaCCheckpointTo`) plus `-XX:CRaCEngine=warp` and `-XX:CPUFeatures=generic` (Depot builders have extra CPU bits Fly Firecracker VMs lack). Loads the app **without** a listen socket, JDBC pool, or CMS registration. Restore falls back to a cold Puma boot if the snapshot cannot be restored.
- Start: `bin/start` → `jruby --nocache --restore=/app/.jruby.checkpoint` (`-XX:CRaCRestoreFrom`, Warp-only `JAVA_OPTS`). `config.ru` calls `acquire_after_restore!`, which copies restore-time `System.getenv` into Ruby `ENV` (CRaC leaves JRuby `ENV` at checkpoint values), warms the year-listing cache, then registers with the CMS. Catalog connect and the CMS POST are bounded to a few seconds so a blackhole cannot hold the listen socket. The JDBC pool is not opened at checkpoint. `/health` does not read the catalog.

Leyden `-XX:AOTCache` is the fallback if a CRaC JDK is unavailable; this image uses CRaC because restore is the Lambda/SnapStart analog for scale-to-zero.

```bash
# Requires JDK 27 + JRuby 10.0 LTS
bundle install
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4003 \
PORT=4003 \
bundle exec puma -p 4003
```

If this environment cannot run JRuby, the MRI Ruby API is the behavioral equivalent of this source.

```bash
bundle install
make test        # handler tests (fake catalog, no Postgres) + hook/workflow structure
make sast        # Semgrep CE Ruby rules
make audit       # bundler-audit against ruby-advisory-db
make gitleaks    # gitleaks detect
make style       # RuboCop
make check       # all five
make hooks       # install local pre-commit hooks
```

Pre-commit runs the same five checks (`tests`, `sast`, `audit`, `gitleaks`, `style`). Install once with `make hooks` (needs `pre-commit` on PATH). Emergency skip: `SKIP=tests,sast,audit,gitleaks,style git commit`.

Local warm-path check (Rack mock, 20 warmup GETs then 10 timed `GET /v1/speakers?year=2026`, same Postgres): JRuby 10.0.6.0 + this app averaged about 14 ms (min ~9 ms); MRI Ruby 3.3 averaged about 3.5 ms. JRuby remains slower than MRI on this path; the gap is the JVM/JDBC runtime, not query count (`perf_test.rb` still bounds year listing at ≤ 4 SQL).
