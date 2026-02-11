#!/bin/sh
set -eu

# ----------------------------
# CONFIG (defaults)
# ----------------------------
HOMELAB_DIR="${HOMELAB_DIR:-/home/homelab}"
HOMELAB_DATA_DIR="${HOMELAB_DATA_DIR:-/home/homelab_data}"
DATA_DIR="${DATA_DIR:-/home/data}"

# Host-exposed ports (must stay in 8060-8069)
PORT_SEAFILE=8060
PORT_BENTOPDF=8061
PORT_ITTOOLS=8062
PORT_FRESHRSS=8063
PORT_IMMICH=8064
PORT_JOPLIN=8065
PORT_PAPERLESS=8066
PORT_N8N=8067
PORT_ONLYOFFICE=8068

log() { printf "%s\n" "$*"; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Zaženi kot root (npr. sudo ./install.sh)"
}

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
    return
  fi
  echo "unknown"
}

start_docker_service() {
  if have systemctl; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
  elif have service; then
    service docker start >/dev/null 2>&1 || true
  elif have rc-service; then
    rc-service docker start >/dev/null 2>&1 || true
  fi
}

install_docker_apt() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg openssl

  # Install Docker Engine + Compose plugin from Docker's official repo
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [ -n "$codename" ] || codename="$(lsb_release -cs 2>/dev/null || echo "")"
  [ -n "$codename" ] || die "Ne morem ugotovit Ubuntu/Debian codename."

  if ! grep -q "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    echo \
"deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list
  fi

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_apk() {
  apk update
  apk add --no-cache docker docker-cli-compose curl ca-certificates openssl
  if have rc-update; then
    rc-update add docker default >/dev/null 2>&1 || true
  fi
}

ensure_docker_installed() {
  if have docker; then
    return 0
  fi

  os_id="$(detect_os)"
  log "[*] Docker ni nameščen. Nameščam za OS: ${os_id}"

  if have apt-get; then
    install_docker_apt
  elif have apk; then
    install_docker_apk
  else
    die "Ne podpiram tega package managerja (rabim apt-get ali apk)."
  fi
}

pick_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif have docker-compose; then
    echo "docker-compose"
  else
    die "Ni najden Docker Compose (docker compose / docker-compose)."
  fi
}

detect_host_ip() {
  # MUST return exactly one line (no newlines), otherwise sed replacements break.
  if have ip; then
    ipaddr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    [ -n "$ipaddr" ] && { printf "%s\n" "$ipaddr"; return; }
  fi

  if have hostname; then
    ipaddr="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$ipaddr" ] && { printf "%s\n" "$ipaddr"; return; }
  fi

  printf "127.0.0.1\n"
}

rand_alnum_32() {
  # A-Za-z0-9 only (good for Immich DB_PASSWORD recommendation)
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
}

rand_hex_32() {
  openssl rand -hex 32
}

ensure_env_kv() {
  key="$1"
  val="$2"
  envfile="$3"

  # safety: strip newlines (sed replacement can't handle raw newlines)
  val="$(printf "%s" "$val" | tr '\n' ' ')"

  # escape for sed replacement: backslash, | and &
  esc_val="$(printf "%s" "$val" | sed 's/[\\|&]/\\&/g')"

  if grep -q "^${key}=" "$envfile" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${esc_val}|" "$envfile"
  else
    printf "%s=%s\n" "$key" "$val" >> "$envfile"
  fi
}

