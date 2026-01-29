#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\e[31m[ERR]\e[0m line $LINENO: $BASH_COMMAND"; exit 1' ERR

# ===========================================================
# GLOBAL CONFIGURATION
# ===========================================================
NETWORK_NAME="tig-network"

# ===========================================================
# GLOBAL VARIABLES
# ===========================================================
OS_ID=""
PKG_MGR=""
INIT_SYSTEM=""
INFLUX_TOKEN=""
SELINUX_ENFORCING="0"

# รับค่าที่กรอกเพื่อเอาไปใช้ใน docker-compose (init org/bucket)
INFLUX_ORG=""
INFLUX_BUCKET=""

# ===========================================================
# UTILITY FUNCTIONS
# ===========================================================
log()   { echo -e "\e[32m[LOG]\e[0m $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "This script must be run as root. Try using sudo."
    exit 1
  fi
}

create_folder() {
  local dir="$1"
  [[ -d "$dir" ]] || mkdir -p "$dir"
}

# ===========================================================
# DETECT OS / PKG / INIT
# ===========================================================
detect_os() {
  OS_ID=""
  PKG_MGR=""
  INIT_SYSTEM=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    error "Cannot detect OS (missing /etc/os-release)"
    exit 1
  fi

  if command_exists systemctl; then
    INIT_SYSTEM="systemd"
  elif command_exists rc-service; then
    INIT_SYSTEM="openrc"
  else
    error "Unsupported init system"
    exit 1
  fi

  case "$OS_ID" in
    ubuntu|debian) PKG_MGR="apt" ;;
    centos|rhel|almalinux|fedora|rocky)
      if command_exists dnf; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
      ;;
    alpine) PKG_MGR="apk" ;;
    *) error "Unsupported OS: $OS_ID"; exit 1 ;;
  esac

  log "Detected OS=$OS_ID | PKG_MGR=$PKG_MGR | INIT_SYSTEM=$INIT_SYSTEM"
}

# ===========================================================
# SELINUX DETECTION
# ===========================================================
detect_selinux() {
  if command_exists getenforce; then
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    if [[ "$mode" == "Enforcing" ]]; then
      SELINUX_ENFORCING="1"
      warn "SELinux is Enforcing. Bind mounts should use :Z."
    else
      SELINUX_ENFORCING="0"
      log "SELinux mode: $mode"
    fi
  else
    SELINUX_ENFORCING="0"
  fi
}

# ===========================================================
# REQUIRED KERNEL + SYSCTL (SAFE FOR DOCKER ON RHEL-BASED)
# ===========================================================
enable_kernel_modules_for_docker() {
  log "Enabling kernel modules + sysctl needed for Docker networking..."

  modprobe br_netfilter 2>/dev/null || true
  modprobe nf_nat 2>/dev/null || true
  modprobe overlay 2>/dev/null || true
  modprobe bridge 2>/dev/null || true

  cat >/etc/modules-load.d/docker.conf <<EOF
br_netfilter
nf_nat
overlay
bridge
EOF

  cat >/etc/sysctl.d/99-docker.conf <<EOF
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

  sysctl --system >/dev/null 2>&1 || true
  log "sysctl net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo N/A)"
}

# ===========================================================
# FIX FIREWALLD BACKEND (EL10/RHEL10 ISSUE)
# ===========================================================
fix_firewalld_backend_if_needed() {
  if ! command_exists firewall-cmd; then
    return
  fi

  local conf="/etc/firewalld/firewalld.conf"
  if [[ -f "$conf" ]]; then
    local backend
    backend="$(grep -E '^FirewallBackend=' "$conf" | cut -d= -f2 || true)"

    if [[ "$backend" == "ipv4" || "$backend" == "ipv6" || -z "$backend" ]]; then
      warn "firewalld backend invalid: $backend -> set to nftables"
      sed -i 's/^FirewallBackend=.*/FirewallBackend=nftables/' "$conf"
      systemctl restart firewalld || true
    fi
  fi
}

# ===========================================================
# INSTALL DOCKER (REPO METHOD)
# ===========================================================
install_docker_repo() {
  if command_exists docker; then
    log "Docker already installed. Skipping."
    return
  fi

  case "$PKG_MGR" in
    apt)
      install_docker_apt
      ;;
    dnf|yum)
      install_docker_rhel
      ;;
    apk)
      install_docker_alpine
      ;;
    *)
      error "Unsupported PKG_MGR: $PKG_MGR"
      exit 1
      ;;
  esac
}

install_docker_apt() {
  log "Installing Docker via APT (official Docker repo)..."

  apt update -y
  apt install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${codename} stable
EOF

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log "Docker installed successfully (APT)."
}

install_docker_rhel() {
  log "Installing Docker via DNF/YUM (official Docker repo)..."

  "$PKG_MGR" -y install yum-utils ca-certificates curl
  "$PKG_MGR" config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  "$PKG_MGR" -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin container-selinux

  systemctl enable --now docker
  log "Docker installed successfully (RHEL repo)."
}

