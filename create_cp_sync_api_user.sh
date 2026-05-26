#!/usr/bin/env bash
# =============================================================================
# create_cp_sync_api_user.sh
# =============================================================================
# Creates a least-privilege CheckPoint API admin account for use by the
# subnet sync script.
#
# The account is granted exactly two capabilities:
#   1. Read/write access to Network Objects (create, edit, delete networks,
#      groups, and hosts)
#   2. Install policy (push the "Standard" package to gateways)
#
# Everything else (access control rules, NAT, threat prevention, users,
# certificates, etc.) is explicitly denied.
#
# What this script creates:
#   - A custom permission profile: "CP_Sync_Profile"
#   - An API admin account:        "cp_sync_api" (or whatever you specify)
#
# Usage (run as root on the Management Server):
#   chmod +x create_cp_sync_api_user.sh
#   ./create_cp_sync_api_user.sh
#
# Requirements:
#   - mgmt_cli must be on PATH (standard on Gaia / Management Server)
#   - Run on the Management Server itself, or set MGMT_HOST/MGMT_USER to
#     connect remotely
# =============================================================================

# Enable Bash Strict Mode: exit on command errors, unset variables, or pipe failures
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}──── $* ────${NC}"; }

# =============================================================================
# CONFIGURATION DEFAULTS
# These can be overridden by environment variables before running the script.
# =============================================================================

# Name of the permission profile to create
PROFILE_NAME="${CP_PROFILE_NAME:-CP_Sync_Profile}"

# Name and password of the API admin to create
API_USER="${CP_API_USER:-cp_sync_api}"
API_PASS="${CP_API_PASS:-}"           # Prompted interactively if blank

# Connection settings for mgmt_cli
# Leave MGMT_HOST blank to connect to the local Management Server
MGMT_HOST="${MGMT_HOST:-}"
MGMT_PORT="${MGMT_PORT:-443}"
MGMT_USER="${MGMT_USER:-}"           # Prompted interactively if blank
MGMT_PASS="${MGMT_PASS:-}"           # Prompted interactively if blank
MGMT_DOMAIN="${MGMT_DOMAIN:-}"       # Only needed for MDS environments

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

section "Pre-flight checks"

# Verify mgmt_cli is available – it ships with the CheckPoint Management
# Server and is the official CLI for the Management REST API
if ! command -v mgmt_cli &>/dev/null; then
    error "mgmt_cli not found on PATH."
    error "This script must run on the CheckPoint Management Server,"
    error "or mgmt_cli must be installed and reachable."
    exit 1
fi

info "mgmt_cli found: $(command -v mgmt_cli)"

# =============================================================================
# COLLECT INTERACTIVE INPUT
# =============================================================================

section "Configuration"

# Prompt for the admin password for the new API account
if [[ -z "$API_PASS" ]]; then
    while true; do
        read -srp "Password for new API user '${API_USER}': " API_PASS
        echo ""
        read -srp "Confirm password: " API_PASS_CONFIRM
        echo ""
        if [[ "$API_PASS" == "$API_PASS_CONFIRM" ]]; then
            break
        fi
        warn "Passwords do not match – try again."
    done
fi

# Prompt for existing admin credentials used to bootstrap the operation
if [[ -z "$MGMT_USER" ]]; then
    read -rp "Management admin username (to authenticate this setup): " MGMT_USER
fi
if [[ -z "$MGMT_PASS" ]]; then
    read -srp "Management admin password: " MGMT_PASS
    echo ""
fi

echo ""
info "Will create permission profile : ${PROFILE_NAME}"
info "Will create API admin account  : ${API_USER}"
if [[ -n "$MGMT_HOST" ]]; then
    info "Connecting to remote host       : ${MGMT_HOST}:${MGMT_PORT}"
else
    info "Connecting to                   : localhost"
fi

echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ "${CONFIRM^^}" != "Y" ]]; then
    info "Aborted by user."
    exit 0
fi

# =============================================================================
# BUILD mgmt_cli CONNECTION ARGUMENTS
# =============================================================================
# mgmt_cli accepts either --root true (for local Gaia shell) or
# -u/-p/-m/-d flags for explicit credentials.

build_conn_args() {
    local args=()

    if [[ -n "$MGMT_HOST" ]]; then
        # Remote connection – supply explicit credentials
        args+=( -u "$MGMT_USER" -p "$MGMT_PASS" -m "$MGMT_HOST" --port "$MGMT_PORT" )
    else
        # Local connection on the Management Server itself
        args+=( -u "$MGMT_USER" -p "$MGMT_PASS" )
    fi

    # Domain is only added for Multi-Domain Server environments
    if [[ -n "$MGMT_DOMAIN" ]]; then
        args+=( -d "$MGMT_DOMAIN" )
    fi

    echo "${args[@]}"
}

# Capture connection args into an array (safe for arguments with spaces)
mapfile -t CONN_ARGS < <(build_conn_args | tr ' ' '\n')

# =============================================================================
# HELPER: run a mgmt_cli command and check for errors
# =============================================================================