make_dirs_and_perms() {
  target_user="${SUDO_USER:-$(whoami)}"
  target_uid="$(id -u "$target_user" 2>/dev/null || echo 0)"
  target_gid="$(id -g "$target_user" 2>/dev/null || echo 0)"

  mkdir -p "$HOMELAB_DIR" "$HOMELAB_DATA_DIR" "$DATA_DIR"

  mkdir -p \
    "$HOMELAB_DATA_DIR/seafile/mysql" \
    "$HOMELAB_DATA_DIR/seafile/data" \
    "$HOMELAB_DATA_DIR/bentopdf" \
    "$HOMELAB_DATA_DIR/it-tools" \
    "$HOMELAB_DATA_DIR/freshrss/config" \
    "$HOMELAB_DATA_DIR/freshrss/extensions" \
    "$HOMELAB_DATA_DIR/immich/library" \
    "$HOMELAB_DATA_DIR/immich/postgres" \
    "$HOMELAB_DATA_DIR/immich/model-cache" \
    "$HOMELAB_DATA_DIR/immich/redis" \
    "$HOMELAB_DATA_DIR/joplin/postgres" \
    "$HOMELAB_DATA_DIR/paperless/data" \
    "$HOMELAB_DATA_DIR/paperless/media" \
    "$HOMELAB_DATA_DIR/paperless/consume" \
    "$HOMELAB_DATA_DIR/paperless/export" \
    "$HOMELAB_DATA_DIR/paperless/postgres" \
    "$HOMELAB_DATA_DIR/paperless/redis" \
    "$HOMELAB_DATA_DIR/n8n/data" \
    "$HOMELAB_DATA_DIR/n8n/files" \
    "$HOMELAB_DATA_DIR/onlyoffice/logs" \
    "$HOMELAB_DATA_DIR/onlyoffice/data" \
    "$HOMELAB_DATA_DIR/onlyoffice/lib" \
    "$HOMELAB_DATA_DIR/onlyoffice/postgres"

  chmod 755 "$HOMELAB_DIR" "$HOMELAB_DATA_DIR" "$DATA_DIR" || true
  chown -R "$target_uid:$target_gid" "$HOMELAB_DIR" "$HOMELAB_DATA_DIR" "$DATA_DIR" || true

  # Postgres dirs (many images run as uid 999)
  for d in \
    "$HOMELAB_DATA_DIR/joplin/postgres" \
    "$HOMELAB_DATA_DIR/paperless/postgres" \
    "$HOMELAB_DATA_DIR/immich/postgres" \
    "$HOMELAB_DATA_DIR/onlyoffice/postgres"
  do
    chown -R 999:999 "$d" || true
    chmod 700 "$d" || true
  done

# MariaDB/MySQL dirs (often uid 999)
for d in     "$HOMELAB_DATA_DIR/seafile/mysql"
do
  chown -R 999:999 "$d" || true
  chmod 700 "$d" || true
done

  # Redis/Valkey dirs
  for d in \
    "$HOMELAB_DATA_DIR/paperless/redis" \
    "$HOMELAB_DATA_DIR/immich/redis"
  do
    chown -R 999:999 "$d" || true
    chmod 770 "$d" || true
  done
}