install_docker_alpine() {
  log "Installing Docker via APK (Alpine)..."

  apk update
  apk add --no-cache docker docker-cli docker-compose containerd runc

  rc-update add docker default
  service docker start

  log "Docker installed successfully (Alpine)."
}

# ===========================================================
# ADD USER TO DOCKER GROUP
# ===========================================================
add_user_to_docker_group() {
  if ! getent group docker >/dev/null 2>&1; then
    groupadd docker || true
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    usermod -aG docker "${SUDO_USER}" || true
    log "Added user ${SUDO_USER} to docker group"
    warn "Logout/login again or run: newgrp docker"
  fi
}

# ===========================================================
# VERIFY DOCKER
# ===========================================================
verify_docker() {
  log "Verifying Docker..."
  unset DOCKER_HOST || true
  docker version
  docker compose version
  log "Docker verification OK."
}

# ===========================================================
# FIX PERMISSIONS FOR BIND MOUNTS (GRAFANA/INFLUXDB)
# ===========================================================
fix_bind_mount_permissions() {
  log "Fixing bind mount directory permissions..."

  # Grafana official image runs as UID/GID 472
  if [[ -d grafana-data ]]; then
    chown -R 472:472 grafana-data || true
    chmod -R 755 grafana-data || true
  fi

  # InfluxDB v2 commonly uses UID/GID 1000
  if [[ -d influxdb ]]; then
    chown -R 1000:1000 influxdb || true
    chmod -R 755 influxdb || true
  fi

  log "Permissions fixed."
}

# ===========================================================
# TIG STACK GENERATION
# ===========================================================
generate_env_files() {
  log "Generating InfluxDB secret files..."

  local token_file=".env.influxdb-admin-token"
  local user_file=".env.influxdb-admin-username"
  local pass_file=".env.influxdb-admin-password"

  if [[ ! -f "$token_file" ]]; then
    INFLUX_TOKEN="$(openssl rand -hex 32)"
    echo "$INFLUX_TOKEN" > "$token_file"
    chmod 600 "$token_file"
    log "Generated token file: $token_file"
  else
    INFLUX_TOKEN="$(cat "$token_file")"
    log "Using existing token file: $token_file"
  fi

  if [[ ! -f "$user_file" ]]; then
    read -rp "InfluxDB admin username: " admuser
    echo "$admuser" > "$user_file"
    chmod 600 "$user_file"
  fi

  if [[ ! -f "$pass_file" ]]; then
    read -srp "InfluxDB admin password: " admpass
    echo
    echo "$admpass" > "$pass_file"
    chmod 600 "$pass_file"
  fi
}

generate_telegraf_config() {
  create_folder "telegraf-config/telegraf.d"

  if [[ ! -f telegraf-config/telegraf.conf ]]; then
    cat > telegraf-config/telegraf.conf <<EOF
[agent]
  interval = "30s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  flush_interval = "10s"
  precision = "0s"
EOF
  fi

  # โหลดค่าเดิม (ถ้ามี) เพื่อเอามาเป็น default ตอนถาม
  local envfile=".env.tig"
  if [[ -f "$envfile" ]]; then
    # shellcheck disable=SC1090
    source "$envfile" || true
  fi

  read -rp "Organization Name [${INFLUX_ORG:-AskMe}]: " ORG_IN
  read -rp "Bucket Name [${INFLUX_BUCKET:-askme2u}]: " BUCKET_IN

  INFLUX_ORG="${ORG_IN:-${INFLUX_ORG:-AskMe}}"
  INFLUX_BUCKET="${BUCKET_IN:-${INFLUX_BUCKET:-askme2u}}"

  # เขียน .env.tig เพื่อให้ docker compose ใช้ค่าเดียวกัน
  cat > "$envfile" <<EOF
INFLUX_ORG=${INFLUX_ORG}
INFLUX_BUCKET=${INFLUX_BUCKET}
EOF
  chmod 600 "$envfile"

  local token
  token="$(cat .env.influxdb-admin-token)"

  cat > telegraf-config/telegraf.d/000-influxdb.conf <<EOF
[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "${token}"
  organization = "${INFLUX_ORG}"
  bucket = "${INFLUX_BUCKET}"
EOF
}

generate_docker_compose() {

  if [[ -f docker-compose.yml ]]; then
    log "docker-compose.yml already exists. Skipping generation."
    return
  fi

  # If SELinux enforcing -> add :Z to bind mounts
  local ZOPT=""
  if [[ "$SELINUX_ENFORCING" == "1" ]]; then
    ZOPT=":Z"
  fi

  cat > docker-compose.yml <<EOF
services:
  influxdb:
    image: influxdb:latest
    container_name: influxdb
    ports:
      - "8086:8086"
    env_file:
      - .env.tig
    environment:
      - INFLUXDB_HTTP_AUTH_ENABLED=true
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME_FILE=/run/secrets/influxdb-admin-username
      - DOCKER_INFLUXDB_INIT_PASSWORD_FILE=/run/secrets/influxdb-admin-password
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN_FILE=/run/secrets/influxdb-admin-token
      - DOCKER_INFLUXDB_INIT_ORG=\${INFLUX_ORG}
      - DOCKER_INFLUXDB_INIT_BUCKET=\${INFLUX_BUCKET}
    secrets:
      - influxdb-admin-token
      - influxdb-admin-username
      - influxdb-admin-password
    volumes:
      - ./influxdb/data:/var/lib/influxdb2${ZOPT}
      - ./influxdb/config:/etc/influxdb2${ZOPT}
    restart: unless-stopped

  grafana:
    image: grafana/grafana-oss:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - ./grafana-data:/var/lib/grafana${ZOPT}
    depends_on:
      - influxdb
    restart: unless-stopped

  telegraf:
    image: telegraf:latest
    container_name: telegraf
    volumes:
      - ./telegraf-config/telegraf.d:/etc/telegraf/telegraf.d/:ro${ZOPT}
      - ./telegraf-config/telegraf.conf:/etc/telegraf.conf:ro${ZOPT}
    depends_on:
      - influxdb
    restart: unless-stopped

secrets:
  influxdb-admin-token:
    file: .env.influxdb-admin-token
  influxdb-admin-username:
    file: .env.influxdb-admin-username
  influxdb-admin-password:
    file: .env.influxdb-admin-password

networks:
  default:
    name: ${NETWORK_NAME}
EOF
}

prepare_data_dirs() {
  log "Preparing data directories..."
  create_folder influxdb/data
  create_folder influxdb/config
  create_folder grafana-data

  fix_bind_mount_permissions
}

run_stack() {
  log "Starting TIG stack using Docker Compose..."
  docker compose up -d
  log "TIG stack is up and running."
}

get_local_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  [[ -n "$ip" ]] && echo "$ip" || echo "127.0.0.1"
}

