# gitbucket-railway

A thin, production-oriented image for running [GitBucket](https://github.com/gitbucket/gitbucket)
on [Railway](https://railway.com), built on the upstream `ghcr.io/gitbucket/gitbucket:latest`
image.

GitBucket is a Git web platform written in Scala: repositories over HTTP and SSH,
issues, pull requests, wikis, a plugin system and a GitHub-compatible REST API.

## What this layer adds

| Change | Why |
|---|---|
| Seeds the built-in `root` administrator from `GITBUCKET_ADMIN_PASSWORD` | GitBucket's own database migration creates `root` with the password `root` and exposes no variable to change it. The entrypoint runs the app once on `127.0.0.1` so the schema is built and the password rewritten before the public port is bound. |
| `<secure>true</secure>` in the packaged `web.xml` | Jetty only flags `JSESSIONID` as `Secure` when the servlet cookie-config says so; behind Railway's TLS-terminating edge every request arrives as plain HTTP. |
| `-XX:MaxRAMPercentage=70` and `-XX:ActiveProcessorCount` from the cgroup | Railway hosts report 48 cores; JDK 17's `availableProcessors()` reads the host, not the quota. |
| PostgreSQL wiring from `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD` | Turns Railway's managed database references into the `GITBUCKET_DB_*` settings GitBucket reads, and waits for the database before the first migration. |
| SSH clone URLs from `RAILWAY_TCP_PROXY_*` | Re-read on every boot, so a regenerated proxy port heals itself. |

## Environment variables

| Variable | Required | Notes |
|---|---|---|
| `GITBUCKET_ADMIN_PASSWORD` | on the first boot | Password for the built-in `root` administrator. Ignored on later boots, so changing it in the UI is never reverted. |
| `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` | yes | Reference Railway's managed PostgreSQL service. |
| `PORT` | yes | Port the web UI binds. |
| `GITBUCKET_HOME` | no | Defaults to `/gitbucket`; mount the volume there. |
| `GITBUCKET_BASE_URL` | no | Derived from `RAILWAY_PUBLIC_DOMAIN`. Set it only for a custom domain. |
| `GITBUCKET_DB_URL`, `GITBUCKET_DB_USER`, `GITBUCKET_DB_PASSWORD` | no | Set all three to point GitBucket at a database of your own; the managed wiring and the administrator seed are then skipped. |
| `JAVA_OPTS` | no | Appended after the defaults above, so it wins. |

## Licence

GitBucket is Apache-2.0. This packaging is provided under the same terms.
