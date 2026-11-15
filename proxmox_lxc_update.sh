#!/bin/bash
# Proxmox LXC updater: run only on the intended host in a maintenance window.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The optional private config contains only the webhook URL on one line.
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
UPDATE_TIMEOUT="300s"
HOST_APT_TIMEOUT="300s"

SUMMARY_FILE=$(mktemp) || { echo 'Cannot create summary file' >&2; exit 1; }
OVERALL_STATUS=0
PVE_HOSTNAME=$(hostname)
printf '**Proxmox Server: %s | LXC Update Summary - %s**\n----------------------------------------\n' "$PVE_HOSTNAME" "$(date '+%Y-%m-%d %H:%M:%S')" > "$SUMMARY_FILE"

send_to_discord() {
    local initial_status=$? chunk_dir payload code curl_status delivery_failed=0
    trap - EXIT
    [ "$initial_status" -eq 0 ] || OVERALL_STATUS=1
    printf '%s\n' '----------------------------------------' 'Update process finished.' >> "$SUMMARY_FILE"
    if [ -n "$WEBHOOK_URL" ] && [ "$WEBHOOK_URL" != "YOUR_DISCORD_WEBHOOK_URL_HERE" ]; then
        chunk_dir=$(mktemp -d) || delivery_failed=1
        if [ "$delivery_failed" -eq 0 ]; then
            # Split on Unicode characters, not bytes. No text is discarded.
            python3 - "$SUMMARY_FILE" "$chunk_dir" <<'PY'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace')
directory = pathlib.Path(sys.argv[2])
# Count UTF-16 code units conservatively for non-BMP characters.
chunks = []
start = units = 0
for index, char in enumerate(text):
    size = 2 if ord(char) > 0xffff else 1
    if units + size > 1900:
        chunks.append(text[start:index])
        start, units = index, 0
    units += size
chunks.append(text[start:])
for index, chunk in enumerate(chunks):
    (directory / f'{index:08d}.json').write_text(json.dumps({'content': chunk}, ensure_ascii=True), encoding='utf-8')
PY
            [ "$?" -eq 0 ] || delivery_failed=1
        fi
        if [ "$delivery_failed" -eq 0 ]; then
            for payload in "$chunk_dir"/*.json; do
                [ -f "$payload" ] || { delivery_failed=1; break; }
                code=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$(cat "$payload")" "$WEBHOOK_URL")
                curl_status=$?
                if [ "$curl_status" -ne 0 ] || { [ "$code" != 200 ] && [ "$code" != 204 ]; }; then
                    echo "Discord delivery failed (curl exit $curl_status, HTTP ${code:-unavailable})." >&2
                    delivery_failed=1
                fi
            done
        fi
        [ -z "$chunk_dir" ] || rm -rf -- "$chunk_dir"
        if [ "$delivery_failed" -ne 0 ]; then
            OVERALL_STATUS=1
            echo 'Full summary follows because Discord delivery failed:' >&2
            cat "$SUMMARY_FILE" >&2
        else
            echo 'Successfully sent summary to Discord.'
        fi
    else
        echo 'Discord webhook URL not set or empty. Printing summary locally:'
        cat "$SUMMARY_FILE"
    fi
    rm -f -- "$SUMMARY_FILE"
    exit "$OVERALL_STATUS"
}
trap send_to_discord EXIT

# Refresh host lists without installing packages; do not count stale lists.
echo 'Refreshing package lists on Proxmox host...'
if HOST_OUTPUT=$(timeout "$HOST_APT_TIMEOUT" apt-get -o APT::Update::Error-Mode=any update 2>&1); then
    HOST_REFRESH_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')
    HOST_ERR_FILE=$(mktemp) || { echo 'Cannot create host APT error file' >> "$SUMMARY_FILE"; exit 1; }
    if HOST_UPGRADABLE=$(LC_ALL=C apt list --upgradable 2>"$HOST_ERR_FILE"); then
        if [[ "$HOST_UPGRADABLE" == Listing* ]]; then
            HOST_COUNT=$(printf '%s\n' "$HOST_UPGRADABLE" | awk 'NR > 1 && NF {n++} END {print n+0}')
            echo "📦 Host APT: Package lists refreshed $HOST_REFRESH_TIME; $HOST_COUNT packages listed as upgradable (none installed on host)." >> "$SUMMARY_FILE"
        else
            printf '⚠️ Host APT: Could not interpret upgradable package list:\n%s\n' "$HOST_UPGRADABLE" >> "$SUMMARY_FILE"
            OVERALL_STATUS=1
        fi
    else
        status=$?
        printf '⚠️ Host APT: Could not list upgradable packages (exit %s):\n%s\n' "$status" "$HOST_UPGRADABLE" >> "$SUMMARY_FILE"
        cat "$HOST_ERR_FILE" >> "$SUMMARY_FILE"
        OVERALL_STATUS=1
    fi
    rm -f -- "$HOST_ERR_FILE"
else
    status=$?
    printf '⚠️ Host APT: Package list refresh failed or timed out (exit %s); count unavailable:\n%s\n' "$status" "$HOST_OUTPUT" >> "$SUMMARY_FILE"
    OVERALL_STATUS=1
fi

if PCT_LIST=$(pct list 2>&1); then
    RUNNING_LXCS=$(printf '%s\n' "$PCT_LIST" | awk 'NR>1 && $2 == "running" {print $1}')
else
    status=$?
    printf '❌ Failed to enumerate containers (pct list exit %s):\n%s\n' "$status" "$PCT_LIST" >> "$SUMMARY_FILE"
    OVERALL_STATUS=1
    RUNNING_LXCS=''
    ENUMERATION_FAILED=1
fi

if [ -z "$RUNNING_LXCS" ]; then
    [ "${ENUMERATION_FAILED:-0}" -eq 1 ] || echo 'No running LXC containers found.' >> "$SUMMARY_FILE"
else
    for VMID in $RUNNING_LXCS; do
        CT_NAME=$(pct exec "$VMID" -- hostname 2>/dev/null || echo 'Unknown')
        CT_OS=$(pct exec "$VMID" -- bash -c 'source /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown OS}" || echo "Unknown OS"' 2>/dev/null)
        [ -n "$CT_OS" ] || CT_OS='Unknown OS'
        echo "Updating LXC: $VMID ($CT_NAME - $CT_OS)..."
        UPDATE_SCRIPT=$(cat <<'EOF'
export DEBIAN_FRONTEND=noninteractive
APT_LOG=$(mktemp) || { echo 'Cannot create apt output file' >&2; exit 1; }
trap 'rm -f -- "$APT_LOG"' EXIT
run_apt() {
    local status
    apt-get "$@" 2>&1 | tee "$APT_LOG"
    status=${PIPESTATUS[0]}
    if [ "$status" -ne 0 ]; then
        printf 'apt-get %s failed (exit %s)\n' "$*" "$status" >&2
        exit "$status"
    fi
    APT_OUTPUT=$(cat "$APT_LOG")
}
run_apt update
run_apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
UPGRADE_OUT=$APT_OUTPUT
run_apt dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
DIST_UPGRADE_OUT=$APT_OUTPUT
run_apt autoremove -y
run_apt clean
if echo "$UPGRADE_OUT" | grep -q '0 upgraded, 0 newly installed' && echo "$DIST_UPGRADE_OUT" | grep -q '0 upgraded, 0 newly installed'; then
    echo NO_PATCHES
else
    echo PATCHES_APPLIED
fi
EOF
)
        if EXEC_OUTPUT=$(pct exec "$VMID" -- timeout "$UPDATE_TIMEOUT" bash -c "$UPDATE_SCRIPT" 2>&1); then
            if [[ "$EXEC_OUTPUT" == *NO_PATCHES* ]]; then
                echo "✅ LXC $VMID ($CT_NAME) [$CT_OS]: Fully updated, no patches applied." >> "$SUMMARY_FILE"
            elif [[ "$EXEC_OUTPUT" == *PATCHES_APPLIED* ]]; then
                echo "✅ LXC $VMID ($CT_NAME) [$CT_OS]: Successfully updated (patches applied)." >> "$SUMMARY_FILE"
            else
                echo "✅ LXC $VMID ($CT_NAME) [$CT_OS]: Successfully updated." >> "$SUMMARY_FILE"
            fi
        else
            status=$?
            OVERALL_STATUS=1
            if [ "$status" -eq 124 ]; then
                printf '⏱️ LXC %s (%s) [%s]: Update timed out after %s (exit %s).\n' "$VMID" "$CT_NAME" "$CT_OS" "$UPDATE_TIMEOUT" "$status" >> "$SUMMARY_FILE"
            else
                printf '❌ LXC %s (%s) [%s]: Failed to update (exit %s).\n' "$VMID" "$CT_NAME" "$CT_OS" "$status" >> "$SUMMARY_FILE"
            fi
            [ -z "$EXEC_OUTPUT" ] || printf 'Command output:\n%s\n' "$EXEC_OUTPUT" >> "$SUMMARY_FILE"
        fi
    done
fi
exit "$OVERALL_STATUS"
