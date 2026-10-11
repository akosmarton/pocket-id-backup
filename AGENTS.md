# AGENTS.md

Operating notes for agents working in this repository. Read this before changing anything;
`README.md` is the user-facing documentation and must stay accurate after every change.

## What this is

A one-shot Docker job that dumps a Pocket ID database (`sqlite3 .dump` or `pg_dump`), uploads
the dump to `dumps/` and mirrors the uploads directory to `uploads/` with `s3cmd sync`
(upwards only). No daemon, no scheduler, no retention logic.

| File | Role |
|---|---|
| `Dockerfile` | alpine + `bash` + `ca-certificates` + `sqlite` + `postgresql-client` + `s3cmd`; no Pocket ID binary |
| `backup.sh` | the entire application: validate env → dump → archive → upload → sync uploads. Also sourceable — the README restore commands reuse its helpers (`main()` only runs when the file is executed) |
| `compose.yml` | **image build/push only** — one service, no runtime config, no build args, no helper containers; the job is started with `docker run` |
| `.env.example` | env contract; users copy it to `.env` (gitignored) |
| `README.md` | how it works, build/run, scheduling, restore runbook, security notes |

## Invariants — do not break these

1. **Never copy the database file; always dump it.** A plain `cp` of `pocket-id.db` while the
   instance runs loses whatever is committed in the WAL and can be torn. `sqlite3 .dump` reads
   a consistent snapshot; `pg_dump` uses a repeatable-read transaction.
2. **No migrations, ever.** The job must not embed or call the `pocket-id` binary: `export`
   and `import` run database migrations, so a binary that differs from the deployment rewrites
   the live database. The dump is version-agnostic by construction — that is why the repo has
   no version-pinning machinery.
3. **The Pocket ID data directory is mounted read-write** (`-v <dir>:/app/data`): SQLite in WAL
   mode needs the `-shm`/`-wal` files writable, and the uploads sync needs read access.
