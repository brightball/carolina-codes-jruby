# Carolina Codes — JRuby API

Read-only Sinatra API on JRuby for the [Carolina Code Conference](https://carolina.codes) polyglot site.

This is a sibling of `carolina-codes-ruby`. It speaks the same v1 contract, including year-scoped routes:

- `GET /v1/speakers?year=2026`
- `GET /v1/speakers/2026/diana-pham`
- `GET /v1/sponsors?year=2026`
- `GET /v1/sponsors/2026/flywheel`

Queries PostgreSQL **v1 views**. Registers with the Elixir site once on boot.

```bash
# Requires a JVM + JRuby
bundle install
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4003 \
PORT=4003 \
bundle exec puma -p 4003
```

If this environment cannot run JRuby, the MRI Ruby API is the behavioral equivalent of this source.
