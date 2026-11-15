#!/bin/bash

# --- Ensure Cron has access to Proxmox binaries (like /usr/sbin/pct) ---
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ==============================================================================
# Proxmox LXC Autonomous Updater Script
# ==============================================================================
# This script lists all running LXCs and updates them non-interactively.
# It then sends a summary report to a Discord webhook.
#
# ==============================================================================
# Proxmox LXC Autonomous Updater Script (with OS Version & Timeout Handling)
# ==============================================================================
# This script lists all running LXCs, retrieves their OS version, updates them 
# non-interactively with a safety timeout, and sends a summary report to Discord.
#
# ==============================================================================
# Proxmox LXC Autonomous Updater Script (with OS Version, Timeouts & Safe Trapping)
# ==============================================================================
#
# Recommended cron entry (e.g., run every Sunday at 3 AM):
# 0 3 * * 0 /path/to/proxmox_lxc_update.sh
# ==============================================================================

# --- Configuration ---
# Replace with your actual Discord Webhook URL
# The private config contains only the webhook URL on one line.
# Set LXC_UPDATE_CONFIG to override the default path beside the script.
CONFIG_FILE="${LXC_UPDATE_CONFIG:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/proxmox_lxc_update.conf}"
WEBHOOK_URL=""
if [ -f "$CONFIG_FILE" ]; then
    if [ ! -r "$CONFIG_FILE" ]; then
        echo "Cannot read webhook config: $CONFIG_FILE" >&2
        exit 1
    fi
    IFS= read -r WEBHOOK_URL < "$CONFIG_FILE" || [ -n "$WEBHOOK_URL" ]
elif [ -n "${LXC_UPDATE_CONFIG:-}" ]; then
    echo "Webhook config not found: $CONFIG_FILE" >&2
    exit 1
fi
# Maximum time allowed per container update before timing out (e.g., 300s = 5 minutes)
UPDATE_TIMEOUT="300s"

# --- Script Initialization ---
SUMMARY_FILE=$(mktemp)
PVE_HOSTNAME=$(hostname)
echo "**Proxmox Server: $PVE_HOSTNAME | LXC Update Summary - $(date '+%Y-%m-%d %H:%M:%S')**" > "$SUMMARY_FILE"
echo "----------------------------------------" >> "$SUMMARY_FILE"

# --- Cleanup & Notification Trap ---
# This ensures that even if the script exits early or times out somewhere, 
# the summary file is always sent to Discord before the script terminates.

send_to_discord() {
    echo "----------------------------------------" >> "$SUMMARY_FILE"
    echo "Update process finished." >> "$SUMMARY_FILE"

    if [ -n "$WEBHOOK_URL" ] && [ "$WEBHOOK_URL" != "YOUR_DISCORD_WEBHOOK_URL_HERE" ]; then
        # Truncate content to fit under Discord's 2000 character limit
        SUMMARY_CONTENT=$(cat "$SUMMARY_FILE" | head -c 1900)
        
        # Use Python 3 to safely build the JSON payload (no 'jq' required)
        JSON_PAYLOAD=$(python3 -c 'import json, sys; print(json.dumps({"content": sys.stdin.read()}))' <<< "$SUMMARY_CONTENT")
        
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD" "$WEBHOOK_URL")
        
        if [ "$HTTP_CODE" -eq 204 ] || [ "$HTTP_CODE" -eq 200 ]; then
            echo "Successfully sent summary to Discord."
        else
            echo "Failed to send summary to Discord. HTTP Status: $HTTP_CODE"
        fi
    else
        echo "Discord webhook URL not set or empty. Printing summary locally:"
        cat "$SUMMARY_FILE"
    fi
    rm -f "$SUMMARY_FILE"
}
trap send_to_discord EXIT

