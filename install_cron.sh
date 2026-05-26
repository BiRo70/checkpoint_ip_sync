#!/usr/bin/env bash
# =============================================================================
# install_cron.sh
# =============================================================================
# Sets up the daily cron job for sync_object_to_checkpoint.py on the
# CheckPoint Management Server.
#
# What this script does:
#   1. Validates that Python 3 and the 'requests' library are available.
#   2. Resolves the log file location using CheckPoint's $FWDIR/log if
#      available, falling back to /var/log if not.
#   3. Installs a logrotate configuration to prevent the log from filling
#      the disk (daily rotation, 30-day retention, compressed).
#   4. Creates /etc/cp_object_sync/env containing the credentials and
#      configuration (readable only by root).
#   5. Installs a cron entry that runs the sync at 03:00 every day.
#   6. Optionally runs the script immediately in DRY RUN mode to verify
#      connectivity.
#
# Usage (run as root on the Management Server):
#   chmod +x install_cron.sh
#   ./install_cron.sh
#
# Uninstall:
#   crontab -l | grep -v sync_object | crontab -
#   rm -rf /etc/cp_object_sync
#   rm -f  /etc/logrotate.d/cp_object_sync
# =============================================================================

# Enable Bash Strict Mode: exit on command errors, unset variables, or pipe failures
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root."
    exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────

# Directory where the sync script lives (same directory as this installer)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/sync_object_to_checkpoint.py"

# Secure configuration directory (only root can read it)
CONFIG_DIR="/etc/cp_object_sync"
ENV_FILE="${CONFIG_DIR}/env"

# Cron wrapper – thin shell that sources the env file before calling Python
CRON_WRAPPER="${SCRIPT_DIR}/run_sync.sh"

# ── Resolve the log file location ────────────────────────────────────────────
# CheckPoint's $FWDIR/log is the correct place to store operational logs on
# the Management Server.  The directory sits on a dedicated partition that
# CheckPoint's own disk-space management monitors, which prevents runaway
# logs from filling the OS root volume.
#
# The log file is written directly into $FWDIR/log (no subdirectory created).
# If $FWDIR is not set (e.g. running on a plain Linux host for testing) we
# fall back to /var/log and warn the operator.

# Source the CheckPoint environment if it hasn't been sourced already.
# /etc/profile.d/CP.sh sets FWDIR, CPDIR, CPHOME, etc.
if [[ -z "${FWDIR:-}" ]]; then
    if [[ -f /etc/profile.d/CP.sh ]]; then
        # shellcheck source=/dev/null
        source /etc/profile.d/CP.sh
    fi
fi

if [[ -n "${FWDIR:-}" && -d "${FWDIR}/log" ]]; then
    # Use the CheckPoint managed log partition directly
    LOG_DIR="${FWDIR}/log"
    info "CheckPoint FWDIR detected: logs will be written to ${LOG_DIR}."
else
    # Fallback for non-Gaia or development environments
    LOG_DIR="/var/log"
    warn "FWDIR not set or \$FWDIR/log not found."
    warn "Falling back to ${LOG_DIR} for logs."
    warn "Ensure this path is on a partition with sufficient free space."
fi

LOG_FILE="${LOG_DIR}/sync_object.log"
info "Log file: ${LOG_FILE}"

# ── Install logrotate configuration ──────────────────────────────────────────
# logrotate is standard on Gaia and all RHEL-family systems.  This config:
#
#   daily          – rotate every day (aligns with the daily cron run)
#   rotate 30      – keep 30 days of history before deleting old logs
#   compress       – gzip rotated files to save disk space
#   delaycompress  – compress the previous rotation, not the one just rotated
#                    (keeps the most recent rotated file readable without gunzip)
#   missingok      – don't error if the log file doesn't exist yet
#   notifempty     – don't rotate if the file is empty
#   create 640 root root – recreate the log file with safe permissions
#   dateext        – append the rotation date to the rotated filename
#                    e.g. sync_object.log-20250115
#
# Size guard: 'size 50M' means logrotate will also rotate mid-day if the log
# somehow grows beyond 50 MB before the next scheduled run.

LOGROTATE_CONF="/etc/logrotate.d/cp_object_sync"

info "Installing logrotate configuration at ${LOGROTATE_CONF}..."

cat > "$LOGROTATE_CONF" <<LOGROTATE
# logrotate config for CheckPoint object sync
# Managed by install_cron.sh – do not edit manually.

${LOG_FILE} {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
    dateext
    dateformat -%Y%m%d

    # Emergency size cap: rotate immediately if the log exceeds 50 MB,
    # regardless of whether a day has passed.  This is the last line of
    # defence against a runaway loop filling the disk.
    size 50M

    # Post-rotation hook: write a marker line into the fresh log so it is
    # easy to spot where each rotation boundary is.
    postrotate
        echo "--- log rotated on \$(date -u +'%Y-%m-%dT%H:%M:%SZ') ---" >> ${LOG_FILE} || true
    endscript
}
LOGROTATE

