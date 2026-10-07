# Agent memory

Non-obvious corrections for this JRuby and Sinatra API. Names in the code suggest the wrong behavior often enough that these are worth keeping next to the repo.

Accepted decisions live in [DECISIONS.md](DECISIONS.md) and are binding. Update this file when a non-obvious correction changes. Do not store secrets, tokens, private hostnames, or credentials here.

## Checkpoint and restore

- Checkpointed Ruby `ENV` stays at image-build values until restore copies `System.getenv`. `refresh_env_after_restore!` does that copy. `acquire_after_restore!` calls it before the catalog URL or the CMS registration is read. Reading `ENV` first uses the checkpoint-time values (often empty).
- Checkpoint must not open a JDBC pool, a listen socket, or CMS registration. `bin/crac_checkpoint.rb` only loads the app. `config.ru` acquires those after restore.
- `/health` does not read the catalog. A healthy liveness response does not prove `DATABASE_URL` was copied or that the CMS register POST ran.
- Restore must not re-pass heap, GC, or `CPUFeatures` flags. CRaC rejects flags that were captured at checkpoint. `CRAC_RESTORE_JAVA_OPTS` stays Warp-only (`-XX:CRaCEngine=warp`).
- Pass `--nocache` on both checkpoint and restore. JRuby injects AppCDS unless that flag is set, and those flags are not restore-settable.
- `CPUFeatures=generic` because the image builder CPU differs from the Fly VM. A checkpoint tied to the builder CPU can fail when the VM restores it. Do not pin a builder-specific feature list.
- Cold-start Puma if restore fails. `bin/start` logs `CRaC restore failed; cold-starting` and runs Puma through `config.ru`. `/health` returning 200 does not say which path ran.

## Tests

- Sinatra test helpers must not be named `get` or `post` (or another HTTP verb). Those names shadow the route DSL and break app boot when the test loads `app.rb`. The harness uses `http_get`.
- MRI can run the fake-catalog tests when JRuby is absent. `handler_test.rb` does not need Postgres or a JDK. `make test` runs that file. It does not run `perf_test.rb`.