# Refresh host package lists without installing host packages. Treat any
# repository fetch failure as a failed refresh rather than reporting stale data.
HOST_APT_TIMEOUT="300s"
echo "Refreshing package lists on Proxmox host..."
if timeout "$HOST_APT_TIMEOUT" apt-get -o APT::Update::Error-Mode=any update >/dev/null 2>&1; then
    HOST_REFRESH_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')
    if HOST_UPGRADABLE=$(LC_ALL=C apt list --upgradable 2>/dev/null); then
        if [[ "$HOST_UPGRADABLE" == Listing* ]]; then
            HOST_COUNT=$(printf '%s\n' "$HOST_UPGRADABLE" | awk 'NR > 1 && NF {n++} END {print n+0}')
            echo "📦 Host APT: Package lists refreshed $HOST_REFRESH_TIME; $HOST_COUNT packages listed as upgradable (none installed on host)." >> "$SUMMARY_FILE"
        else
            echo "⚠️ Host APT: Refreshed $HOST_REFRESH_TIME, but could not interpret upgradable package list." >> "$SUMMARY_FILE"
        fi
    else
        echo "⚠️ Host APT: Refreshed $HOST_REFRESH_TIME, but could not list upgradable packages." >> "$SUMMARY_FILE"
    fi
else
    HOST_APT_STATUS=$?
    echo "⚠️ Host APT: Package list refresh failed or timed out (exit $HOST_APT_STATUS); upgradable package count unavailable." >> "$SUMMARY_FILE"
fi

# Get a list of all running LXC container IDs
RUNNING_LXCS=$(pct list | awk 'NR>1 && /running/ {print $1}')

if [ -z "$RUNNING_LXCS" ]; then
    echo "No running LXC containers found." >> "$SUMMARY_FILE"
else
    for VMID in $RUNNING_LXCS; do
        CT_NAME=$(pct exec "$VMID" -- hostname 2>/dev/null || echo "Unknown")
        CT_OS=$(pct exec "$VMID" -- bash -c 'source /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown OS}" || echo "Unknown OS"' 2>/dev/null)
        [ -z "$CT_OS" ] && CT_OS="Unknown OS"

        echo "Updating LXC: $VMID ($CT_NAME - $CT_OS)..."
        
        UPDATE_SCRIPT=$(cat << 'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null 2>&1 || exit $?
UPGRADE_OUT=$(apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold") || exit $?
DIST_UPGRADE_OUT=$(apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold") || exit $?
apt-get autoremove -y >/dev/null 2>&1
apt-get clean >/dev/null 2>&1

if echo "$UPGRADE_OUT" | grep -q "0 upgraded, 0 newly installed" && echo "$DIST_UPGRADE_OUT" | grep -q "0 upgraded, 0 newly installed"; then
    echo "NO_PATCHES"
else
    echo "PATCHES_APPLIED"
fi
EOF
)

        # Execute with timeout wrapper
        EXEC_OUTPUT=$(pct exec "$VMID" -- timeout "$UPDATE_TIMEOUT" bash -c "$UPDATE_SCRIPT" 2>&1)
        EXEC_STATUS=$?

        if [ $EXEC_STATUS -eq 124 ]; then
            echo "⏱️ LXC $VMID ($CT_NAME) [$CT_OS]: Update timed out after $UPDATE_TIMEOUT (package update or upgrade)." >> "$SUMMARY_FILE"
        elif [ $EXEC_STATUS -eq 0 ]; then
            if echo "$EXEC_OUTPUT" | grep -q "NO_PATCHES"; then
                echo "✅ LXC $VMID ($CT_NAME) [$CT_OS]: Fully updated, no patches applied." >> "$SUMMARY_FILE"
            elif echo "$EXEC_OUTPUT" | grep -q "PATCHES_APPLIED"; then
                echo "✅ LXC $VMID ($CT_NAME) [$CT_OS]: Successfully updated (patches applied)." >> "$SUMMARY_FILE"
            else
                echo "✅ LXC $VMID ($CT_NAME) [$CT_OS]: Successfully updated." >> "$SUMMARY_FILE"
            fi
        else
            echo "❌ LXC $VMID ($CT_NAME) [$CT_OS]: Failed to update (Exit code: $EXEC_STATUS). Check manually." >> "$SUMMARY_FILE"
        fi
    done
fi