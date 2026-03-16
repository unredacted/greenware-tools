#!/bin/bash
# =============================================================================
# GreenWare Fleet Verification
# =============================================================================
# Check the online status of provisioned Raspberry Pi units on your tailnet.
# Uses tailscale ping and/or tailscale status to verify connectivity.
#
# Usage:
#   ./verify-fleet.sh [path-to-config.env]
#
# Part of: https://github.com/unredacted/greenware-tools
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Load Config -------------------------------------------------------------

CONFIG_FILE="${1:-${REPO_ROOT}/provisioning/config.env}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Usage: $0 [path-to-config.env]"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

for var in HOSTNAME_PREFIX HOSTNAME_SUFFIX HOSTNAME_START HOSTNAME_END; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable $var is not set in $CONFIG_FILE"
        exit 1
    fi
done

# --- Check Prerequisites -----------------------------------------------------

if ! command -v tailscale &>/dev/null; then
    echo "ERROR: tailscale CLI not found."
    echo "Install with: brew install tailscale (macOS) or curl -fsSL https://tailscale.com/install.sh | sh"
    exit 1
fi

# --- Verify Fleet ------------------------------------------------------------

TOTAL=$(( HOSTNAME_END - HOSTNAME_START + 1 ))
ONLINE=0
OFFLINE=0
TIMEOUT_SECS=5

echo "============================================"
echo "GreenWare Fleet Verification"
echo "============================================"
echo "  Range:   ${HOSTNAME_PREFIX}${HOSTNAME_START}${HOSTNAME_SUFFIX}"
echo "           through"
echo "           ${HOSTNAME_PREFIX}${HOSTNAME_END}${HOSTNAME_SUFFIX}"
echo "  Total:   ${TOTAL} units"
echo "  Timeout: ${TIMEOUT_SECS}s per host"
echo "============================================"
echo ""

OFFLINE_HOSTS=()

for i in $(seq "$HOSTNAME_START" "$HOSTNAME_END"); do
    HOST="${HOSTNAME_PREFIX}${i}${HOSTNAME_SUFFIX}"

    if tailscale ping --c 1 --timeout="${TIMEOUT_SECS}s" "$HOST" &>/dev/null 2>&1; then
        echo "  ✅ ${HOST}"
        ONLINE=$((ONLINE + 1))
    else
        echo "  ❌ ${HOST}"
        OFFLINE=$((OFFLINE + 1))
        OFFLINE_HOSTS+=("$HOST")
    fi
done

# --- Summary -----------------------------------------------------------------

echo ""
echo "============================================"
echo "Results"
echo "============================================"
echo "  Online:  ${ONLINE}/${TOTAL}"
echo "  Offline: ${OFFLINE}/${TOTAL}"

if [ ${#OFFLINE_HOSTS[@]} -gt 0 ]; then
    echo ""
    echo "Offline hosts:"
    for host in "${OFFLINE_HOSTS[@]}"; do
        echo "  - ${host}"
    done
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check if the Pi has power and network connectivity"
    echo "  2. SSH into the Pi (if reachable) and check cloud-init status:"
    echo "     cloud-init status --long"
    echo "  3. Check cloud-init logs: /boot/firmware/cloud-init-output.log"
    echo "  4. Check Tailscale status: tailscale status"
    echo "  5. Verify on Headscale: headscale nodes list"
fi

echo "============================================"

# Exit with non-zero if any hosts are offline
if [ "$OFFLINE" -gt 0 ]; then
    exit 1
fi
