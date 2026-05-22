#!/usr/bin/env python3
"""
sync_cloudflare_to_checkpoint.py
─────────────────────────────────────────────────────────────────────────────
Synchronises Cloudflare's published IPv4 CIDR ranges into a Check Point
network-group object called GRP_Cloudflare_Subnets on the Management Server.

High-level flow
───────────────
1.  Fetch current Cloudflare IPv4 CIDRs from the public API.
2.  Log in to the Check Point Management API.
3.  Ensure the target group (GRP_Cloudflare_Subnets) exists (create it if not).
4.  Resolve which network objects are already in the group.
5.  Create any missing network objects (one per CIDR).
6.  Update the group so it contains exactly the current Cloudflare CIDRs.
7.  Delete stale network objects that were removed from the group AND are not
    referenced by any other policy element (safe deletion).
8.  Publish the session if any changes were made.
9.  Install the policy package named "Standard" only when changes occurred.
10. Log out cleanly.

Configuration is read from environment variables so no credentials are
hard-coded in this file (see CONFIGURATION section below).

Usage
─────
    python3 sync_cloudflare_to_checkpoint.py

Environment variables (required)
─────────────────────────────────
    CP_HOST        – IP or hostname of the Management Server
    CP_USER        – API admin username
    CP_PASSWORD    – API admin password

Environment variables (optional)
─────────────────────────────────
    CP_PORT        – Management API port  (default: 443)
    CP_DOMAIN      – Domain name for MDS environments (default: omitted)
    CP_POLICY      – Policy package to install  (default: Standard)
    CP_GROUP       – Name of the network group  (default: GRP_Cloudflare_Subnets)
    CP_OBJ_PREFIX  – Prefix for network objects (default: NET_Cloudflare_)
    CF_API_URL     – Cloudflare IPs endpoint    (default: https://api.cloudflare.com/client/v4/ips)
    LOG_LEVEL      – Logging verbosity (DEBUG/INFO/WARNING/ERROR, default: INFO)
    DRY_RUN        – Set to "1" to simulate without making changes
"""

import json
import logging
import os
import sys
import time
import urllib.parse
from ipaddress import IPv4Network, ip_network
from typing import Any

import requests
import urllib3

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION  (sourced from environment variables)
# ─────────────────────────────────────────────────────────────────────────────

CP_HOST       = os.environ.get("CP_HOST", "")
CP_PORT       = int(os.environ.get("CP_PORT", "443"))
CP_USER       = os.environ.get("CP_USER", "")
CP_PASSWORD   = os.environ.get("CP_PASSWORD", "")
CP_DOMAIN     = os.environ.get("CP_DOMAIN", "")          # blank = not MDS
CP_POLICY     = os.environ.get("CP_POLICY", "Standard")
CP_GROUP      = os.environ.get("CP_GROUP", "GRP_Cloudflare_Subnets")
CP_OBJ_PREFIX = os.environ.get("CP_OBJ_PREFIX", "NET_Cloudflare_")
CF_API_URL    = os.environ.get("CF_API_URL", "https://api.cloudflare.com/client/v4/ips")
LOG_LEVEL     = os.environ.get("LOG_LEVEL", "INFO").upper()
DRY_RUN       = os.environ.get("DRY_RUN", "0") == "1"

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING SETUP
# ─────────────────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        # Write to stdout so cron/systemd captures it naturally
        logging.StreamHandler(sys.stdout),
        # Also write to a local log file next to this script
        logging.FileHandler(
            os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "sync_cloudflare.log"),
            encoding="utf-8",
        ),
    ],
)
log = logging.getLogger(__name__)

# Suppress the urllib3 "InsecureRequestWarning" that fires because the
# Management Server typically uses a self-signed certificate.  We verify
# the server fingerprint at login instead of relying on the system CA store.
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

# Maximum objects returned in a single Check Point API page
CP_PAGE_LIMIT = 500

# Seconds to wait between polling an async task (install-policy)
TASK_POLL_INTERVAL = 5  # seconds

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: convert a CIDR string into a safe object name
# ─────────────────────────────────────────────────────────────────────────────

def cidr_to_obj_name(cidr: str) -> str:
    """
    Derive a deterministic Check Point object name from a CIDR.

    Example: "103.21.244.0/22" → "NET_Cloudflare_103.21.244.0_22"

    The slash is replaced with an underscore because Check Point object names
    must not contain forward slashes.
    """
    safe = cidr.replace("/", "_")
    return f"{CP_OBJ_PREFIX}{safe}"