4. **Bind-mount label is `:z` (shared), never `:Z` (private).** The live Pocket ID instance
   mounts the same directory; a private relabel revokes the instance's access to its own
   database (SELinux denies, Pocket ID then loses its database lock and reports "another
   instance is running").
5. **s3cmd is driven by command-line arguments only** — no `-c`, no `~/.s3cfg`, no generated
   config file. Credentials are required; with empty ones s3cmd falls back to a config file and
   dies with "Configuration file not available". Addressing is virtual-host by default
   (`host_bucket = %(bucket)s.<host>`, UpCloud/AWS); `BACKUP_S3_FORCE_PATH_STYLE=true` switches
   to path style. The wrong choice fails loudly: `405 MethodNotAllowed` on bucket ops,
   `404 NoSuchBucket` on object ops.
6. **The `BACKUP_S3_*` names are a public contract** — they avoid colliding with Pocket ID's
   own `S3_*` variables in a shared `.env`. Any change must be applied to `backup.sh`,
   `.env.example` and the README table in the same commit.
7. **The bucket layout is `dumps/` plus `uploads/`, at the bucket root.** Every run writes one
   timestamped archive to `dumps/pocket-id-backup-<UTC stamp>.tar.gz` (a `database.sql`
   inside), and the uploads are mirrored to `uploads/` with `s3cmd sync`, **upwards only**.
   `sync` is additive: it uploads new and changed files but does not delete remote objects by
   default (verified on s3cmd 2.4.0), so the job never removes anything. Pass
   `--delete-removed` only if an exact mirror is explicitly wanted. Nothing is ever synced
   back down by the job: restoring uploads is a manual operator step in the README runbook.
8. **Settled product decisions** (do not "improve" without an explicit request): no cron
   inside the container, no in-app retention/deletion (a bucket lifecycle rule on `dumps/`
   instead; dumps are never deleted by the job), no built-in restore subcommand, container
   runs as root, bucket must pre-exist (never auto-create), no test harness or example
   instance in the repo — `compose.yml` builds/pushes the image and nothing else.
9. **Everything in the repo is English** — identifiers, comments, docs, commit messages.

## Verify locally (rootless podman on Fedora)

Docker is not necessarily installed; `podman` + `podman-compose` are. Deliverables must stay
engine-agnostic (plain Dockerfile + compose spec). The harness below is ad-hoc shell, not a
repo file: the repo deliberately ships no S3 server and no example instance.

```bash
export CONTAINERS_REGISTRIES_CONF=/tmp/podman-registries.conf   # permissive short names
printf 'short-name-mode = "permissive"\nunqualified-search-registries = ["docker.io"]\n' > "$CONTAINERS_REGISTRIES_CONF"

cp .env.example .env
cat >> .env <<'EOF'
ENCRYPTION_KEY=change-me-32-bytes-minimum-padding
BACKUP_S3_ENDPOINT=http://127.0.0.1:7070
BACKUP_S3_BUCKET=pocket-id-backups
BACKUP_S3_ACCESS_KEY=minioadmin
BACKUP_S3_SECRET_KEY=minioadmin
BACKUP_S3_FORCE_PATH_STYLE=true
EOF
podman-compose build                                     # single service, no profile needed

# Ad-hoc S3 endpoint (VersityGW) + an initialized Pocket ID instance sharing ./data.
# VersityGW needs an existing data dir and root credentials, else it exits at once
# (`failed to init posix backend` / `root user access and secret key must be provided`).
podman network create s3test
podman run -d --name test-s3 --network s3test -p 7070:7070 -v test-s3-data:/data \
  -e ROOT_ACCESS_KEY=minioadmin -e ROOT_SECRET_KEY=minioadmin \
  versity/versitygw:latest --virtual-domain gw.test posix /data
podman run -d --name test-pocket-id -p 1411:1411 -v ./data:/app/data:z \
  -e APP_URL=http://localhost:1411 --env-file .env pocketid/pocket-id:v2.18.0
curl -fsS http://localhost:1411/ >/dev/null              # instance UI is up

# bucket, created with the image's own s3cmd (path style; host networking because the
# gateway is on the host loopback)
podman run --rm --network host --env-file .env docker.io/makos/pocket-id-backup:latest bash -c \
  '. /app/backup.sh; backup_s3args; s3cmd "${S3CMD_ARGS[@]}" mb "s3://$BACKUP_S3_BUCKET"'

# SQLite backup while the instance runs: expect exit 0, and the instance still 200 with no
# errors in its log (that is the regression check for invariant 4)
podman run --rm --network host --env-file .env -v ./data:/app/data:z docker.io/makos/pocket-id-backup:latest
# the dump landed under dumps/ and the uploads mirror is populated
podman run --rm --network host --env-file .env docker.io/makos/pocket-id-backup:latest bash -c \
  '. /app/backup.sh; backup_s3args; s3cmd "${S3CMD_ARGS[@]}" ls -r "s3://$BACKUP_S3_BUCKET/"'
# sync is additive, not a mirror: an upload removed locally stays in the bucket. To watch it
# happen, create the scratch file from inside the container (the host user cannot write to
# ./data/uploads, it belongs to the container's subuid mapping):
#   podman run --rm -v ./data:/app/data:z IMG bash -c 'echo x > /app/data/uploads/scratch.txt'
# Bad credentials: expect non-zero and no new object
podman run --rm --network host --env-file .env -e BACKUP_S3_SECRET_KEY=bad \
  -v ./data:/app/data:z docker.io/makos/pocket-id-backup:latest

# PostgreSQL path: throwaway server, then point DB_CONNECTION_STRING at it. Its dump lands in
# the same dumps/ directory as the SQLite one, so the harness uses a second bucket to keep
# them apart; the endpoint is overridden because this run joins the s3test network (the
# 127.0.0.1 of .env would be the container itself there).
podman run -d --name test-pg --network s3test -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_USER=pocketid -e POSTGRES_DB=pocketid docker.io/library/postgres:14
podman exec test-pg psql -U pocketid -d pocketid -c 'create table users (id text primary key, name text);'
podman run --rm --network s3test --env-file .env -e BACKUP_S3_ENDPOINT=http://test-s3:7070 \
  -e BACKUP_S3_BUCKET=pocket-id-backups-pg docker.io/makos/pocket-id-backup:latest bash -c \
  '. /app/backup.sh; backup_s3args; s3cmd "${S3CMD_ARGS[@]}" mb "s3://$BACKUP_S3_BUCKET"'
podman run --rm --network s3test --env-file .env -e BACKUP_S3_ENDPOINT=http://test-s3:7070 \
  -e BACKUP_S3_BUCKET=pocket-id-backups-pg \
  -e DB_CONNECTION_STRING=postgres://pocketid:secret@test-pg:5432/pocketid \
  -v ./data:/app/data:z docker.io/makos/pocket-id-backup:latest

# Virtual-host addressing (the UpCloud mode): the bucket hostname must resolve and the
# gateway must know its base domain, otherwise every bucket op fails with 405
IP=$(podman inspect test-s3 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
podman run --rm --network s3test --add-host gw.test:"$IP" --add-host pocket-id-backups.gw.test:"$IP" \
  --env-file .env -e BACKUP_S3_ENDPOINT=http://gw.test:7070 -e BACKUP_S3_FORCE_PATH_STYLE= \
  -v ./data:/app/data:z docker.io/makos/pocket-id-backup:latest

# restore: README runbook steps 3-5 (with --network host and the harness .env), then bring
# the instance back and confirm it answers 200
podman rm -f test-pocket-id                              # clean stop releases the DB lease
podman rm -f test-s3 test-pg
podman network rm s3test
podman volume rm test-s3-data
podman unshare rm -rf data                               # ./data is owned by a subuid mapping
```

`APP_URL` is not in `.env.example` because the dump does not read it — only a running instance
needs it. `ENCRYPTION_KEY` is not there either, but Pocket ID refuses to start without it, so
the harness appends one.

`bash -n backup.sh` is the cheap syntax check; `shellcheck` may not be installed.

## Gotchas (symptom → cause → fix)

| Symptom | Cause | Fix |
|---|---|---|
| "it appears that there's already one instance of Pocket ID running" right after a restore | the archive was taken while an instance was running, so it still contains that instance's host registration | clear it before the first start: `sqlite3 db "PRAGMA foreign_keys=ON; DELETE FROM francis_hosts;"` / `psql "$DB_CONNECTION_STRING" -c "DELETE FROM francis_hosts;"` |
| `unrecognized configuration parameter "transaction_timeout"` while restoring a PostgreSQL dump | `pg_dump` is newer than the server (Alpine ships the newest client) | harmless, `psql` reports it and continues |
| `unable to open database file (14)`, AVC `denied { lock }`, "already one instance running" | private SELinux label on the shared bind mount | use `:z` on every container that mounts the Pocket ID data dir |
| an upload deleted in Pocket ID stays in the bucket | `s3cmd sync` does not delete remote objects by default (it only uploads new and changed files) | intended: the bucket keeps what was ever uploaded. Add `--delete-removed` in `backup.sh` for an exact mirror |
| `405 MethodNotAllowed` on bucket ops, `404 NoSuchBucket` on object ops | virtual-host requests against an endpoint that only does path style (or a gateway without `--virtual-domain`) | set `BACKUP_S3_FORCE_PATH_STYLE=true`, or enable virtual-host addressing on the endpoint |
| `Configuration file not available` | `BACKUP_S3_ACCESS_KEY`/`BACKUP_S3_SECRET_KEY` empty, so s3cmd looked for `~/.s3cfg` | pass the credentials (the job validates them, this only happens with a broken env) |
| `BACKUP_S3_BUCKET is required` | no runtime env was passed | pass `--env-file .env` to `docker run` |
| `root user access and secret key must be provided`, `failed to init posix backend` | VersityGW started without `ROOT_ACCESS_KEY`/`ROOT_SECRET_KEY` or without an existing data dir | pass both credentials and mount a volume at the posix path |
| `short-name resolution enforced but cannot prompt without a TTY` | podman short names | permissive `registries.conf` (above) or fully qualified image names |
| `minio/minio: … access denied` | MinIO community images are no longer published | use VersityGW as the test S3 endpoint; do not re-add MinIO |
