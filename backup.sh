#!/usr/bin/env bash
#
# One-shot Pocket ID backup.
#
# 1. A database dump is written with `sqlite3 .dump` (SQLite) or `pg_dump`
#    (PostgreSQL). Both read a consistent snapshot, so they are safe while the
#    instance keeps running, and neither runs migrations -- unlike
#    `pocket-id export`, which migrates the live database.
# 2. The dump is packed into a timestamped tar.gz and uploaded to dumps/.
# 3. The uploads directory is mirrored to uploads/ with `s3cmd sync`,
#    one way only (up): the job never syncs anything back down. Restoring the
#    uploads is a manual down-sync, see the runbook in README.md.
# 4. Every s3cmd setting is passed as a command-line argument: no config file
#    is used or written.
#
# The container exits after the upload; scheduling is external (host cron,
# systemd timer, CI). Retention is bucket-side (lifecycle / TTL rules) --
# this script never deletes dumps; the uploads mirror is kept exact by `sync`.
#
# This file is sourced by the restore commands in README.md, so the helpers
# below are shared with them (main() only runs when the file is executed).
set -euo pipefail

# --- Helpers ----------------------------------------------------------------

# backup_s3args
#   Fill the global S3CMD_ARGS array from the BACKUP_S3_* variables.
#   Addressing: virtual-host style by default (bucket.<host>, UpCloud, AWS);
#   BACKUP_S3_FORCE_PATH_STYLE=true switches to path style (MinIO, ...).
backup_s3args() {
	local endpoint="${BACKUP_S3_ENDPOINT:-s3.amazonaws.com}"
	local host host_bucket

	case "$endpoint" in
	https://*) host="${endpoint#https://}" ;;
	http://*) host="${endpoint#http://}" ;;
	*) host="$endpoint" ;;
	esac
	host="${host%/}"

	if [ "${BACKUP_S3_FORCE_PATH_STYLE:-}" = "true" ]; then
		host_bucket="$host"
	else
		host_bucket="%(bucket)s.${host}"
	fi

	S3CMD_ARGS=(
		--access_key="${BACKUP_S3_ACCESS_KEY:-}"
		--secret_key="${BACKUP_S3_SECRET_KEY:-}"
		--host="$host"
		--host-bucket="$host_bucket"
	)
	case "$endpoint" in
	http://*) S3CMD_ARGS+=(--no-ssl) ;;
	esac
	if [ -n "${BACKUP_S3_REGION:-}" ]; then
		S3CMD_ARGS+=(--region="$BACKUP_S3_REGION")
	fi
}

# Scratch paths, assigned by main() and removed by the EXIT trap (they must stay
# global: the trap runs after main() returns, when its locals are gone).
stage=""
out=""
trap 'rm -rf "$stage" "$out"' EXIT

# --- Backup -----------------------------------------------------------------

main() {
	local db="${DB_CONNECTION_STRING:-data/pocket-id.db}"
	local data_dir uploads_dir ts key size dest uploads_dest

	: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET is required (target S3 bucket, must already exist)}"
	# s3cmd always gets the credentials as arguments; without them it would fall
	# back to a config file, which this job deliberately never uses.
	: "${BACKUP_S3_ACCESS_KEY:?BACKUP_S3_ACCESS_KEY is required}"
	: "${BACKUP_S3_SECRET_KEY:?BACKUP_S3_SECRET_KEY is required}"

	# --- Where the database and the uploads live ----------------------------
	# DB_CONNECTION_STRING is Pocket ID's own variable: a postgres:// URI or a
	# path to the SQLite file (relative paths resolve against Pocket ID's
	# working directory, /app). Uploads always live in the mounted data dir.
	case "$db" in
	postgres://* | postgresql://*)
		data_dir="/app/data"
		;;
	/*)
		data_dir="$(dirname "$db")"
		;;
	*)
		db="/app/${db}"
		data_dir="$(dirname "$db")"
		;;
	esac
	uploads_dir="${data_dir}/uploads"

	ts="$(date -u +%Y%m%d-%H%M%SZ)"
	stage="/tmp/pocket-id-backup-${ts}"
	out="/tmp/pocket-id-backup-${ts}.tar.gz"
	key="pocket-id-backup-${ts}.tar.gz"

	mkdir -p "$stage"

	# --- Dump the database --------------------------------------------------
	case "$db" in
	postgres://* | postgresql://*)
		echo "[backup] dumping PostgreSQL database to ${stage}/database.sql"
		pg_dump --no-owner --no-acl "$db" >"${stage}/database.sql"
		;;
	*)
		if [ ! -f "$db" ]; then
			echo "[backup] error: database file not found: ${db}" >&2
			exit 1
		fi
		echo "[backup] dumping ${db} to ${stage}/database.sql"
		sqlite3 "$db" .dump >"${stage}/database.sql"
		;;
	esac

	# --- Pack the dump ------------------------------------------------------
	tar -czf "$out" -C "$stage" .
	size="$(stat -c %s "$out")"

	# --- Upload the dump ----------------------------------------------------
	dest="s3://${BACKUP_S3_BUCKET}/dumps/${key}"
	echo "[backup] uploading ${size} bytes to ${dest}"
	backup_s3args
	s3cmd "${S3CMD_ARGS[@]}" --no-progress put "$out" "$dest"
	echo "[backup] done: ${dest} (${size} bytes)"

	# --- Mirror the uploads, upwards only -----------------------------------
	# `sync` uploads new and changed files. It does not delete remote objects
	# by default (verified on s3cmd 2.4.0), so nothing is ever removed here;
	# pass --delete-removed for an exact mirror instead. The reverse direction
	# never happens -- restoring uploads is a manual down-sync (README runbook).
	if [ -d "$uploads_dir" ]; then
		uploads_dest="s3://${BACKUP_S3_BUCKET}/uploads/"
		echo "[backup] syncing ${uploads_dir} to ${uploads_dest}"
		s3cmd "${S3CMD_ARGS[@]}" --no-progress sync "${uploads_dir%/}/" "$uploads_dest"
		echo "[backup] done: ${uploads_dest}"
	fi
}

# Run the backup only when executed, not when sourced for the helpers above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
