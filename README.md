# Proxmox LXC Autonomous Updater

A Bash script for a Proxmox VE host that discovers running LXC containers, performs Debian-style package updates sequentially and reports a summary locally or to a Discord webhook.

> **Important:** This script makes real changes inside every running container on the host. It runs `apt-get update`, `upgrade`, `dist-upgrade`, `autoremove`, and `clean` inside running containers. `dist-upgrade` and `autoremove` can remove packages; upgrades can change or restart services. It does not run application update helpers. Review it, ensure tested backups are available, and use a maintenance window. There is no dry-run mode or container exclusion list.

## Requirements

- Run on a Proxmox VE host with sufficient privileges to use `pct list` and `pct exec` (typically root).
- Containers must support Bash, `apt-get`, GNU `timeout`, and the utilities used by the update script. It is intended for Debian/Ubuntu-style containers, not arbitrary container distributions.
- Host utilities include Bash, `pct`, `awk`, `mktemp`, `hostname`, `date`, `python3`, `curl`, `head`, and standard coreutils.
- An optional Discord webhook URL; no webhook is needed for a local summary.

## How it works

1. Lists running LXCs on the local Proxmox host; stopped containers are skipped.
2. Obtains each container's hostname and OS description, then runs `apt-get update`, `apt-get upgrade`, `apt-get dist-upgrade`, `apt-get autoremove`, and `apt-get clean` non-interactively, in that order. An update or upgrade failure stops the remaining commands for that container. Existing configuration files are generally kept via the script's dpkg options.
3. Applies a default 300-second timeout to the in-container update command and collects a per-container summary. Hostname and OS discovery occur outside that timeout.
4. An EXIT trap sends the summary to Discord when configured, otherwise prints it locally. Discord content is truncated to 1900 characters; summaries may omit later containers. Abrupt termination (for example SIGKILL or power loss) cannot run the trap.

## Configure and run

1. Review `proxmox_lxc_update.sh` and adjust `UPDATE_TIMEOUT` if needed. For Discord, copy `proxmox_lxc_update.conf.example` to `proxmox_lxc_update.conf` beside the script, replace its contents with the webhook URL on one line, and run `chmod 600 proxmox_lxc_update.conf`. Keep it out of Git in a trusted, non-world-writable directory. The config is read as text, not executed.
2. Make executable: `chmod 750 proxmox_lxc_update.sh`.
3. On the Proxmox host, with backups verified and a maintenance window approved, run as root:

   ```bash
   sudo ./proxmox_lxc_update.sh
   ```

   Without a config file, or with an empty file or the example placeholder, the script prints the summary locally. An unreadable existing config or a missing explicitly specified config stops the script before updates. Set `LXC_UPDATE_CONFIG` to an alternate absolute path if needed; ensure the root process can read it. Rotate an exposed webhook.

## Scheduling

After manual validation, a root crontab entry such as the following runs it every Sunday at 03:00 in the cron host's local time. Replace the path and choose an appropriate maintenance window:

```cron
0 3 * * 0 /root/server-scripts/proxmox_lxc_update.sh >>/var/log/proxmox-lxc-update.log 2>&1
```

Place the private config beside the deployed script (or set `LXC_UPDATE_CONFIG` in root's crontab), and manage log permissions and rotation. Avoid overlapping runs; this script has no locking. Each Proxmox host must be scheduled separately. Test the configuration before unattended use.

## Reporting limitations and safety

- The script checks the exit status of `apt-get update`, `apt-get upgrade`, and `apt-get dist-upgrade` but does not check `autoremove` or `clean` failures; but a successful summary is not proof that services are healthy or that applications using separate update mechanisms are current.
- The `NO_PATCHES` detection searches both upgrade outputs and can misclassify results. Review package logs inside containers for definitive results.
- On a timeout or interrupted update, package management may need manual recovery; check container and dpkg/apt state before retrying.
- The script's summary can be truncated, and Discord/network errors do not necessarily make the overall run fail. Verify delivery and review logs separately.
- `pct list` and other host command failures are not rigorously distinguished from an empty result; independently confirm expected containers were checked.
