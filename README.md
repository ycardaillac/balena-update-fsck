# balena-update-fsck

### What this repo contains

- `balena_os_update_and_fsck.sh`: simple bash script to iterate over a list of balenaOS versions, trigger host OS updates via `balena device os-update`, wait until the target version is visible in `/etc/os-release`, then run `fsck.ext4 -f -n` on `/dev/mmcblk0p2` and `/dev/mmcblk0p3` and save logs locally.

### Quick start

Assumptions:
- You have `balena` CLI installed and authenticated (`balena login`).
- Your user has permission to run `balena device os-update` and `balena device ssh` for the target device.

Example:

```bash
DEVICE_UUID=5de5e719a92ba905a52a405bef58d04d \
LOG_DIR=./logs \
./balena_os_update_and_fsck.sh
```

Outputs:
- `./logs/script_<UTC_TIMESTAMP>.log`: high-level progress log (update transitions + wait loops + fsck errors)
- `./logs/mmcblk0p2_<os_version>.log`: fsck output + exit code
- `./logs/mmcblk0p3_<os_version>.log`: fsck output + exit code

### Behavior notes / knobs

- Update verification: after triggering an update, the script waits at least `WAIT_TIME` seconds (min 180s) and then polls every `RETRY_WAIT` seconds until `/etc/os-release` contains the target version (up to `MAX_TRIES` times).
- Transient “HTML error page” from balena API: `balena device os-update` is retried when the output contains `<!DOCTYPE html>` / `<html>`, waiting `UPDATE_RETRY_WAIT` seconds between retries, up to `UPDATE_MAX_TRIES` tries.

Environment variables:
- `DEVICE_UUID`: target device UUID (required)
- `LOG_DIR`: local directory for logs (default `./logs`)
- `WAIT_TIME`: initial wait before checking version (default `180`, minimum `180`)
- `RETRY_WAIT`: seconds between `/etc/os-release` checks (default `15`)
- `MAX_TRIES`: number of `/etc/os-release` checks after the initial wait (default `10`)
- `UPDATE_RETRY_WAIT`: seconds between os-update retries on HTML error (default `10`)
- `UPDATE_MAX_TRIES`: number of os-update retries on HTML error (default `5`)