chmod 644 "$LOGROTATE_CONF"
info "logrotate configuration installed."

# Test the logrotate config immediately so we catch syntax errors at install
# time rather than silently at the next rotation
if logrotate --debug "$LOGROTATE_CONF" &>/dev/null; then
    info "logrotate configuration validated successfully."
else
    warn "logrotate --debug reported a warning.  Review ${LOGROTATE_CONF}."
fi

# ── Validate the sync script exists ──────────────────────────────────────────
if [[ ! -f "$SYNC_SCRIPT" ]]; then
    error "sync_object_to_checkpoint.py not found at: $SYNC_SCRIPT"
    error "Place both files in the same directory and re-run."
    exit 1
fi

# ── Validate Python 3 ────────────────────────────────────────────────────────
info "Checking Python 3 availability..."
PYTHON_BIN=""
for candidate in python3 python3.11 python3.10 python3.9 python3.8; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON_BIN="$(command -v "$candidate")"
        break
    fi
done

if [[ -z "$PYTHON_BIN" ]]; then
    error "Python 3 not found.  Install it with:  yum install python3"
    exit 1
fi

PYTHON_VERSION=$("$PYTHON_BIN" --version 2>&1)
info "Using: $PYTHON_BIN  ($PYTHON_VERSION)"

# ── Validate / install the 'requests' library ────────────────────────────────
info "Checking 'requests' library..."
if ! "$PYTHON_BIN" -c "import requests" 2>/dev/null; then
    warn "'requests' is not installed.  Attempting pip install..."
    if command -v pip3 &>/dev/null; then
        pip3 install --quiet requests
    else
        error "pip3 not found.  Install requests manually: pip3 install requests"
        exit 1
    fi
fi
info "'requests' library is available."

# ── Collect configuration interactively ──────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "   CheckPoint Management Server – Sync Configuration"
echo "══════════════════════════════════════════════════════════"
echo ""

read -rp "Management Server IP or hostname [required]: " CP_HOST
[[ -z "$CP_HOST" ]] && { error "CP_HOST cannot be empty."; exit 1; }

read -rp "Management API port [443]: " CP_PORT
CP_PORT="${CP_PORT:-443}"

read -rp "API admin username [required]: " CP_USER
[[ -z "$CP_USER" ]] && { error "CP_USER cannot be empty."; exit 1; }

read -srp "API admin password [required]: " CP_PASSWORD
echo ""
[[ -z "$CP_PASSWORD" ]] && { error "CP_PASSWORD cannot be empty."; exit 1; }

read -rp "Domain (leave blank for standalone / not MDS): " CP_DOMAIN

read -rp "Policy package name [Standard]: " CP_POLICY
CP_POLICY="${CP_POLICY:-Standard}"

read -rp "Network group name [GRP_object_Subnets]: " CP_GROUP
CP_GROUP="${CP_GROUP:-GRP_object_Subnets}"

read -rp "Cron schedule (cron syntax) [0 3 * * *  = daily at 03:00]: " CRON_SCHEDULE
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * *}"

echo ""

# ── Write the env file (mode 600 – root only) ─────────────────────────────────
info "Writing configuration to ${ENV_FILE}..."
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

cat > "$ENV_FILE" <<EOF
# object → CheckPoint sync configuration
# Generated by install_cron.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# WARNING: This file contains credentials – do NOT share it.

export CP_HOST="${CP_HOST}"
export CP_PORT="${CP_PORT}"
export CP_USER="${CP_USER}"
export CP_PASSWORD="${CP_PASSWORD}"
export CP_DOMAIN="${CP_DOMAIN}"
export CP_POLICY="${CP_POLICY}"
export CP_GROUP="${CP_GROUP}"

# Log directory resolved at install time ($FWDIR/log or /var/log)
export CP_LOG_DIR="${LOG_DIR}"

# Optional overrides (uncomment and adjust as needed):
# export CP_OBJ_PREFIX="NET_object_"
# export CF_API_URL="https://api.object.com/client/v4/ips"
# export LOG_LEVEL="INFO"
# export DRY_RUN="0"
EOF

chmod 600 "$ENV_FILE"
info "Configuration saved.  Permissions set to 600 (root-only)."

# ── Write the cron wrapper script ─────────────────────────────────────────────
# Cron runs with a minimal environment; this wrapper ensures:
#   - The CheckPoint environment (FWDIR etc.) is sourced first
#   - The secure env file is sourced for credentials
#   - Python is on PATH
#   - Output is appended to the managed log file via tee
#   - Each run is clearly delimited with timestamped markers for easy grepping
info "Writing cron wrapper to ${CRON_WRAPPER}..."

