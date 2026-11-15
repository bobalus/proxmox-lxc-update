# Proxmox LXC Autonomous Updater

A Bash script that refreshes Proxmox host package lists, reports the number of packages listed as upgradable, updates running LXC containers sequentially, and reports a summary locally or to a Discord webhook. It does not install host package upgrades.

> **Important:** This script makes real changes inside every running container on the host. It runs `apt-get update`, `upgrade`, `dist-upgrade`, `autoremove`, and `clean` inside running containers. `dist-upgrade` and `autoremove` can remove packages; upgrades can change or restart services. It does not run application update helpers. Review it, ensure tested backups are available, and use a maintenance window. There is no dry-run mode or container exclusion list.

## Requirements

- Run on a Proxmox VE host with sufficient privileges to use `pct list` and `pct exec` (typically root).
- Containers must support Bash, `apt-get`, GNU `timeout`, `mktemp`, `tee`, and standard shell utilities. It is intended for Debian/Ubuntu-style containers, not arbitrary container distributions.
- Host utilities include Bash, `apt`, `apt-get`, `timeout`, `pct`, `awk`, `mktemp`, `hostname`, `date`, `python3`, `curl`, and standard coreutils.
- An optional Discord webhook URL; no webhook is needed for a local summary.

## How it works

1. Refreshes host package lists with `apt-get update`, with a 300-second timeout, then counts packages reported by `apt list --upgradable`. No host packages are installed. A failed refresh, including a repository fetch failure, is reported without a potentially stale count; container updates still proceed. The count reflects APT candidates, not a guarantee all packages will be installed by a particular upgrade command.
2. Lists running LXCs on the local Proxmox host; stopped containers are skipped.
3. Obtains each container's hostname and OS description, then runs `apt-get update`, `apt-get upgrade`, `apt-get dist-upgrade`, `apt-get autoremove`, and `apt-get clean` non-interactively, in that order. Any command failure stops the remaining commands for that container. Existing configuration files are generally kept via the script's dpkg options.
4. Applies a default 300-second timeout to the in-container update command and collects a per-container summary, including captured command output on failure. Hostname and OS discovery, `pct list`, and the host upgradable-package listing occur outside that timeout.
5. An EXIT trap sends the full summary to Discord in ordered chunks (up to 1900 UTF-16 units each) when configured, otherwise prints it locally. Failed delivery prints the full report to stderr and sets a nonzero exit status. Discord requests have a 10-second connect and 30-second total timeout per chunk; there is no retry or rate-limit handling. Abrupt termination (for example SIGKILL or power loss) cannot run the trap.

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

- Host refresh/listing failures, enumeration failures, container update failures/timeouts, and webhook delivery failures produce a nonzero overall status. Other containers still run after a host or container failure. Config errors stop before updates.
- Error output may contain sensitive repository details; protect logs and the Discord channel. A successful summary is not proof that services are healthy or that applications using separate update mechanisms are current.
- The `NO_PATCHES` detection searches both upgrade outputs and can misclassify results. Review package logs inside containers for definitive results.
- On a timeout or interrupted update, package management may need manual recovery; check container and dpkg/apt state before retrying. A timed-out `pct exec` or unresponsive host-side call is not independently bounded by the in-container timeout.
- Hostname and OS discovery failures fall back to unknown values and do not fail the run. An empty successful `pct list` result is treated as no running containers.
- Run the isolated mock tests with `python3 -m unittest discover -s tests -v`. Tests substitute `apt`, `apt-get`, `pct`, `timeout`, and `curl`; they do not validate a real Proxmox host or Discord delivery.