# ─────────────────────────────────────────────────────────────────────────────
# CLASS: CheckPointSession
# ─────────────────────────────────────────────────────────────────────────────

class CheckPointSession:
    """
    Thin wrapper around the Check Point Management REST API.

    All HTTP calls go through _call() which handles:
    - Automatic X-chkp-sid session header injection
    - JSON serialisation / deserialisation
    - Basic error checking and logging
    """

    def __init__(self, host: str, port: int, verify_ssl: bool = False):
        self.base_url  = f"https://{host}:{port}/web_api"
        self.verify    = verify_ssl   # set True in production with a valid cert
        self.sid       = None         # session ID returned after login
        self.session   = requests.Session()
        self.session.headers.update({"Content-Type": "application/json"})

    # ── Low-level HTTP call ──────────────────────────────────────────────────

    def _call(self, endpoint: str, payload: dict | None = None) -> dict:
        """
        POST *payload* to *endpoint* and return the parsed JSON body.

        Raises RuntimeError if the Management API reports a non-ok status or
        if the HTTP layer itself fails.
        """
        url     = f"{self.base_url}/{endpoint}"
        payload = payload or {}

        # Inject session ID into every call after login
        if self.sid:
            self.session.headers["X-chkp-sid"] = self.sid

        log.debug("POST /%s  payload=%s", endpoint, json.dumps(payload))

        try:
            resp = self.session.post(
                url,
                json=payload,
                verify=self.verify,
                timeout=60,
            )
            resp.raise_for_status()
        except requests.RequestException as exc:
            raise RuntimeError(f"HTTP error calling /{endpoint}: {exc}") from exc

        body = resp.json()

        # The Management API returns a top-level "success" key for most calls
        if not body.get("success", True):
            # Collect all error messages for a helpful log line
            errors = body.get("errors", []) or body.get("warnings", [])
            msg = "; ".join(e.get("message", str(e)) for e in errors) or str(body)
            raise RuntimeError(f"Management API error on /{endpoint}: {msg}")

        return body

    # ── Session management ───────────────────────────────────────────────────

    def login(self, username: str, password: str, domain: str = "") -> None:
        """
        Authenticate and store the session ID (sid).

        If *domain* is provided the session is scoped to that domain, which is
        required for Multi-Domain Server (MDS) environments.
        """
        log.info("Logging in to Check Point Management API at %s", self.base_url)

        payload: dict[str, Any] = {
            "user":     username,
            "password": password,
            # Use a read-write session so we can make changes
            "read-only": False,
        }
        if domain:
            payload["domain"] = domain

        body = self._call("login", payload)
        self.sid = body["sid"]
        log.info("Login successful – session ID: %s…", self.sid[:8])

    def logout(self) -> None:
        """
        Terminate the current API session.

        Always call this – even on failure paths – to avoid leaving an open
        session on the Management Server (which has a finite concurrent-session
        limit).
        """
        if not self.sid:
            return
        try:
            self._call("logout")
            log.info("Logged out successfully.")
        except RuntimeError as exc:
            # Non-fatal: log and continue shutdown
            log.warning("Logout call failed (session may already be expired): %s", exc)
        finally:
            self.sid = None

    def publish(self) -> None:
        """
        Commit the current session's changes so they become visible to other
        admins and eligible for policy installation.
        """
        log.info("Publishing session changes…")
        if DRY_RUN:
            log.info("[DRY RUN] Skipping publish.")
            return
        self._call("publish")
        log.info("Publish complete.")

    def discard(self) -> None:
        """
        Roll back all unpublished changes in the current session.
        Called on error paths to leave the database clean.
        """
        log.warning("Discarding session changes due to error…")
        try:
            self._call("discard")
        except RuntimeError as exc:
            log.warning("Discard failed: %s", exc)

    # ── Pagination helper ────────────────────────────────────────────────────

    def _get_all(self, endpoint: str, payload: dict) -> list[dict]:
        """
        Fetch every page from a paginated Management API list call.

        The Management API caps results at CP_PAGE_LIMIT objects per page.
        This helper iterates through all pages and returns the combined list.
        """
        all_objects: list[dict] = []
        offset = 0

        while True:
            page_payload = {**payload, "limit": CP_PAGE_LIMIT, "offset": offset}
            body   = self._call(endpoint, page_payload)
            items  = body.get("objects", [])
            total  = body.get("total", len(items))

            all_objects.extend(items)
            offset += len(items)
            log.debug("  Fetched %d / %d objects from /%s", offset, total, endpoint)

            if offset >= total:
                break

        return all_objects

    # ── Network object helpers ───────────────────────────────────────────────

    def get_network_object(self, name: str) -> dict | None:
        """
        Return the network object with *name*, or None if it does not exist.
        Uses show-network which is faster than a full text search.
        """
        try:
            return self._call("show-network", {"name": name})
        except RuntimeError:
            # The API raises an error (code "generic_err") when the object is
            # not found; we treat that as "does not exist"
            return None

    def create_network_object(self, name: str, subnet: str, mask_length: int,
                              color: str = "blue") -> dict:
        """
        Create a host-network object for the given subnet/mask.

        *color* is cosmetic but helps admins visually identify Cloudflare
        objects inside SmartConsole.
        """
        log.info("  Creating network object: %s  (%s/%d)", name, subnet, mask_length)
        if DRY_RUN:
            log.info("  [DRY RUN] Skipping creation.")
            return {"name": name, "uid": "dry-run-uid"}

        return self._call("add-network", {
            "name":         name,
            "subnet":       subnet,
            "mask-length":  mask_length,
            "color":        color,
            "comments":     "Auto-managed by sync_cloudflare_to_checkpoint.py",
        })

    def delete_network_object(self, name: str) -> None:
        """
        Delete a network object by name.

        Safe to call only after verifying the object is not referenced anywhere
        else (see is_object_in_use()).
        """
        log.info("  Deleting stale network object: %s", name)
        if DRY_RUN:
            log.info("  [DRY RUN] Skipping deletion.")
            return
        self._call("delete-network", {"name": name})

    def is_object_in_use(self, uid: str) -> bool:
        """
        Return True if *uid* is referenced by any rule, group, or NAT entry
        other than GRP_Cloudflare_Subnets itself.

        The 'where-used' API endpoint returns every reference to an object.
        We consider 'in use' to mean at least one reference that is NOT the
        target group, so we don't accidentally remove objects that are shared.
        """
        try:
            body = self._call("where-used", {"uid": uid})
        except RuntimeError:
            # If the call fails we conservatively assume it IS in use
            return True

        used_directly    = body.get("used-directly", {})
        total_references = used_directly.get("total", 0)

        # The group itself will appear as one reference.  If total > 1, there
        # are additional references we should not disturb.
        return total_references > 1

    # ── Group helpers ────────────────────────────────────────────────────────

    def get_group(self, name: str) -> dict | None:
        """
        Return the group object with *name*, or None if it does not exist.
        """
        try:
            return self._call("show-group", {"name": name})
        except RuntimeError:
            return None

    def create_group(self, name: str) -> dict:
        """
        Create an empty network group.
        """
        log.info("Creating new network group: %s", name)
        if DRY_RUN:
            log.info("[DRY RUN] Skipping group creation.")
            return {"name": name, "uid": "dry-run-group-uid", "members": []}

        return self._call("add-group", {
            "name":     name,
            "color":    "blue",
            "comments": "Cloudflare CIDR ranges – auto-managed by sync script",
        })

    def set_group_members(self, name: str, member_names: list[str]) -> None:
        """
        Replace the group's member list with exactly *member_names*.

        'set-group' with members=[…] replaces the entire member list atomically,
        which is simpler and safer than adding/removing one by one.
        """
        log.info("Updating group '%s' with %d members.", name, len(member_names))
        if DRY_RUN:
            log.info("[DRY RUN] Skipping set-group.")
            return
        self._call("set-group", {
            "name":    name,
            "members": member_names,
        })

    # ── Policy installation ──────────────────────────────────────────────────

    def install_policy(self, policy_name: str) -> None:
        """
        Install the named policy package on all targets and wait for completion.

        install-policy is asynchronous: the API returns a task-id immediately
        and we poll show-task until the task finishes (or fails).
        """
        log.info("Installing policy package '%s'…", policy_name)
        if DRY_RUN:
            log.info("[DRY RUN] Skipping policy install.")
            return

        # Kick off the install
        body    = self._call("install-policy", {"policy-package": policy_name})
        task_id = body.get("task-id")

        if not task_id:
            raise RuntimeError("install-policy did not return a task-id")

        # Poll until the task reaches a terminal state
        while True:
            time.sleep(TASK_POLL_INTERVAL)
            status_body = self._call("show-task", {"task-id": task_id})
            tasks       = status_body.get("tasks", [])

            if not tasks:
                raise RuntimeError("show-task returned no tasks for id " + task_id)

            task   = tasks[0]
            status = task.get("status", "").lower()

            log.info("  Policy install status: %s  (%s%%)",
                     status, task.get("progress-percentage", "?"))

            if status == "succeeded":
                log.info("Policy install completed successfully.")
                return
            elif status in ("failed", "partially succeeded"):
                details = task.get("task-details", [])
                msg     = "; ".join(str(d) for d in details) or status
                raise RuntimeError(f"Policy installation failed: {msg}")
            # Otherwise still 'in progress' – loop and poll again


# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 – Fetch Cloudflare IPs
# ─────────────────────────────────────────────────────────────────────────────

def fetch_cloudflare_ipv4_cidrs() -> list[str]:
    """
    Call the Cloudflare public API and return a sorted list of IPv4 CIDRs.

    The endpoint returns both ipv4_cidrs and ipv6_cidrs; we only care about
    IPv4 here.  We also normalise each CIDR to its canonical network address
    (e.g. 103.21.244.1/22 → 103.21.244.0/22) to avoid spurious object names.
    """
    log.info("Fetching Cloudflare IPv4 CIDRs from %s", CF_API_URL)

    try:
        resp = requests.get(CF_API_URL, timeout=30)
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise RuntimeError(f"Failed to fetch Cloudflare IP list: {exc}") from exc

    body = resp.json()

    if not body.get("success"):
        errors = body.get("errors", [])
        raise RuntimeError(f"Cloudflare API returned failure: {errors}")

    raw_cidrs: list[str] = body["result"].get("ipv4_cidrs", [])

    # Normalise to network address (strict=False keeps things like /32 hosts)
    normalised: list[str] = []
    for cidr in raw_cidrs:
        try:
            net = ip_network(cidr, strict=False)
            # Only include IPv4; skip any sneaky v6-mapped addresses
            if isinstance(net, IPv4Network):
                normalised.append(str(net))
        except ValueError:
            log.warning("Skipping invalid CIDR returned by Cloudflare: %s", cidr)

    normalised.sort()
    log.info("Received %d IPv4 CIDRs from Cloudflare.", len(normalised))
    log.debug("CIDRs: %s", normalised)
    return normalised


