#!/usr/bin/env bash
# ==============================================================================
# Debian 13 (trixie) amd64 server initialization script
#
# Goals:
#   1. Reset the initial Debian APT configuration to official Debian repositories.
#   2. Update and full-upgrade the system.
#   3. Install basic administration / operations tools.
#   4. Set timezone to Asia/Shanghai.
#   5. Configure systemd-timesyncd for NTP/SNTP time synchronization.
#   6. Set system locale to C.UTF-8.
#   7. Enable unattended security updates (no automatic reboot).
#   8. Install and enable UFW; allow TCP 22/80/443.
#   9. Run health checks and save all output to a dated report under /root.
#
# Idempotency / extension notes:
#   - Must be run as root; otherwise it exits immediately.
#   - The initial APT source reset happens only once, controlled by a state file
#     under /var/lib/debian13-init. On later runs, private/third-party repositories
#     added after initialization are not deleted. The managed debian.sources file
#     is still refreshed to the official Debian 13 configuration every run.
#   - UFW is NOT reset, so rules added later are preserved.
#   - Configuration files owned by this script are written only when content changes.
#   - Add organization/private software steps in run_custom_steps().
#
# Recommended invocation:
#   chmod +x debian13-init.sh
#   ./debian13-init.sh
# ==============================================================================

set -Eeuo pipefail
umask 022

SCRIPT_VERSION="1.0.0"
EXPECTED_CODENAME="trixie"
EXPECTED_MAJOR_VERSION="13"
EXPECTED_ARCH="amd64"
TIMEZONE="Asia/Shanghai"
LOCALE_VALUE="C.UTF-8"

STATE_DIR="/var/lib/debian13-init"
APT_RESET_STATE="${STATE_DIR}/apt-source-reset.done"
REPORT_DATE="$(TZ="${TIMEZONE}" date +%F 2>/dev/null || date +%F)"
REPORT_FILE="/root/${REPORT_DATE}-debian13-init.txt"
RUN_STARTED_AT="$(TZ="${TIMEZONE}" date --iso-8601=seconds 2>/dev/null || date --iso-8601=seconds)"

# ------------------------------------------------------------------------------
# Root-only guard. Do this before changing anything.
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

mkdir -p "${STATE_DIR}"
touch "${REPORT_FILE}"
chmod 600 "${REPORT_FILE}"

# Mirror stdout/stderr to screen and the dated initialization report.
exec > >(tee -a "${REPORT_FILE}") 2>&1

trap 'echo "[ERROR] line=${LINENO} command=${BASH_COMMAND}"' ERR
on_exit() {
    local rc=$?
    echo
    echo "================================================================================"
    if (( rc == 0 )); then
        echo "Initialization run finished successfully."
    else
        echo "Initialization run FAILED with exit code: ${rc}"
    fi
    echo "Started : ${RUN_STARTED_AT}"
    echo "Finished: $(date --iso-8601=seconds)"
    echo "Report  : ${REPORT_FILE}"
    echo "================================================================================"
}
trap on_exit EXIT

# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------
section() {
    echo
    echo "================================================================================"
    echo "[$(date '+%F %T %z')] $*"
    echo "================================================================================"
}

note() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

# Execute a required command. Because set -e is active, a failure stops the script.
run_cmd() {
    printf '[CMD ] '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

# Execute a health-check command without aborting the initialization if the check
# itself returns non-zero. Its exit code is still recorded in the report.
check_cmd() {
    local rc=0
    printf '\n[CHECK CMD] '
    printf '%q ' "$@"
    printf '\n'
    # Put the command in an if-condition so a non-zero health-check result does
    # not trigger the global ERR trap or abort the initialization.
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc == 0 )); then
        echo "[CHECK RESULT] PASS (exit=${rc})"
    else
        echo "[CHECK RESULT] WARN/FAIL (exit=${rc})"
    fi
    return 0
}