run_mgmt() {
    # Usage: run_mgmt <command> [key value ...]
    # Runs mgmt_cli and exits if the API returns an error code.
    local cmd="$1"; shift

    local output
    output=$(mgmt_cli "$cmd" "$@" "${CONN_ARGS[@]}" --format json 2>&1) || {
        error "mgmt_cli '${cmd}' failed:"
        error "$output"
        # Attempt a clean discard before exiting so the DB stays consistent
        mgmt_cli discard "${CONN_ARGS[@]}" --format json &>/dev/null || true
        exit 1
    }

    # The Management API embeds errors inside a successful HTTP 200 response,
    # so we also check for the presence of "errors" in the JSON body
    if echo "$output" | grep -q '"type" *: *"err"'; then
        error "Management API returned an error for '${cmd}':"
        error "$output"
        mgmt_cli discard "${CONN_ARGS[@]}" --format json &>/dev/null || true
        exit 1
    fi

    echo "$output"
}

# Shorthand to check whether an object already exists (returns 0 or 1)
object_exists() {
    local obj_type="$1"
    local obj_name="$2"
    mgmt_cli "show-${obj_type}" name "$obj_name" "${CONN_ARGS[@]}" \
             --format json &>/dev/null
}

# =============================================================================
# STEP 1 – CREATE THE PERMISSION PROFILE
# =============================================================================
# CheckPoint permission profiles control what an admin may see and change.
# We use the 'add-administrator-profile' command available in R80.10+.
#
# Key permission flags used:
#
#   access-control           → "show"        Read-only view of AC policy layers
#   network-objects-access   → "write"       Full CRUD on network objects/groups
#   install-policy           → true          Allowed to push policy packages
#   management-api           → true          Account is usable via the REST API
#
# Everything not listed defaults to "none" (no access).
# =============================================================================

section "Step 1 – Creating permission profile '${PROFILE_NAME}'"

if object_exists "administrator-profile" "$PROFILE_NAME"; then
    warn "Permission profile '${PROFILE_NAME}' already exists – skipping creation."
    warn "If you want to reset its permissions, delete it in SmartConsole first."
else
    run_mgmt add-administrator-profile \
        name                        "$PROFILE_NAME" \
        \
        color                       "blue" \
        comments                    "Least-privilege profile for object subnet sync (auto-created)" \
        \
        \
        network-objects-access      "write" \
        \
        \
        access-control              "show" \
        \
        \
        install-policy              "true" \
        \
        \
        monitoring-and-logging      "none" \
        \
        user-authority              "none" \
        \
        management                  "none" \
        \
        threat-prevention           "none" \
        \
        layers                      "none" \
        \
        mobile-access               "none" \
        \
        management-api              "true"

    info "Permission profile '${PROFILE_NAME}' created successfully."
fi

# =============================================================================
# STEP 2 – CREATE THE API ADMIN ACCOUNT
# =============================================================================
# 'add-administrator' creates a new CheckPoint admin user.
#
# authentication-method "CheckPoint Password" stores a local password hash
# on the Management Server, which is appropriate for a service account.
#
# The account is explicitly marked as an API-only admin by assigning the
# profile we created above.  It will NOT be able to log into SmartConsole.
#
# If you need SmartConsole access for troubleshooting, set a different profile
# that includes SmartConsole access.
# =============================================================================

section "Step 2 – Creating API admin account '${API_USER}'"

if object_exists "administrator" "$API_USER"; then
    warn "Administrator '${API_USER}' already exists – skipping creation."
    warn "To update its password or profile, use SmartConsole or:"
    warn "  mgmt_cli set-administrator name '${API_USER}' password '<new>' ..."
else
    run_mgmt add-administrator \
        name                    "$API_USER" \
        password                "$API_PASS" \
        authentication-method   "CheckPoint Password" \
        \
        permissions-profile     "$PROFILE_NAME" \
        \
        color                   "blue" \
        comments                "object subnet sync service account (auto-created)"

    info "Administrator '${API_USER}' created successfully."
fi

# =============================================================================
# STEP 3 – PUBLISH THE SESSION
# =============================================================================
# Profile and admin objects are not visible to other sessions until published.

section "Step 3 – Publishing changes"

run_mgmt publish
info "Published successfully."

# =============================================================================
# DONE
# =============================================================================

section "Summary"

echo ""
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │           API account setup complete                 │"
echo "  ├──────────────────────────────────────────────────────┤"
printf "  │  %-20s  %-30s  │\n" "Permission profile:" "$PROFILE_NAME"
printf "  │  %-20s  %-30s  │\n" "API username:"       "$API_USER"
printf "  │  %-20s  %-30s  │\n" "Capabilities:"       "Network objects (r/w)"
printf "  │  %-20s  %-30s  │\n" ""                    "Install policy"
echo "  └──────────────────────────────────────────────────────┘"
echo ""
info "Next step: export these credentials into the sync script's env file:"
echo ""
echo "    sudo vi /etc/cp_object_sync/env"
echo ""
echo "    export CP_USER=\"${API_USER}\""
echo "    export CP_PASSWORD=\"<the password you just set>\""
echo ""
warn "Store the password securely.  It is not printed here."
echo ""
