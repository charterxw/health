# Raspberry Pi operations

These six Python scripts were copied from the running Pi's `/home/admin/health/ops`
on 2026-11-18. They retain the existing host paths and behavior. They are not run
by importing the app, building an image, or checking the repository.

| File | Purpose / prerequisites |
| --- | --- |
| `probe_container.py` | Run inside `fitness-api`; checks readiness and authenticates against the operational endpoint. |
| `monitor.py` | Host timer entry point; uses Docker, probe, backup receipts and `alert.py`. |
| `alert.py` | Sends operational Telegram alerts using private files under `secrets/`. |
| `install_host.py` | Root-only installer; modifies systemd, SSH, fail2ban and boot settings. Requires the existing `server-backup` installation and profile. |
| `rotate_password.py` | Interactive production password rotation with restart, checks and rollback. |
| `full_restore_check.py` | Downloads/decrypts private backups and boots isolated restore containers; requires existing backup receipt/profile, rclone, age, zstd and Docker images. |

`compose.standalone.yml` is a new portable source-build configuration. It keeps the
backend private, maps the UI to localhost:9999, and omits the unrelated cloud-reel
media bridge. See [the recovery guide](../docs/RESTORE.md) before using it.

The generic host `server-backup` executable, encrypted remote storage, encryption
identity, Cloudflare tunnel and their credentials are managed outside this app
repository. The current host backup's `backup-runtime` archive is the recovery
source for that infrastructure. App source can be built without those services.