write_env() {
  envfile="$HOMELAB_DIR/.env"
  touch "$envfile"

  target_user="${SUDO_USER:-$(whoami)}"
  target_uid="$(id -u "$target_user" 2>/dev/null || echo 0)"
  target_gid="$(id -g "$target_user" 2>/dev/null || echo 0)"

  host_ip="$(detect_host_ip)"

  tz_default="${TZ:-Europe/Ljubljana}"

  # secrets (only generate if missing)
  if ! grep -q '^DB_PASSWORD=' "$envfile" 2>/dev/null; then
    ensure_env_kv "DB_PASSWORD" "$(rand_alnum_32)" "$envfile"
  fi
  if ! grep -q '^PAPERLESS_DB_PASSWORD=' "$envfile" 2>/dev/null; then
    ensure_env_kv "PAPERLESS_DB_PASSWORD" "$(rand_alnum_32)" "$envfile"
  fi
  if ! grep -q '^PAPERLESS_SECRET_KEY=' "$envfile" 2>/dev/null; then
    ensure_env_kv "PAPERLESS_SECRET_KEY" "$(rand_hex_32)" "$envfile"
  fi
  if ! grep -q '^N8N_ENCRYPTION_KEY=' "$envfile" 2>/dev/null; then
    ensure_env_kv "N8N_ENCRYPTION_KEY" "$(rand_hex_32)" "$envfile"
  fi
  if ! grep -q '^JOPLIN_DB_PASSWORD=' "$envfile" 2>/dev/null; then
    ensure_env_kv "JOPLIN_DB_PASSWORD" "$(rand_alnum_32)" "$envfile"
  fi
  if ! grep -q '^ONLYOFFICE_JWT_SECRET=' "$envfile" 2>/dev/null; then
    ensure_env_kv "ONLYOFFICE_JWT_SECRET" "$(rand_hex_32)" "$envfile"
  fi
# Seafile
if ! grep -q '^SEAFILE_MYSQL_ROOT_PASSWORD=' "$envfile" 2>/dev/null; then
  ensure_env_kv "SEAFILE_MYSQL_ROOT_PASSWORD" "$(rand_alnum_32)" "$envfile"
fi
if ! grep -q '^SEAFILE_ADMIN_PASSWORD=' "$envfile" 2>/dev/null; then
  ensure_env_kv "SEAFILE_ADMIN_PASSWORD" "$(rand_alnum_32)" "$envfile"
fi


  # common
  ensure_env_kv "TZ" "$tz_default" "$envfile"
  ensure_env_kv "PUID" "$target_uid" "$envfile"
  ensure_env_kv "PGID" "$target_gid" "$envfile"
  ensure_env_kv "USERMAP_UID" "$target_uid" "$envfile"
  ensure_env_kv "USERMAP_GID" "$target_gid" "$envfile"
# Seafile
ensure_env_kv "SEAFILE_ADMIN_EMAIL" "${SEAFILE_ADMIN_EMAIL:-admin@local}" "$envfile"
ensure_env_kv "SEAFILE_SERVER_HOSTNAME" "${SEAFILE_SERVER_HOSTNAME:-${host_ip}:${PORT_SEAFILE}}" "$envfile"


  # Immich
  ensure_env_kv "IMMICH_VERSION" "${IMMICH_VERSION:-release}" "$envfile"
  ensure_env_kv "UPLOAD_LOCATION" "$HOMELAB_DATA_DIR/immich/library" "$envfile"
  ensure_env_kv "DB_DATA_LOCATION" "$HOMELAB_DATA_DIR/immich/postgres" "$envfile"
  ensure_env_kv "DB_USERNAME" "postgres" "$envfile"
  ensure_env_kv "DB_DATABASE_NAME" "immich" "$envfile"
  ensure_env_kv "DB_HOSTNAME" "immich_postgres" "$envfile"
  ensure_env_kv "DB_PORT" "5432" "$envfile"
  ensure_env_kv "REDIS_HOSTNAME" "immich_redis" "$envfile"
  ensure_env_kv "REDIS_PORT" "6379" "$envfile"

  # Joplin
  ensure_env_kv "JOPLIN_DB_NAME" "joplin" "$envfile"
  ensure_env_kv "JOPLIN_DB_USER" "joplin" "$envfile"
  ensure_env_kv "JOPLIN_BASE_URL" "http://${host_ip}:${PORT_JOPLIN}" "$envfile"

  # Paperless
  ensure_env_kv "PAPERLESS_URL" "http://${host_ip}:${PORT_PAPERLESS}" "$envfile"
  ensure_env_kv "PAPERLESS_TIME_ZONE" "$tz_default" "$envfile"
  ensure_env_kv "PAPERLESS_OCR_LANGUAGE" "${PAPERLESS_OCR_LANGUAGE:-eng}" "$envfile"

  # n8n
  ensure_env_kv "N8N_HOST" "${N8N_HOST:-$host_ip}" "$envfile"
  ensure_env_kv "N8N_PROTOCOL" "${N8N_PROTOCOL:-http}" "$envfile"
  ensure_env_kv "WEBHOOK_URL" "${WEBHOOK_URL:-http://$host_ip:$PORT_N8N/}" "$envfile"
}

copy_compose() {
  script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
  src="$script_dir/docker-compose.yml"
  [ -f "$src" ] || die "Manjka docker-compose.yml v isti mapi kot install.sh"

  dst="$HOMELAB_DIR/docker-compose.yml"
  if [ -f "$dst" ]; then
    cp "$dst" "$dst.bak.$(date +%F_%H%M%S)" || true
  fi
  cp "$src" "$dst"
}

main() {
  require_root

  ensure_docker_installed
  start_docker_service

  # wait a moment for dockerd
  if ! docker info >/dev/null 2>&1; then
    sleep 2
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon ne teče (dockerd)."

  make_dirs_and_perms
  write_env
  copy_compose

  COMPOSE_CMD="$(pick_compose_cmd)"

  log "[*] Deploy v: $HOMELAB_DIR"
  cd "$HOMELAB_DIR"

  $COMPOSE_CMD pull
  $COMPOSE_CMD up -d --remove-orphans

  ip="$(detect_host_ip)"
  log ""
  log "[OK] Stack je gor. URLji:"
  log "  Seafile     : http://${ip}:$PORT_SEAFILE"
  log "  BentoPDF    : http://${ip}:$PORT_BENTOPDF"
  log "  IT-Tools    : http://${ip}:$PORT_ITTOOLS"
  log "  FreshRSS    : http://${ip}:$PORT_FRESHRSS"
  log "  Immich      : http://${ip}:$PORT_IMMICH"
  log "  Joplin      : http://${ip}:$PORT_JOPLIN"
  log "  Paperless   : http://${ip}:$PORT_PAPERLESS"
  log "  n8n         : http://${ip}:$PORT_N8N"
  log "  OnlyOffice  : http://${ip}:$PORT_ONLYOFFICE"
}

main "$@"
