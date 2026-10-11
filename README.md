# pocket-id-backup

A one-shot Docker container that dumps a [Pocket ID](https://github.com/pocket-id/pocket-id)
database and mirrors its uploads to an S3 bucket.

There is no daemon and no cron inside the container: it runs, uploads one dump, syncs the
uploads upwards and exits. Scheduling is external (host cron, systemd timer, CI). Nothing is
ever deleted by this application — **retention is managed by a lifecycle/TTL rule on the
`dumps/` prefix** — and nothing is ever synced back down: restoring is a manual operator step.

The container is a one-shot command, not a service, so it is started with `docker run`.
`compose.yml` holds a single service whose only purpose is building and pushing the image.

## How it works

1. `backup.sh` writes a database dump: `sqlite3 .dump` for SQLite, `pg_dump` for PostgreSQL.
   Both take a consistent read snapshot, so they are safe while the live instance keeps
   running. Neither runs migrations — the dump carries the schema exactly as it is, so
   this job can never touch the live database (unlike `pocket-id export`).
2. The dump is packed into `pocket-id-backup-YYYYMMDD-HHMMSSZ.tar.gz` (containing
   `database.sql`) and uploaded to `dumps/`.
3. The uploads directory (`/app/data/uploads`, filesystem file backend) is mirrored to
   `uploads/` with `s3cmd sync` — one way only, up. The mirror is additive: objects already in
   the bucket are never deleted (pass `--delete-removed` in `backup.sh` if you want an exact
   mirror instead).
4. s3cmd drives every step. Endpoint, credentials and addressing are passed as command-line
   arguments — no s3cmd config file is used or written.

Bucket layout:

```
s3://<bucket>/dumps/pocket-id-backup-YYYYMMDD-HHMMSSZ.tar.gz   one per run
s3://<bucket>/uploads/…                                       mirror of /app/data/uploads
```

The image is Alpine plus `bash`, `sqlite`, `postgresql-client` and `s3cmd`. It does not embed
Pocket ID itself.

## Configuration

The container reads Pocket ID's own `DB_CONNECTION_STRING` plus the `BACKUP_S3_*` variables
below; use the same `env_file` as your Pocket ID service.

`DB_CONNECTION_STRING` selects the dump: a `postgres://…` URI runs `pg_dump`, anything else is
the path of the SQLite file (default `data/pocket-id.db`, relative to Pocket ID's working
directory `/app`). Mount the directory holding it at `/app/data`.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `BACKUP_S3_BUCKET` | yes | — | Target bucket. Must already exist; the job never creates it. |
| `BACKUP_S3_ACCESS_KEY` | yes | — | Access key (passed to s3cmd on the command line). |
| `BACKUP_S3_SECRET_KEY` | yes | — | Secret for the access key above. |
| `BACKUP_S3_ENDPOINT` | no | `s3.amazonaws.com` | S3 endpoint, with or without scheme: `https://<instance-id>.upcloudobjects.com`, `http://minio:9000`. Unset = AWS. |
| `BACKUP_S3_REGION` | no | — | Region used for signing. Leave unset for UpCloud; unset also means s3cmd's own default. |
| `BACKUP_S3_FORCE_PATH_STYLE` | no | unset | `true` = path-style addressing (`host/bucket/key`, MinIO). Unset = virtual-host style (`bucket.host`, UpCloud, AWS). |

## Build

```bash
cp .env.example .env
docker compose build      # tags docker.io/makos/pocket-id-backup (see image: in compose.yml)
docker compose push
```

Without compose:

```bash
docker build -t docker.io/makos/pocket-id-backup:latest .
```

## Running a backup

```bash
docker run --rm --env-file .env -v /srv/pocket-id/data:/app/data:z docker.io/makos/pocket-id-backup:latest
```

- `-v …:/app/data` must point at the directory holding the SQLite file and `uploads/`
  (the filesystem file backend). A PostgreSQL + S3-file-backend deployment can drop the mount.
- The bind-mount label is `:z` (shared SELinux relabel), **not** `:Z`. Your live Pocket ID
  instance mounts the same directory; a private `:Z` label revokes the instance's access to
  its own database (SELinux denies, and Pocket ID then loses its database lock).
- On non-SELinux hosts `:z` is accepted and ignored; you can also write it as two flags
  (`-v /srv/pocket-id/data:/app/data:rw`).

Exit code `0` means the dump was uploaded and the uploads were synced. Any validation, dump,
sync or upload failure exits non-zero (s3cmd errors are printed verbatim). Log lines are plain
text:

```
[backup] dumping /app/data/pocket-id.db to /tmp/pocket-id-backup-20261011-160958Z/database.sql
[backup] uploading 9142 bytes to s3://pocket-id-backups/dumps/pocket-id-backup-20261011-160958Z.tar.gz
upload: '/tmp/pocket-id-backup-20261011-160958Z.tar.gz' -> 's3://pocket-id-backups/dumps/pocket-id-backup-20261011-160958Z.tar.gz' (9142 bytes in 0.0 seconds, 6.97 MB/s) [1 of 1]
[backup] done: s3://pocket-id-backups/dumps/pocket-id-backup-20261011-160958Z.tar.gz (9142 bytes)
[backup] syncing /app/data/uploads to s3://pocket-id-backups/uploads/
[backup] done: s3://pocket-id-backups/uploads/
```

The uploads sync only prints transfers for new or changed files; a run where nothing changed
logs just the two `[backup]` lines above. s3cmd's `Owner username not known` warnings are
normal on a rootless setup (the files belong to the instance's uid mapping).

## Scheduling

Host crontab (daily at 03:00):

```cron
0 3 * * * cd /opt/pocket-id-backup && docker run --rm --env-file .env \
  -v /srv/pocket-id/data:/app/data:z docker.io/makos/pocket-id-backup:latest >> /var/log/pocket-id-backup.log 2>&1
```

systemd (better logging, `OnFailure=` hooks):

```ini
# /etc/systemd/system/pocket-id-backup.service
[Unit]
Description=Back up Pocket ID to S3
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=/opt/pocket-id-backup
ExecStart=/usr/bin/docker run --rm --env-file .env -v /srv/pocket-id/data:/app/data:z docker.io/makos/pocket-id-backup:latest
```

```ini
# /etc/systemd/system/pocket-id-backup.timer
[Unit]
Description=Daily Pocket ID backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now pocket-id-backup.timer
```

## Restore runbook (manual)

Restoring is destructive: the import replaces the live data. Stop Pocket ID first, and take a
fresh copy of the data directory if you want a rollback path.

1. List the dumps in the bucket (`. /app/backup.sh` loads the helpers without running a
   backup):

   ```bash
   docker run --rm --env-file .env docker.io/makos/pocket-id-backup:latest bash -c '
   . /app/backup.sh
   backup_s3args
   s3cmd "${S3CMD_ARGS[@]}" ls "s3://${BACKUP_S3_BUCKET}/dumps/"
   '
   ```

2. Stop the instance (whatever runs it):

   ```bash
   docker compose stop pocket-id     # or: systemctl stop pocket-id
   ```

3. Download the newest dump and import it:

   ```bash
   docker run --rm --env-file .env -v /srv/pocket-id/data:/app/data:z \
     docker.io/makos/pocket-id-backup:latest bash -c '
   set -euo pipefail
   . /app/backup.sh
   backup_s3args
   SRC="s3://${BACKUP_S3_BUCKET}/dumps/"
   LATEST=$(s3cmd "${S3CMD_ARGS[@]}" ls "$SRC" | grep -o "s3://[^ ]*\.tar\.gz" | sort | tail -1)
   echo "restoring ${LATEST}"
   rm -rf /tmp/restore && mkdir -p /tmp/restore
   s3cmd "${S3CMD_ARGS[@]}" get "$LATEST" /tmp/restore/backup.tar.gz
   tar xzf /tmp/restore/backup.tar.gz -C /tmp/restore

   case "${DB_CONNECTION_STRING:-data/pocket-id.db}" in
   postgres://* | postgresql://*)
     # the dump contains no DROP: empty the database first
     psql "$DB_CONNECTION_STRING" -c "drop schema public cascade; create schema public;"
     psql "$DB_CONNECTION_STRING" -f /tmp/restore/database.sql
     ;;
   *)
     # keep the old SQLite files for rollback, then import into a fresh file
     mkdir -p /app/data/restore-old
     mv /app/data/pocket-id.db /app/data/pocket-id.db-wal /app/data/pocket-id.db-shm \
       /app/data/restore-old/ 2>/dev/null || true
     sqlite3 /app/data/pocket-id.db < /tmp/restore/database.sql
     ;;
   esac
   '
   ```

   The image's `CMD` is replaced by the `bash -c` argument, so no `--entrypoint` override is
   needed. Use `bash`, not `sh`: the helpers in `backup.sh` use arrays, and the image's
   `/bin/sh` is busybox ash.

4. Sync the uploads back down. The job never does this by itself — it is an explicit operator
   step:

   ```bash
   docker run --rm --env-file .env -v /srv/pocket-id/data:/app/data:z \
     docker.io/makos/pocket-id-backup:latest bash -c '
   set -euo pipefail
   . /app/backup.sh
   backup_s3args
   s3cmd "${S3CMD_ARGS[@]}" --no-progress sync \
     "s3://${BACKUP_S3_BUCKET}/uploads/" /app/data/uploads/
   '
   ```

   `sync` copies new and changed files down; it does not delete local files by default. Add
   `--delete-removed` if you want the local directory to be an exact mirror of the bucket.

5. Clear the previous instance's registration. The dump was taken while an instance was
   running, so it contains that instance's host registration — Pocket ID refuses to start
   when it finds one (*"it appears that there's already one instance of Pocket ID running"*):

   ```bash
   # SQLite
   sqlite3 /srv/pocket-id/data/pocket-id.db "PRAGMA foreign_keys=ON; DELETE FROM francis_hosts;"
   # PostgreSQL
   psql "$DB_CONNECTION_STRING" -c "DELETE FROM francis_hosts;"
   ```

6. Start the instance again:

   ```bash
   docker compose start pocket-id     # or: systemctl start pocket-id
   ```

   Pocket ID's entrypoint re-chowns `/app/data`, so files created by this container (which
   runs as root) do not break the service.

7. Once the restored instance is verified, remove the rollback copy:
   `rm -rf /srv/pocket-id/data/restore-old`.

Notes:

- The dump is schema-complete for the version that produced it. Restoring it into a **newer**
  Pocket ID is fine (migrations run on instance start); restoring into an **older** version is
  not supported.
- If `pg_dump` is newer than the server, the dump can contain `SET` lines the server rejects
  (e.g. `unrecognized configuration parameter "transaction_timeout"`). `psql` prints the error
  and continues; the restore still completes.

## Security notes

- The dumps contain IdP secrets (user data, token signing keys) and the uploads mirror contains
  user profile images. Restrict bucket access: private bucket, least-privilege credentials,
  TLS-only endpoint.
- The container runs as **root** (no PUID/PGID drop). It only needs the data volume and
  network access to the S3 endpoint. Credentials travel as process arguments, not in a file.

## S3-compatible providers

### UpCloud Object Storage

```bash
BACKUP_S3_ENDPOINT=https://<instance-id>.upcloudobjects.com
BACKUP_S3_ACCESS_KEY=<access key>
BACKUP_S3_SECRET_KEY=<secret key>
BACKUP_S3_BUCKET=<bucket>
```

The endpoint is your Object Storage instance's hostname (not a region URL), and buckets are
addressed as `bucket.<instance-id>.upcloudobjects.com` — so leave `BACKUP_S3_FORCE_PATH_STYLE`
and `BACKUP_S3_REGION` unset. Credentials are the S3 access keys of that instance. The bucket
must already exist.

### Other providers

| Provider | `BACKUP_S3_ENDPOINT` | Notes |
|---|---|---|
| AWS S3 | leave unset | set `BACKUP_S3_REGION` to the bucket's region |
| MinIO, other path-style endpoints | `http://minio:9000` | `BACKUP_S3_FORCE_PATH_STYLE=true` |
| Other S3-compatible providers | provider endpoint | set `BACKUP_S3_REGION` if the provider needs a signing region; add `BACKUP_S3_FORCE_PATH_STYLE=true` only if the endpoint has no virtual-host addressing |

Retention: configure a lifecycle expiration rule on the `dumps/` prefix (AWS S3 Lifecycle,
MinIO ILM, R2/B2 equivalents). This application never deletes anything — the uploads are only
ever added to, so a lifecycle rule on `uploads/` would be your own call.
