# docker-ckan-backup

Docker image to backup and restore CKAN instances.

The image bundles the Postgres client tools (`pg_dump`/`pg_restore`) together
with two scripts, `create` (aliased as `backup`) and `restore`, that back up
and restore everything needed to fully reproduce a CKAN instance:

- the CKAN database
- the DataStore database
- the CKAN file storage (`resources`, `storage`, `webassets` under
  `/var/lib/ckan`, whichever of these exist)

It is built to run alongside a CKAN stack such as the one in
[docker-ckan](https://github.com/TIBHannover/docker-ckan), sharing its
Postgres and CKAN storage volume, and is also used as the backup/restore tool
for other CKAN deployments built on top of that stack.

## How it works

### Backup (`create` / `backup`)

1. Checks free space on the filesystem holding `BACKUP_FILE` and aborts if
   it is below `CKAN_BACKUP_MIN_FREE_PERCENT`, since `create` stages the
   database dumps and overwrites `BACKUP_FILE` in place on that same
   filesystem, and running out of space mid-write would corrupt the last
   good backup.
2. Compares the installed `pg_dump` client's major version against the
   Postgres server's major version and aborts if the client is older, since
   an older client can silently produce dumps a newer `pg_restore` misreads.
3. Dumps the CKAN database and the DataStore database with
   `pg_dump --format=custom`.
4. Records the backup tool version and the Postgres server version in a
   `ckan-backup.version` file for provenance.
5. Packs the two dumps and the version file into a tar archive, then appends
   `resources`, `storage`, and `webassets` from `$CKAN_STORAGE_PATH` if
   present.

### Restore (`restore`)

1. Extracts the archive and validates that both database dumps are present.
2. Compares the installed `pg_restore` client's major version against the
   Postgres server's major version and aborts if the client is older.
3. Restores the CKAN database and the DataStore database with
   `pg_restore --clean --if-exists`.
4. Checks the archive for at least one of `resources`, `storage`,
   `webassets` before touching `$CKAN_STORAGE_PATH`, and aborts if none are
   present (e.g. a database-only or damaged archive) instead of wiping the
   current files. Otherwise wipes `$CKAN_STORAGE_PATH` and re-extracts
   whichever of the three directories are present (a missing individual
   directory only produces a warning).
5. Optionally `chown`s the restored files if `RESTORE_OWNER` is set.

Note: restoring does not rebuild the Solr search index. That has to be
triggered separately from the CKAN container after a restore (e.g. via
`ckan search-index rebuild`).

## Environment variables

| Variable            | Required | Description                                                             |
| ------------------- | -------- | ------------------------------------------------------------------------ |
| `POSTGRES_HOST`     | yes      | Hostname of the Postgres server                                          |
| `CKAN_DB_USER`      | yes      | Postgres user used for both databases                                    |
| `CKAN_DB_PASSWORD`  | yes      | Password for `CKAN_DB_USER`                                              |
| `CKAN_DB`           | yes      | Name of the CKAN database                                                |
| `DATASTORE_DB`      | yes      | Name of the DataStore database                                           |
| `POSTGRES_PORT`     | no       | Port of the Postgres server (default `5432`)                             |
| `BACKUP_FILE`       | no       | Path to the backup archive (default `/backup/ckan-backup.tar`)           |
| `CKAN_STORAGE_PATH` | no       | Path containing `resources`/`storage`/`webassets` (default `/var/lib/ckan`) |
| `RESTORE_OWNER`     | no       | `user:group` to `chown` the restored files to (e.g. `ckan:ckan`)         |
| `CKAN_BACKUP_MIN_FREE_PERCENT` | no | Minimum free space (%) required on the `BACKUP_FILE` filesystem before `create` runs (default `20`) |

## Usage

The image expects two volumes: one for the backup archive and one matching
the CKAN storage volume (mounted at `/var/lib/ckan`), plus network access to
the Postgres server.

### As a compose service

Add it alongside your CKAN stack, sharing the Postgres network and the CKAN
storage volume:

```yaml
services:
  backup:
    image: ghcr.io/tibhannover/ckan-backup:latest
    networks:
      - dbnet
    volumes:
      - ./backup:/backup
      - ckan_storage:/var/lib/ckan
    env_file:
      - .env
    profiles:
      - no-up # don't start on 'docker-compose up'
```

Then run backup or restore as one-off commands:

```sh
# Create a backup
docker compose run --rm backup backup

# Restore from a backup
docker compose run --rm backup restore
```

### Standalone

```sh
docker run --rm \
  --network <network-with-access-to-postgres> \
  -e POSTGRES_HOST=db \
  -e CKAN_DB_USER=ckandbuser \
  -e CKAN_DB_PASSWORD=ckandbpassword \
  -e CKAN_DB=ckandb \
  -e DATASTORE_DB=datastore \
  -v $(pwd)/backup:/backup \
  -v ckan_storage:/var/lib/ckan \
  ghcr.io/tibhannover/ckan-backup:latest backup
```

Replace `backup` with `restore` to restore from `$BACKUP_FILE`.

### Backing up a manually installed CKAN

The image has no hard dependency on CKAN itself running in Docker. It only
needs network access to the Postgres server and a mount pointing at the
CKAN storage directory, so it can also back up a CKAN instance installed
directly on a host (e.g. via a native package or a Python virtualenv):

```sh
docker run --rm \
  --network host \
  -e POSTGRES_HOST=localhost \
  -e POSTGRES_PORT=5432 \
  -e CKAN_DB_USER=ckandbuser \
  -e CKAN_DB_PASSWORD=ckandbpassword \
  -e CKAN_DB=ckandb \
  -e DATASTORE_DB=datastore \
  -e CKAN_STORAGE_PATH=/var/lib/ckan \
  -v /path/to/backup:/backup \
  -v /path/to/your/ckan/storage:/var/lib/ckan \
  ghcr.io/tibhannover/ckan-backup:latest backup
```

Notes for this setup:

- Bind-mount whatever your CKAN's `ckan.storage_path` config points to onto
  `/var/lib/ckan` (or set `CKAN_STORAGE_PATH` to mount it somewhere else
  inside the container). The scripts look for `resources`, `storage`, and
  `webassets` directly under that path, so the mount must point at the
  storage root, not at one of those subdirectories.
- `--network host` (or any network from which the Postgres server is
  reachable) replaces the Docker network used in the compose setup.
  `POSTGRES_PORT` lets you point at a non-default Postgres port.
- The bundled Postgres client version (see [Compatibility](#compatibility))
  still has to be at least as new as the target Postgres server.
- As with the Docker-based setup, this only backs up the databases and file
  storage — CKAN's own configuration and any custom extensions are not
  covered, see [Known limitations](#known-limitations).

## Compatibility

The image is built on a specific major version of the Postgres client tools
(currently Postgres 16, see the `Dockerfile`). Both `create` and `restore`
refuse to run if the bundled client is older than the target Postgres
server, since that combination can silently corrupt or misread dumps across
a major version boundary. When upgrading the Postgres server used by your
CKAN stack, make sure to use a `docker-ckan-backup` image built on a client
version that is at least as new.

## Known limitations

This image is deliberately minimal and runs non-interactively (no prompts,
no "are you sure?" confirmations), which shapes what it can and can't do:

- **No retention or off-host copy.** `create` always overwrites
  `$BACKUP_FILE` in place. Rotating backups, keeping history, copying
  archives off-host, and verifying their integrity (checksums) are the
  responsibility of whatever schedules and stores the backups, not this
  image.
- **No built-in multi-instance isolation.** The image has no concept of
  "instances" — it always writes to `$BACKUP_FILE` and reads/writes
  `$CKAN_STORAGE_PATH` as given. When running multiple CKAN instances on the
  same host, giving each instance its own `BACKUP_FILE`/backup mount and
  `CKAN_STORAGE_PATH` is entirely up to the deployment configuration; this
  is by design, not an oversight, since it keeps the image simple and lets
  each deployment decide its own directory layout.
- **Not a single consistent snapshot.** The CKAN database, the DataStore
  database, and the file storage are backed up sequentially while CKAN can
  keep running, so the archive is not guaranteed to be one atomic
  point-in-time snapshot. For a fully consistent backup, stop CKAN (or put
  it into maintenance mode) before running `backup`.
- **Configuration and secrets are out of scope.** The archive only contains
  databases and CKAN file storage. Deployment configuration
  (`.env`/Compose files, the CKAN image or extension sources, TLS
  certificates, and other deployment-specific configuration) must be backed
  up separately.
- **No automated backup/restore tests.** There is currently no CI step that
  exercises `create`/`restore` end to end; changes to either script should
  be tested manually against a disposable CKAN stack before release.

## Releasing

Images are published to `ghcr.io/tibhannover/ckan-backup` by the
`.github/workflows/publish.yml` workflow whenever a GitHub release is
created, and are tagged and multi-arch built (`linux/amd64`, `linux/arm64`)
via that workflow.