# Write a config file only when its content changes. Content is read from stdin.
write_if_changed() {
    local path="$1"
    local mode="${2:-0644}"
    local tmp
    tmp="$(mktemp)"
    cat > "${tmp}"

    if [[ -f "${path}" ]] && cmp -s "${tmp}" "${path}"; then
        note "Unchanged: ${path}"
        rm -f "${tmp}"
        return 0
    fi

    install -D -m "${mode}" "${tmp}" "${path}"
    rm -f "${tmp}"
    note "Updated: ${path}"
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# ------------------------------------------------------------------------------
# Report header / declared actions
# ------------------------------------------------------------------------------
section "Debian 13 initialization - run header"
echo "Script version : ${SCRIPT_VERSION}"
echo "Report file    : ${REPORT_FILE}"
echo "Run started    : ${RUN_STARTED_AT}"
echo "Expected OS    : Debian ${EXPECTED_MAJOR_VERSION} (${EXPECTED_CODENAME})"
echo "Expected arch  : ${EXPECTED_ARCH}"
echo "Timezone       : ${TIMEZONE}"
echo "Locale         : ${LOCALE_VALUE}"
cat <<'SUMMARY'

Planned actions:
  1. Configure official Debian 13 (trixie) APT repositories.
  2. apt-get update + full-upgrade.
  3. Install base administration and operations packages.
  4. Set Asia/Shanghai timezone.
  5. Configure systemd-timesyncd.
  6. Configure C.UTF-8 locale.
  7. Enable unattended security updates without automatic reboot.
  8. Enable UFW and allow TCP 22, 80 and 443.
  9. Run OS, APT, NTP, locale, firewall, network, disk and systemd checks.
SUMMARY

# ------------------------------------------------------------------------------
# 0. Preconditions - intentionally strict to avoid changing an unexpected system.
# ------------------------------------------------------------------------------
section "0. Preflight checks"

if [[ ! -r /etc/os-release ]]; then
    echo "ERROR: /etc/os-release is missing; refusing to continue." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
ACTUAL_CODENAME="${VERSION_CODENAME:-unknown}"
ACTUAL_VERSION="${VERSION_ID:-unknown}"
ACTUAL_ARCH="$(dpkg --print-architecture)"

echo "Detected: ${PRETTY_NAME:-Debian}"
echo "Codename: ${ACTUAL_CODENAME}"
echo "Version : ${ACTUAL_VERSION}"
echo "Arch    : ${ACTUAL_ARCH}"

if [[ "${ID:-}" != "debian" ]]; then
    echo "ERROR: This script is intended for Debian only." >&2
    exit 1
fi

if [[ "${ACTUAL_CODENAME}" != "${EXPECTED_CODENAME}" ]] || [[ "${ACTUAL_VERSION%%.*}" != "${EXPECTED_MAJOR_VERSION}" ]]; then
    echo "ERROR: Expected Debian 13/trixie, got VERSION_ID=${ACTUAL_VERSION}, VERSION_CODENAME=${ACTUAL_CODENAME}." >&2
    exit 1
fi

if [[ "${ACTUAL_ARCH}" != "${EXPECTED_ARCH}" ]]; then
    echo "ERROR: Expected architecture ${EXPECTED_ARCH}, got ${ACTUAL_ARCH}." >&2
    exit 1
fi

# Debian's official deb822 source uses the Debian archive keyring. A normal
# Debian 13 installation already has it. If it is missing, bootstrap it from
# the currently configured sources before replacing those sources.
if ! package_installed debian-archive-keyring || ! package_installed ca-certificates; then
    warn "debian-archive-keyring and/or ca-certificates is missing; bootstrapping from current APT sources first."
    export DEBIAN_FRONTEND=noninteractive
    run_cmd apt-get update
    run_cmd apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        debian-archive-keyring ca-certificates
fi

if [[ ! -r /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
    echo "ERROR: Debian archive keyring not found at /usr/share/keyrings/debian-archive-keyring.gpg" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. APT repositories
# ------------------------------------------------------------------------------
section "1. Configure official Debian 13 APT repositories"

# On the first run only, save the complete pre-init APT source configuration and
# remove active .list/.sources files. This guarantees that initialization starts
# from Debian's official repositories. After the state marker exists, later
# third-party repository files are preserved on reruns.
if [[ ! -f "${APT_RESET_STATE}" ]]; then
    BACKUP_DIR="/root/debian13-init-backup-$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 "${BACKUP_DIR}/apt"

    if [[ -e /etc/apt/sources.list ]]; then
        cp -a /etc/apt/sources.list "${BACKUP_DIR}/apt/sources.list"
    fi
    if [[ -d /etc/apt/sources.list.d ]]; then
        cp -a /etc/apt/sources.list.d "${BACKUP_DIR}/apt/sources.list.d"
    fi

    note "Original APT source configuration backed up to: ${BACKUP_DIR}/apt"

    cat > /etc/apt/sources.list <<'EOF_APT_LEGACY'
# Managed by debian13-init.sh.
# Debian 13 uses the deb822 source file:
#   /etc/apt/sources.list.d/debian.sources
EOF_APT_LEGACY

    mkdir -p /etc/apt/sources.list.d
    rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources
else
    note "Initial APT source reset was already completed; preserving additional repository files."
fi

# Debian 13 official repositories, pinned by codename (trixie), not "stable".
# All official components are enabled to avoid later package/firmware surprises.
write_if_changed /etc/apt/sources.list.d/debian.sources 0644 <<'EOF_DEBIAN_SOURCES'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF_DEBIAN_SOURCES

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

run_cmd apt-get update
# Mark the destructive first-run source reset complete only after the official
# repositories have successfully passed apt-get update.
touch "${APT_RESET_STATE}"
chmod 600 "${APT_RESET_STATE}"

# ------------------------------------------------------------------------------
# 2. System update / upgrade
# ------------------------------------------------------------------------------
section "2. Update and full-upgrade base system"
run_cmd apt-get full-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

# ------------------------------------------------------------------------------
# 3. Base packages and operations tools
# ------------------------------------------------------------------------------
section "3. Install basic administration and operations tools"

# Keep these arrays easy to extend later.
BASE_PACKAGES=(
    sudo
    ca-certificates
    curl
    wget
    gnupg
    git
    vim
    nano
    less
    jq
    unzip
    zip
    rsync
    tree
    file
    bash-completion
    man-db
)

OPS_PACKAGES=(
    htop
    lsof
    psmisc
    procps
    dnsutils
    iproute2
    iputils-ping
    traceroute
    netcat-openbsd
    tcpdump
    ethtool
    strace
    sysstat
)

SYSTEM_PACKAGES=(
    tzdata
    locales
    systemd-timesyncd
    unattended-upgrades
    ufw
)

run_cmd apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "${BASE_PACKAGES[@]}" \
    "${OPS_PACKAGES[@]}" \
    "${SYSTEM_PACKAGES[@]}"

# ------------------------------------------------------------------------------
# 4. Timezone
# ------------------------------------------------------------------------------
section "4. Configure timezone"
run_cmd timedatectl set-timezone "${TIMEZONE}"
echo "Configured timezone: $(timedatectl show -p Timezone --value)"

# ------------------------------------------------------------------------------
# 5. NTP/SNTP - systemd-timesyncd
# ------------------------------------------------------------------------------
section "5. Configure NTP with systemd-timesyncd"

mkdir -p /etc/systemd/timesyncd.conf.d
write_if_changed /etc/systemd/timesyncd.conf.d/10-debian13-init.conf 0644 <<'EOF_TIMESYNCD'
[Time]
# Debian pool first; vendor-neutral public services are fallbacks.
NTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
FallbackNTP=time.cloudflare.com time.google.com
EOF_TIMESYNCD

run_cmd systemctl enable --now systemd-timesyncd.service
run_cmd timedatectl set-ntp true
run_cmd systemctl restart systemd-timesyncd.service

# Give timesyncd a short opportunity to complete an initial sync. Lack of an
# immediate sync is not fatal; the final health-check records the real status.
for _ in {1..10}; do
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == "yes" ]]; then
        break
    fi
    sleep 2
done

# ------------------------------------------------------------------------------
# 6. Locale
# ------------------------------------------------------------------------------
section "6. Configure system locale"
run_cmd update-locale LANG="${LOCALE_VALUE}"
export LANG="${LOCALE_VALUE}"
export LC_ALL="${LOCALE_VALUE}"
echo "Configured LANG=${LOCALE_VALUE}"

# ------------------------------------------------------------------------------
# 7. Automatic security updates
# ------------------------------------------------------------------------------
section "7. Enable unattended security updates"

# Enable daily metadata refresh and unattended upgrades.
write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF_AUTO_UPGRADES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF_AUTO_UPGRADES

# Debian's package defaults can also permit normal release updates. This later
# config explicitly clears that list and restricts unattended installation to
# Debian Security. Automatic reboot is deliberately disabled.
write_if_changed /etc/apt/apt.conf.d/52debian13-init-unattended-upgrades 0644 <<'EOF_UU'
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOF_UU

run_cmd systemctl enable --now apt-daily.timer
run_cmd systemctl enable --now apt-daily-upgrade.timer

# ------------------------------------------------------------------------------
# 8. UFW firewall
# ------------------------------------------------------------------------------
section "8. Configure UFW firewall"

# IMPORTANT: Do not use "ufw reset" here. Rerunning this script must preserve
# rules that administrators add later.
run_cmd ufw default deny incoming
run_cmd ufw default allow outgoing
run_cmd ufw allow 22/tcp comment 'SSH'
run_cmd ufw allow 80/tcp comment 'HTTP'
run_cmd ufw allow 443/tcp comment 'HTTPS'
run_cmd ufw --force enable

# ------------------------------------------------------------------------------
# 9. Reserved extension point for private/organization-specific initialization
# ------------------------------------------------------------------------------
run_custom_steps() {
    section "9. Private/custom extension steps"
    note "No private/custom steps are configured."

    # Add future commands here. Prefer run_cmd so command + output is included
    # in the initialization report and failures stop the script.
    #
    # Examples:
    #   run_cmd apt-get install -y your-private-package
    #   run_cmd bash /root/private/install-agent.sh
    #   run_cmd systemctl enable --now your-private-service.service
    #
    # If a private repository is required, put it in its own file under:
    #   /etc/apt/sources.list.d/<organization>.sources
    # The script's later reruns will preserve that separate repository file.
}

run_custom_steps

# ------------------------------------------------------------------------------
# 10. Health checks / current-state snapshot
# ------------------------------------------------------------------------------
section "10. Health checks and current system snapshot"

echo "Snapshot time: $(date --iso-8601=seconds)"

section "10.1 OS / kernel / host"
check_cmd cat /etc/os-release
check_cmd uname -a
check_cmd dpkg --print-architecture
check_cmd hostnamectl
check_cmd uptime
check_cmd who -b

section "10.2 APT repositories / package health"
check_cmd cat /etc/apt/sources.list.d/debian.sources
check_cmd apt-get update
check_cmd apt-get check
check_cmd dpkg --audit
check_cmd bash -c "apt list --upgradable 2>/dev/null || true"
check_cmd apt-cache policy base-files

section "10.3 Timezone / NTP"
check_cmd timedatectl
check_cmd timedatectl timesync-status
check_cmd systemctl is-enabled systemd-timesyncd.service
check_cmd systemctl is-active systemd-timesyncd.service
check_cmd cat /etc/systemd/timesyncd.conf.d/10-debian13-init.conf

section "10.4 Locale"
check_cmd cat /etc/locale.conf
check_cmd locale
check_cmd locale -a

section "10.5 Automatic security updates"
check_cmd systemctl is-enabled apt-daily.timer
check_cmd systemctl is-enabled apt-daily-upgrade.timer
check_cmd systemctl list-timers --all apt-daily.timer apt-daily-upgrade.timer
check_cmd bash -c "apt-config dump | grep -E 'APT::Periodic|Unattended-Upgrade::Origins-Pattern|Automatic-Reboot' || true"
check_cmd unattended-upgrade --dry-run

section "10.6 Firewall / listening sockets"
check_cmd ufw status verbose
check_cmd ufw status numbered
check_cmd ss -lntup

section "10.7 Network / DNS / external connectivity"
check_cmd ip -brief address
check_cmd ip route
check_cmd getent ahosts deb.debian.org
check_cmd bash -c "curl -fsSIL --max-time 10 https://deb.debian.org/debian/ | head -n 12"

section "10.8 Memory / disk / swap"
check_cmd free -h
check_cmd df -hT
check_cmd lsblk -o NAME,SIZE,FSTYPE,FSVER,MOUNTPOINTS
check_cmd swapon --show

section "10.9 systemd / logs"
check_cmd systemctl is-system-running
check_cmd systemctl --failed --no-pager
check_cmd journalctl -p err -b --no-pager -n 100

section "10.10 APT history / reboot state"
if [[ -r /var/log/apt/history.log ]]; then
    check_cmd tail -n 120 /var/log/apt/history.log
else
    warn "/var/log/apt/history.log does not exist."
fi

if [[ -f /var/run/reboot-required ]]; then
    echo "[REBOOT] REQUIRED: /var/run/reboot-required exists."
    if [[ -r /var/run/reboot-required.pkgs ]]; then
        echo "Packages requesting reboot:"
        cat /var/run/reboot-required.pkgs
    fi
else
    echo "[REBOOT] Not currently required according to /var/run/reboot-required."
fi

if command -v docker >/dev/null 2>&1; then
    warn "Docker detected. Published Docker ports can interact with/bypass normal UFW expectations; review Docker firewall policy separately."
fi

section "Initialization summary"
cat <<EOF_FINAL
Completed configuration:
  - Debian release/architecture validated: Debian ${EXPECTED_MAJOR_VERSION} ${EXPECTED_CODENAME} / ${EXPECTED_ARCH}
  - Managed Debian source: /etc/apt/sources.list.d/debian.sources
  - System packages updated with apt-get full-upgrade
  - Base administration/operations tools installed
  - Timezone: ${TIMEZONE}
  - NTP service: systemd-timesyncd
  - Locale: ${LOCALE_VALUE}
  - Automatic unattended updates: Debian security updates only
  - Automatic reboot from unattended-upgrades: disabled
  - UFW: enabled, default incoming deny, outgoing allow
  - UFW allowed TCP ports: 22, 80, 443
  - Health checks recorded above

Persistent state directory:
  ${STATE_DIR}

Initialization report:
  ${REPORT_FILE}
EOF_FINAL

exit 0