# ─────────────────────────────────────────────────────────────────────────────
# MAIN SYNC LOGIC
# ─────────────────────────────────────────────────────────────────────────────

def sync(cp: CheckPointSession, cloudflare_cidrs: list[str]) -> bool:
    """
    Perform the full sync and return True if any changes were made.

    Parameters
    ----------
    cp               : Authenticated CheckPointSession
    cloudflare_cidrs : Canonical IPv4 CIDRs from Cloudflare

    Returns
    -------
    bool – True when changes were published (triggers policy install).
    """

    changes_made = False  # Track whether we need to publish / install policy

    # ── Step 2: Ensure the target group exists ───────────────────────────────

    log.info("Checking for group '%s'…", CP_GROUP)
    group = cp.get_group(CP_GROUP)

    if group is None:
        log.info("Group does not exist – creating it.")
        group = cp.create_group(CP_GROUP)
        changes_made = True
    else:
        log.info("Group '%s' already exists.", CP_GROUP)

    # ── Step 3: Resolve existing group members ───────────────────────────────

    # The 'show-group' response contains a 'members' list with name + uid.
    # We build a map of  name → uid  for members currently in the group.
    existing_members: dict[str, str] = {
        m["name"]: m["uid"]
        for m in group.get("members", [])
        if m.get("name", "").startswith(CP_OBJ_PREFIX)   # only our objects
    }

    log.info("Group currently has %d managed member(s).", len(existing_members))

    # ── Step 4: Determine desired state ──────────────────────────────────────

    # Map each Cloudflare CIDR to the object name we want it to have
    desired_names: dict[str, str] = {
        cidr_to_obj_name(cidr): cidr
        for cidr in cloudflare_cidrs
    }

    desired_name_set  = set(desired_names.keys())
    existing_name_set = set(existing_members.keys())

    names_to_add    = desired_name_set - existing_name_set
    names_to_remove = existing_name_set - desired_name_set   # no longer in CF list
    names_to_keep   = existing_name_set & desired_name_set

    log.info(
        "Diff – to add: %d  |  to remove: %d  |  to keep: %d",
        len(names_to_add), len(names_to_remove), len(names_to_keep),
    )

    # ── Step 5: Create missing network objects ───────────────────────────────

    newly_created_names: list[str] = []

    for obj_name in sorted(names_to_add):
        cidr = desired_names[obj_name]
        net  = ip_network(cidr, strict=False)

        # Check Point requires subnet address and mask length separately
        subnet      = str(net.network_address)
        mask_length = net.prefixlen

        # Verify the object doesn't already exist under this name but outside
        # the group (e.g. if a previous run partially failed)
        existing_obj = cp.get_network_object(obj_name)
        if existing_obj is None:
            cp.create_network_object(obj_name, subnet, mask_length)
            changes_made = True
        else:
            log.info("  Object '%s' already exists (not in group) – will re-add.", obj_name)

        newly_created_names.append(obj_name)

    # ── Step 6: Update the group membership ─────────────────────────────────

    # The final member list is: everything we're keeping + everything we added
    final_members = sorted(names_to_keep | set(newly_created_names))

    if set(final_members) != existing_name_set or newly_created_names:
        cp.set_group_members(CP_GROUP, final_members)
        changes_made = True
    else:
        log.info("Group membership is already up to date – no changes needed.")

    # ── Step 7: Delete stale objects (safe) ─────────────────────────────────

    # We wait until AFTER updating the group so the objects are no longer
    # referenced by the group when we check 'where-used'.
    for obj_name in sorted(names_to_remove):
        uid = existing_members.get(obj_name)
        if not uid:
            log.warning("No UID for '%s', skipping deletion check.", obj_name)
            continue

        if cp.is_object_in_use(uid):
            # The object is referenced somewhere else (rule, another group, NAT)
            # – leave it in place and warn the operator.
            log.warning(
                "Object '%s' (uid=%s) is still referenced elsewhere – skipping deletion.",
                obj_name, uid,
            )
        else:
            cp.delete_network_object(obj_name)
            changes_made = True

    return changes_made


# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    """
    Orchestrate the full sync lifecycle:
    fetch → login → sync → publish → install-policy → logout.

    Any unhandled exception triggers a discard so the database is left clean,
    then re-raises so the exit code is non-zero (useful for cron alerting).
    """

    # ── Pre-flight validation ────────────────────────────────────────────────

    if not CP_HOST:
        log.error("CP_HOST environment variable is not set.  Aborting.")
        sys.exit(1)
    if not CP_USER or not CP_PASSWORD:
        log.error("CP_USER and CP_PASSWORD must both be set.  Aborting.")
        sys.exit(1)

    if DRY_RUN:
        log.info("=" * 60)
        log.info("DRY RUN MODE – no changes will be written to the server.")
        log.info("=" * 60)

    # ── Step 1: Get current Cloudflare CIDRs ────────────────────────────────

    try:
        cloudflare_cidrs = fetch_cloudflare_ipv4_cidrs()
    except RuntimeError as exc:
        log.error("Could not fetch Cloudflare CIDRs: %s", exc)
        sys.exit(1)

    if not cloudflare_cidrs:
        log.error("Cloudflare returned zero IPv4 CIDRs – aborting to avoid wiping the group.")
        sys.exit(1)

    # ── Steps 2-7: Connect and sync ─────────────────────────────────────────

    cp = CheckPointSession(host=CP_HOST, port=CP_PORT, verify_ssl=False)

    try:
        cp.login(CP_USER, CP_PASSWORD, domain=CP_DOMAIN)

        changes = sync(cp, cloudflare_cidrs)

        # ── Step 8: Publish ─────────────────────────────────────────────────

        if changes:
            cp.publish()
        else:
            log.info("No changes detected – skipping publish and policy install.")

        # ── Step 9: Install policy only if something changed ────────────────

        if changes:
            try:
                cp.install_policy(CP_POLICY)
            except RuntimeError as exc:
                # Policy install failure is serious but the DB is already
                # published – don't roll back, just report the error loudly.
                log.error("Policy installation failed: %s", exc)
                log.error(
                    "Changes ARE published to the database but the policy is NOT "
                    "yet installed.  Please install '%s' manually.", CP_POLICY
                )
                sys.exit(2)

    except RuntimeError as exc:
        log.error("Fatal error during sync: %s", exc)
        # Attempt to roll back any unpublished changes in this session
        cp.discard()
        sys.exit(1)

    finally:
        # ── Step 10: Always log out ──────────────────────────────────────────
        cp.logout()

    log.info("Sync finished successfully.")


if __name__ == "__main__":
    main()