prompt_influx_credentials() {
  local user_file=".env.influxdb-admin-username"
  local pass_file=".env.influxdb-admin-password"
  local token_file=".env.influxdb-admin-token"

  # username
  if [[ ! -s "$user_file" ]]; then
    read -rp "InfluxDB admin username: " admuser
    echo "$admuser" > "$user_file"
    chmod 600 "$user_file"
  fi

  # password
  if [[ ! -s "$pass_file" ]]; then
    read -srp "InfluxDB admin password: " admpass
    echo
    echo "$admpass" > "$pass_file"
    chmod 600 "$pass_file"
  fi

  # token
  if [[ ! -s "$token_file" ]]; then
    INFLUX_TOKEN="$(openssl rand -hex 32)"
    echo "$INFLUX_TOKEN" > "$token_file"
    chmod 600 "$token_file"
  fi
}

setup_influx() {
  log "Setting up InfluxDB initial configuration..."

  # ensure user/password/token exists and not empty
  prompt_influx_credentials

  local user pass token org bucket
  user="$(cat .env.influxdb-admin-username)"
  pass="$(cat .env.influxdb-admin-password)"
  token="$(cat .env.influxdb-admin-token)"

  # ดึง org/bucket จากไฟล์ telegraf ที่เราสร้าง (ต้องมีอยู่แล้ว)
  org="$(grep -E '^\s*organization\s*=' telegraf-config/telegraf.d/000-influxdb.conf | sed -E 's/.*=\s*"([^"]+)".*/\1/')"
  bucket="$(grep -E '^\s*bucket\s*=' telegraf-config/telegraf.d/000-influxdb.conf | sed -E 's/.*=\s*"([^"]+)".*/\1/')"

  # wait until influxdb is ready
  local retries=60
  for ((i=1; i<=retries; i++)); do
    if curl -fsS http://localhost:8086/health | grep -q '"status":"pass"'; then
      break
    fi
    sleep 2
  done

  docker exec -i influxdb influx setup \
    --username "$user" \
    --password "$pass" \
    --org "$org" \
    --bucket "$bucket" \
    --token "$token" \
    --force || true

  local ip
  ip="$(get_local_ip)"
  log "InfluxDB setup completed."
  log "InfluxDB URL: http://$ip:8086"
  log "Grafana URL:  http://$ip:3000"
}

# ===========================================================
# MAIN SCRIPT EXECUTION (DOCKER-REPO-FIRST)
# ===========================================================
main() {
  need_root
  detect_os
  detect_selinux

  enable_kernel_modules_for_docker
  fix_firewalld_backend_if_needed
  install_docker_repo

  add_user_to_docker_group
  verify_docker

  generate_env_files
  # ต้องถาม/เซ็ต ORG/BUCKET ก่อน เพื่อให้ docker-compose ใช้ค่าที่กรอกได้
  generate_telegraf_config
  generate_docker_compose

  prepare_data_dirs

  run_stack
  setup_influx

  log "TIG stack installation and setup completed successfully."
}

main "$@"
