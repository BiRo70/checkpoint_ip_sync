# Check Point Object Subnets Group Sync

Keeps the `GRP_Cloudflare_Subnets` network group on your Check Point
Management Server in sync with Cloudflare's published IPv4 ranges.

It can be modified to support other IP lists

---

## Files

| File | Purpose |
|---|---|
| `sync_cloudflare_to_checkpoint.py` | Main sync script |
| `install_cron.sh` | Interactive installer – sets up credentials, cron, and a wrapper |
| `README.md` | This file |

---

## Requirements

| Requirement | Notes |
|---|---|
| Python 3.8+ | Pre-installed on Gaia R80.40+; use `python3 --version` to verify |
| `requests` library | `pip3 install requests` if missing |
| Check Point R80.10+ Management | Earlier versions have partial API support |
| An API admin account | Create via SmartConsole → Manage & Settings → Permissions → API admin |
| API enabled on the Management Server | SmartConsole → Manage & Settings → API |

---

## Quick start

### 1. Copy files to the Management Server

```bash
scp sync_cloudflare_to_checkpoint.py install_cron.sh admin@<mgmt-ip>:/home/admin/cf_sync/
```

### 2. Run the installer (as root)

```bash
ssh admin@<mgmt-ip>
sudo -i
cd /home/admin/cf_sync
chmod +x install_cron.sh
./install_cron.sh
```

The installer will prompt for:

- Management Server IP / hostname
- API port (default 443)
- Admin username & password
- Domain (only for Multi-Domain Server environments)
- Policy package name (default `Standard`)
- Network group name (default `GRP_Cloudflare_Subnets`)
- Cron schedule (default `0 3 * * *` = 03:00 daily)

Credentials are written to `/etc/cp_cloudflare_sync/env` with permissions
`600` (root-readable only).

---

## Environment variables

All settings can be overridden via environment variables without re-running
the installer.  Edit `/etc/cp_cloudflare_sync/env` directly.

| Variable | Default | Description |
|---|---|---|
| `CP_HOST` | *(required)* | Management Server IP or hostname |
| `CP_PORT` | `443` | Management API HTTPS port |
| `CP_USER` | *(required)* | API admin username |
| `CP_PASSWORD` | *(required)* | API admin password |
| `CP_DOMAIN` | *(blank)* | Domain name (MDS only) |
| `CP_POLICY` | `Standard` | Policy package to install |
| `CP_GROUP` | `GRP_Cloudflare_Subnets` | Network group name |
| `CP_OBJ_PREFIX` | `NET_Cloudflare_` | Prefix for auto-created network objects |
| `CF_API_URL` | `https://api.cloudflare.com/client/v4/ips` | Cloudflare IP API |
| `LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARNING` / `ERROR` |
| `DRY_RUN` | `0` | Set to `1` to simulate without making changes |

---

## Manual run

```bash
# Normal run
bash /home/admin/cf_sync/run_sync.sh

# Dry run (no changes written)
DRY_RUN=1 bash /home/admin/cf_sync/run_sync.sh

# Debug verbosity
LOG_LEVEL=DEBUG bash /home/admin/cf_sync/run_sync.sh
```

---

## What the script does

1. **Fetches** Cloudflare IPv4 CIDRs from the public `/v1/ips` endpoint.
2. **Logs in** to the Management API and opens a read-write session.
3. **Creates** `GRP_Cloudflare_Subnets` if it does not exist.
4. **Creates** a `NET_Cloudflare_<cidr>` network object for each CIDR not
   already present in the group.
5. **Sets** the group membership to exactly the current Cloudflare CIDR list.
6. **Deletes** stale network objects that were removed from the group — only
   if they are not referenced anywhere else (safe deletion via `where-used`).
7. **Publishes** the session if any change was made.
8. **Installs** the `Standard` policy only when changes occurred.
9. **Logs out** cleanly on both success and failure paths.

If a fatal error occurs before publishing, the session is **discarded** so
the database is left in a clean state.

---

## Object naming convention

Each Cloudflare CIDR becomes a network object named:

```
NET_Cloudflare_<network>_<prefix>
```

Examples:

| CIDR | Object name |
|---|---|
| `103.21.244.0/22` | `NET_Cloudflare_103.21.244.0_22` |
| `198.41.128.0/17` | `NET_Cloudflare_198.41.128.0_17` |

The prefix is configurable via `CP_OBJ_PREFIX`.

---

## Troubleshooting

### API login fails (401 / auth error)

- Confirm the user has API admin permissions in SmartConsole.
- Confirm the Management API is enabled:
  **SmartConsole → Manage & Settings → Blades → Management API → All IP addresses**.
- For MDS: confirm `CP_DOMAIN` is set to the correct domain name.

### Policy install fails but changes are published

The changes ARE committed to the database; only the enforcement push failed.
Install the policy manually from SmartConsole or re-run the script (it will
detect no object changes but you can force an install by temporarily setting
the group comment and running again).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (with or without changes) |
| `1` | Fatal error – changes were discarded |
| `2` | Changes published but policy install failed |

### Logs

The sync writes to `sync_cloudflare.log` in the same directory as the script,
and also to stdout (captured by cron in `/var/mail/root` unless redirected).

---

## Uninstall

```bash
# Remove the cron entry
crontab -l | grep -v sync_cloudflare | crontab -

# Remove credentials
rm -rf /etc/cp_cloudflare_sync

# Remove script files
rm -rf /home/admin/cf_sync
```

Objects and the group are **not** automatically removed from the Management
Server — delete them manually in SmartConsole if required.

---

## Security notes

- Credentials live in `/etc/cp_cloudflare_sync/env` (`chmod 600`, root only).
- The script disables SSL certificate verification for the Management Server
  connection (`verify_ssl=False`) because the server typically uses a
  self-signed cert.  In high-security environments, export the Management
  Server's CA certificate and pass it via `verify="/path/to/ca.pem"` in the
  `CheckPointSession` constructor.
- The API user should have the minimum permission profile needed:
  read-write on Network Objects and Policy Installation.

## License & Disclaimer
This source code is free to use, modify, and distribute for any purpose without restriction. Attribution is not required, but if you do choose to credit the original author, it is genuinely appreciated. Please note that the majority of this code was written by the free version of Claude AI, with only minor manual modifications made to fix small issues. As such, this code is provided as-is, with no warranty or guarantee of any kind. The author assumes no responsibility for its correctness, reliability, or suitability for any particular use case. Use it at your own risk, and always test thoroughly before deploying to a live production infrastructure.