cat > "$CRON_WRAPPER" <<WRAPPER
#!/usr/bin/env bash
# Cron wrapper for sync_object_to_checkpoint.py
# Sources the CheckPoint environment and credentials, then runs the sync.

# Abort on errors so a partial environment doesn't cause silent bad runs
set -euo pipefail

# ── Source the CheckPoint environment ────────────────────────────────────────
# This sets FWDIR, CPDIR, and other CheckPoint variables.  Without it,
# paths and libraries used by CheckPoint utilities may be missing.
if [[ -f /etc/profile.d/CP.sh ]]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/CP.sh
fi

# ── Source the secure sync configuration ──────────────────────────────────────
# shellcheck source=/dev/null
source "${ENV_FILE}"

# ── Ensure Python and system utilities are on PATH ────────────────────────────
export PATH="/usr/local/bin:/usr/bin:/bin:\${PATH}"

# ── Ensure the log directory is accessible ───────────────────────────────────
# The directory ($FWDIR/log or /var/log) is managed by the OS and CheckPoint
# and should always exist.  We check rather than create.
if [[ ! -d "\${CP_LOG_DIR}" ]]; then
    echo "ERROR: Log directory \${CP_LOG_DIR} does not exist.  Aborting." >&2
    exit 1
fi

LOG_FILE="\${CP_LOG_DIR}/sync_object.log"

# Write a timestamped run-start marker so individual runs are easy to grep:
#   grep "run started" \${CP_LOG_DIR}/sync_object.log
echo "━━━ run started \$(date -u +'%Y-%m-%dT%H:%M:%SZ') ━━━" >> "\${LOG_FILE}"

# ── Run the sync ───────────────────────────────────────────────────────────────
# tee -a appends stdout+stderr to the managed log file while also passing it
# through to stdout so cron can capture and mail it to root on failure.
"${PYTHON_BIN}" "${SYNC_SCRIPT}" 2>&1 | tee -a "\${LOG_FILE}"

echo "━━━ run finished \$(date -u +'%Y-%m-%dT%H:%M:%SZ') ━━━" >> "\${LOG_FILE}"
WRAPPER

chmod 750 "$CRON_WRAPPER"
info "Wrapper script created."

# ── Install the cron entry ────────────────────────────────────────────────────
CRON_MARKER="# sync_object_to_checkpoint"
CRON_LINE="${CRON_SCHEDULE}  ${CRON_WRAPPER}  ${CRON_MARKER}"

info "Installing cron entry for root..."

# Remove any previous version of this entry to avoid duplicates
( crontab -l 2>/dev/null | grep -v "$CRON_MARKER" ; echo "$CRON_LINE" ) | crontab -

info "Cron entry installed:"
echo ""
echo "    ${CRON_LINE}"
echo ""

# ── Optional immediate dry-run ────────────────────────────────────────────────
echo ""
read -rp "Run a dry-run now to verify connectivity? [Y/n]: " DO_DRYRUN
DO_DRYRUN="${DO_DRYRUN:-Y}"

if [[ "${DO_DRYRUN^^}" == "Y" ]]; then
    info "Running dry-run (no changes will be made)..."
    echo "──────────────────────────────────────────────────────────"
    DRY_RUN=1 bash "$CRON_WRAPPER" || true
    echo "──────────────────────────────────────────────────────────"
    info "Dry-run complete.  Review output above for any errors."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "   Installation complete"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Script:        ${SYNC_SCRIPT}"
echo "  Config:        ${ENV_FILE}"
echo "  Wrapper:       ${CRON_WRAPPER}"
echo "  Log file:      ${LOG_FILE}"
echo "  logrotate:     ${LOGROTATE_CONF}  (daily, 30-day retention, 50 MB cap)"
echo "  Cron schedule: ${CRON_SCHEDULE}"
echo ""
echo "  To run manually:         bash ${CRON_WRAPPER}"
echo "  To run in dry-run:       DRY_RUN=1 bash ${CRON_WRAPPER}"
echo "  To tail the log:         tail -f ${LOG_FILE}"
echo "  To check cron:           crontab -l"
echo "  To force log rotation:   logrotate -f ${LOGROTATE_CONF}"
echo "  To check log size:       du -sh ${LOG_FILE}"
echo "  To uninstall:"
echo "    crontab -l | grep -v sync_object | crontab -"
echo "    rm -rf ${CONFIG_DIR}"
echo "    rm -f  ${LOGROTATE_CONF}"
echo "    rm -f  ${LOG_FILE}"
echo ""
