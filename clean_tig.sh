#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\e[31m[ERR]\e[0m line $LINENO: $BASH_COMMAND"; exit 1' ERR

WIPE_DOCKER_DATA="${WIPE_DOCKER_DATA:-0}"

log()   { echo -e "\e[32m[LOG]\e[0m $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Run as root: sudo bash $0"
    exit 1
  fi
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    error "Cannot detect OS"
    exit 1
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-unknown}"

  case "$OS_ID" in
    ubuntu|debian) PKG="apt" ;;
    centos|rhel|almalinux|fedora|rocky)
      if command_exists dnf; then PKG="dnf"; else PKG="yum"; fi
      ;;
    alpine) PKG="apk" ;;
    *) error "Unsupported OS: $OS_ID"; exit 1 ;;
  esac

  log "Detected OS=$OS_ID PKG=$PKG"
}

fix_firewalld_backend() {
  if ! command_exists firewall-cmd; then
    return
  fi

  local conf="/etc/firewalld/firewalld.conf"
  if [[ ! -f "$conf" ]]; then
    return
  fi

  local backend
  backend="$(grep -E '^FirewallBackend=' "$conf" | cut -d= -f2 || true)"

  # firewalld valid backend is: nftables or iptables
  if [[ "$backend" == "ipv4" || "$backend" == "ipv6" || -z "$backend" ]]; then
    warn "firewalld backend invalid: '$backend' -> setting to 'nftables'"
    sed -i 's/^FirewallBackend=.*/FirewallBackend=nftables/' "$conf"
    systemctl restart firewalld || true
  fi

  log "firewalld backend: $(firewall-cmd --get-backend 2>/dev/null || echo unknown)"
}

stop_services() {
  log "Stopping docker/containerd services..."
  systemctl stop docker 2>/dev/null || true
  systemctl disable docker 2>/dev/null || true
  systemctl stop containerd 2>/dev/null || true
  systemctl disable containerd 2>/dev/null || true
}

remove_manual_static_files() {
  log "Removing manual/static docker files..."

  # systemd override / manual service
  rm -f /etc/systemd/system/docker.service 2>/dev/null || true
  rm -f /etc/systemd/system/multi-user.target.wants/docker.service 2>/dev/null || true

  # static binaries
  rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/containerd /usr/bin/runc 2>/dev/null || true
  rm -f /usr/bin/containerd-shim* /usr/bin/ctr /usr/bin/docker-init 2>/dev/null || true

  # manual compose plugin
  rm -f /usr/lib/docker/cli-plugins/docker-compose 2>/dev/null || true
  rm -f /usr/bin/docker-compose 2>/dev/null || true

  # config
  rm -rf /etc/docker 2>/dev/null || true

  systemctl daemon-reload 2>/dev/null || true

  log "Manual/static files cleanup done."
}

remove_docker_packages() {
  log "Removing docker packages (if any)..."

  case "$PKG" in
    apt)
      apt remove -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli docker-compose-plugin docker-buildx-plugin 2>/dev/null || true
      apt autoremove -y || true
      ;;
    dnf|yum)
      "$PKG" -y remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine \
        docker-ce docker-ce-cli docker-compose-plugin docker-buildx-plugin containerd.io 2>/dev/null || true
      ;;
    apk)
      apk del docker docker-cli docker-compose containerd runc 2>/dev/null || true
      ;;
  esac

  log "Package removal done."
}

wipe_docker_data_if_requested() {
  if [[ "$WIPE_DOCKER_DATA" == "1" ]]; then
    warn "WIPE_DOCKER_DATA=1 -> Wiping /var/lib/docker and /var/lib/containerd"
    rm -rf /var/lib/docker /var/lib/containerd 2>/dev/null || true
  else
    warn "Keeping docker data. Set WIPE_DOCKER_DATA=1 to wipe."
  fi
}

main() {
  need_root
  detect_os

  # fix firewalld backend for EL10 issue
  fix_firewalld_backend

  stop_services
  remove_manual_static_files
  remove_docker_packages
  wipe_docker_data_if_requested

  log "Cleanup completed ✅"
}

main "$@"
