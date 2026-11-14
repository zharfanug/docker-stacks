#!/usr/bin/env bash
# Deploys one Wazuh indexer instance into /stacks/<STACK_NAME> and starts it.
#
#   sudo ./deploy.sh [path/to/.env]      (default: .env next to this script)
#
# After the first deploy, /stacks/<STACK_NAME>/.env is the instance's copy;
# edit it and run: sudo ./deploy.sh /stacks/<STACK_NAME>/.env
#
# Safe to run again: existing certificates, passwords and data are kept.
# Temporary files stay inside /stacks/<STACK_NAME> (never /tmp).
set -euo pipefail

STACKS=/stacks
SRC=$(cd "$(dirname "$0")" && pwd)
INDEXER_ID=1000   # user and group of the indexer process in the 4.x image
CERT_SUBJECT="/C=US/L=California/O=Wazuh/OU=Wazuh"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'deploy.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
env_file=$(readlink -f "${1:-$SRC/.env}")
[ -f "$env_file" ] || die "$env_file not found: copy .env.example to .env and edit it"
set -a
# shellcheck source=/dev/null
. "$env_file"
set +a

[[ ${STACK_NAME:-} =~ ^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$ ]] ||
  die "STACK_NAME must be 1-32 lowercase letters, digits or '-', start with a letter and not end with '-'"
[ -n "${WAZUH_VERSION:-}" ] || die "WAZUH_VERSION is not set"
case $WAZUH_VERSION in
  4.14.*) ;;
  *) die "this stack supports Wazuh 4.14.x (WAZUH_VERSION=$WAZUH_VERSION); 5.x changes the user, passwords and mounts and needs a migration" ;;
esac
if [ -n "${INDEXER_HEAP:-}" ]; then
  [[ $INDEXER_HEAP =~ ^[0-9]+[mg]$ ]] || die "INDEXER_HEAP must look like 8g or 4096m"
  heap_from="INDEXER_HEAP"
else
  # Half of the RAM, at most 31g (keeps compressed object pointers), at least 512m.
  mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  heap_mb=$((mem_mb / 2))
  [ "$heap_mb" -le 31744 ] || heap_mb=31744
  [ "$heap_mb" -ge 512 ] || heap_mb=512
  INDEXER_HEAP=${heap_mb}m
  heap_from="half of ${mem_mb} MB RAM"
fi
INDEXER_BIND=${INDEXER_BIND:-0.0.0.0}
INDEXER_PORT=${INDEXER_PORT:-9200}
command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed"
command -v openssl >/dev/null || die "openssl not found"

image=wazuh/wazuh-indexer:$WAZUH_VERSION
dir=$STACKS/$STACK_NAME
ca=$dir/ca
certs=$dir/config/certs
cred=$dir/credentials/indexer.env
users=$dir/config/$STACK_NAME-internal_users.yml
os_yml=$dir/config/$STACK_NAME-opensearch.yml
compose=(docker compose --project-directory "$dir" -f "$dir/docker-compose.yml" --env-file "$dir/.env")

# --- /stacks -----------------------------------------------------------------
if ! mountpoint -q "$STACKS"; then
  [ "${STACKS_ON_SYSTEM_DISK:-}" = yes ] ||
    die "$STACKS is not a mounted data disk (see scripts/data-disk.sh). Indexer data on the system disk can fill it, and auditd halts the VM at 3 % free. Set STACKS_ON_SYSTEM_DISK=yes to deploy there anyway."
  warn "$STACKS is on the system disk (STACKS_ON_SYSTEM_DISK=yes)"
  install -d -m 0755 "$STACKS"
fi

# --- kernel setting required by the indexer ----------------------------------
log "vm.max_map_count = 262144 (/etc/sysctl.d/90-wazuh-indexer.conf)"
printf '# Wazuh indexer (OpenSearch): memory-mapped index files.\nvm.max_map_count = 262144\n' \
  > /etc/sysctl.d/90-wazuh-indexer.conf
sysctl -q -p /etc/sysctl.d/90-wazuh-indexer.conf

# --- directories -------------------------------------------------------------
log "directories in $dir"
install -d -m 0755 "$dir"
install -d -m 0750 -o 0 -g "$INDEXER_ID" "$dir/config" "$certs"
install -d -m 0700 -o 0 -g 0 "$ca" "$dir/credentials"
install -d -m 0750 -o "$INDEXER_ID" -g "$INDEXER_ID" "$dir/data" "$dir/logs"
umask 077

if docker image inspect "$image" >/dev/null 2>&1; then
  log "using $image (already pulled)"
else
  log "pulling $image"
  docker pull -q "$image" >/dev/null
fi

# --- certificates ------------------------------------------------------------
# Names and addresses in the indexer certificate: the instance name, this
# host's names and IPv4 addresses (not Docker's bridges), loopback, CERT_SAN.
sans=("DNS:$STACK_NAME" "DNS:localhost" "IP:127.0.0.1")
for n in "$(hostname -s)" "$(hostname -f 2>/dev/null || true)"; do
  [ -n "$n" ] && sans+=("DNS:$n")
done
while read -r _ ifname _ addr _; do
  case $ifname in docker0 | br-* | veth*) continue ;; esac
  sans+=("IP:${addr%/*}")
done < <(ip -4 -o addr show scope global)
IFS=, read -r -a extra <<< "${CERT_SAN:-}"
for s in "${extra[@]}"; do
  s=${s//[[:space:]]/}
  [ -n "$s" ] || continue
  if [[ $s =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then sans+=("IP:$s")
  elif [[ $s =~ ^[A-Za-z0-9.-]+$ ]]; then sans+=("DNS:$s")
  else die "CERT_SAN entry '$s' is neither an IPv4 address nor a host name"
  fi
done
san_list=$(printf '%s\n' "${sans[@]}" | awk '!seen[$0]++' | paste -sd, -)

# Signs <name>.pem / <name>-key.pem in $ca for CN=<cn>, optional SAN list.
issue() {
  local name=$1 cn=$2 san=${3:-}
  {
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment"
    echo "authorityKeyIdentifier = keyid,issuer"
    if [ -n "$san" ]; then echo "subjectAltName = $san"; fi
  } > "$ca/$name.ext"
  openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$ca/$name-key.pem"
  openssl req -new -key "$ca/$name-key.pem" -subj "$CERT_SUBJECT/CN=$cn" -out "$ca/$name.csr"
  openssl x509 -req -in "$ca/$name.csr" -CA "$ca/root-ca.pem" -CAkey "$ca/root-ca.key" \
    -CAcreateserial -sha256 -days 3650 -extfile "$ca/$name.ext" -out "$ca/$name.pem" 2>/dev/null
  rm -f "$ca/$name.csr" "$ca/$name.ext"
}

# Moves a pair from $ca into config/certs, readable by the indexer's group.
place() {
  install -m 0640 -o 0 -g "$INDEXER_ID" "$ca/$1.pem" "$certs/$1.pem"
  install -m 0640 -o 0 -g "$INDEXER_ID" "$ca/$1-key.pem" "$certs/$1-key.pem"
  rm -f "$ca/$1.pem" "$ca/$1-key.pem"
}

if [ ! -s "$ca/root-ca.key" ]; then
  log "new root CA in $ca (back it up: it issues the certificates of every other Wazuh node)"
  openssl req -x509 -new -nodes -newkey rsa:2048 -sha256 -days 3650 \
    -subj "/OU=Wazuh/O=Wazuh/L=California" -keyout "$ca/root-ca.key" -out "$ca/root-ca.pem" 2>/dev/null
  rm -f "$certs"/indexer*.pem "$certs"/admin*.pem   # signed by a CA that is gone
fi
install -m 0640 -o 0 -g "$INDEXER_ID" "$ca/root-ca.pem" "$certs/root-ca.pem"

if [ -s "$certs/indexer.pem" ] && [ -s "$certs/indexer-key.pem" ]; then
  log "keeping the indexer certificate (delete $certs/indexer*.pem and run again to issue a new one)"
  have=$(openssl x509 -in "$certs/indexer.pem" -noout -ext subjectAltName 2>/dev/null |
    tail -n +2 | tr -d ' ' | sed 's/IPAddress:/IP:/g' | tr ',' '\n')
  missing=$(printf '%s\n' "${sans[@]}" | grep -vxF -f <(printf '%s\n' "$have") || true)
  if [ -n "$missing" ]; then
    warn "the indexer certificate does not cover: $(printf '%s' "$missing" | paste -sd' ' -)"
    warn "clients using those names or addresses will fail TLS checks; to reissue: sudo rm $certs/indexer.pem $certs/indexer-key.pem && sudo $0 ${1:-}"
  fi
else
  log "indexer certificate CN=$STACK_NAME, $san_list"
  issue indexer "$STACK_NAME" "$san_list"
  place indexer
fi
if [ -s "$certs/admin.pem" ] && [ -s "$certs/admin-key.pem" ]; then
  log "keeping the admin certificate"
else
  log "admin certificate CN=admin"
  issue admin admin
  place admin
fi

# --- passwords ---------------------------------------------------------------
# 32 characters, at least one upper, lower, digit and symbol, from the set
# the Wazuh tools accept.
gen_password() {
  local p=""
  until [[ $p =~ [a-z] && $p =~ [A-Z] && $p =~ [0-9] && $p =~ [.,_+:@%^=~-] ]]; do
    p=$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9.,_+:@%^=~-' | cut -c1-32)
  done
  printf '%s' "$p"
}

# bcrypt hash with the indexer's own tool; the password goes in through the
# environment, not the command line.
hash_password() {
  local h
  h=$(PW=$1 docker run --rm -e PW --entrypoint /bin/bash "$image" -c \
    'JAVA_HOME=/usr/share/wazuh-indexer/jdk bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -env PW' |
    tail -n 1)
  [[ $h =~ ^\$2[aby]\$[0-9]{2}\$ ]] || die "hash.sh did not return a bcrypt hash"
  printf '%s' "$h"
}

if [ -s "$cred" ] && [ -s "$users" ]; then
  log "keeping the existing passwords ($cred)"
elif [ -e "$cred" ] || [ -e "$users" ]; then
  die "only one of $cred and $users exists; restore the other from a backup"
else
  [ -z "$(ls -A "$dir/data")" ] ||
    die "$dir/data already holds an indexer, but there are no passwords for it; restore $cred and $users from a backup"
  log "new passwords for admin and kibanaserver"
  admin_pw=$(gen_password)
  kibana_pw=$(gen_password)
  admin_hash=$(hash_password "$admin_pw")
  kibana_hash=$(hash_password "$kibana_pw")
  tmp=$(mktemp "$dir/config/.internal_users.XXXXXX")
  cat > "$tmp" <<EOF
---
# Users of the indexer's security plugin, loaded into the security index on
# the first start only. Change passwords later with securityadmin.sh
# (docs/wazuh-indexer.md); editing this file alone changes nothing.
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "$admin_hash"
  reserved: true
  backend_roles:
  - "admin"
  description: "Administrator (Wazuh manager and dashboard log in as admin)"

kibanaserver:
  hash: "$kibana_hash"
  reserved: true
  description: "Wazuh dashboard server"
EOF
  chown 0:"$INDEXER_ID" "$tmp"
  chmod 0640 "$tmp"
  mv "$tmp" "$users"
  tmp=$(mktemp "$dir/credentials/.indexer.env.XXXXXX")
  {
    echo "# Wazuh indexer $STACK_NAME, created $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo "# The only record of these passwords: keep it, back it up."
    echo "WAZUH_INDEXER_ADMIN_PASSWORD=$admin_pw"
    echo "WAZUH_INDEXER_KIBANASERVER_PASSWORD=$kibana_pw"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$cred"
  unset admin_pw kibana_pw
fi

# --- configuration and Compose files -----------------------------------------
config_changed=0
tmp=$(mktemp "$dir/config/.opensearch.XXXXXX")
sed "s/@NODE_NAME@/$STACK_NAME/g" "$SRC/opensearch.yml.in" > "$tmp"
if ! cmp -s "$tmp" "$os_yml"; then
  log "writing $os_yml"
  install -m 0640 -o 0 -g "$INDEXER_ID" "$tmp" "$os_yml"
  config_changed=1
fi
rm -f "$tmp"
log "JVM heap $INDEXER_HEAP ($heap_from)"
printf '# Written by deploy.sh from INDEXER_HEAP; run deploy.sh to change it.\nOPENSEARCH_JAVA_OPTS=-Xms%s -Xmx%s\n' \
  "$INDEXER_HEAP" "$INDEXER_HEAP" > "$dir/config/$STACK_NAME-jvm.env"
chmod 0644 "$dir/config/$STACK_NAME-jvm.env"
install -m 0644 -o 0 -g 0 "$SRC/docker-compose.yml" "$dir/docker-compose.yml"
if ! [ "$env_file" -ef "$dir/.env" ]; then
  if [ -f "$dir/.env" ] && ! cmp -s "$env_file" "$dir/.env"; then
    log "updating $dir/.env from $env_file"
  fi
  install -m 0644 -o 0 -g 0 "$env_file" "$dir/.env"
fi

# --- start -------------------------------------------------------------------
existed=0
docker container inspect "$STACK_NAME" >/dev/null 2>&1 && existed=1
log "starting $STACK_NAME"
"${compose[@]}" up -d
if [ "$existed" = 1 ] && [ "$config_changed" = 1 ]; then
  log "restarting $STACK_NAME for the new opensearch.yml"
  "${compose[@]}" restart indexer
fi

log "waiting for $STACK_NAME to become healthy (up to 10 minutes)"
status=""
for _ in $(seq 120); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$STACK_NAME" 2>/dev/null || echo missing)
  [ "$status" = healthy ] && break
  sleep 5
done
if [ "$status" != healthy ]; then
  docker logs --tail 40 "$STACK_NAME" >&2 || true
  die "$STACK_NAME is not healthy (status: $status)"
fi

host=$INDEXER_BIND
[ "$host" = 0.0.0.0 ] && host=127.0.0.1
admin_pw=$(sed -n 's/^WAZUH_INDEXER_ADMIN_PASSWORD=//p' "$cred")
health=$(printf 'user = "admin:%s"\n' "$admin_pw" |
  curl -sS --cacert "$certs/root-ca.pem" --config - "https://$host:$INDEXER_PORT/_cluster/health") ||
  die "the indexer does not answer on https://$host:$INDEXER_PORT"
unset admin_pw
cluster=$(printf '%s' "$health" | grep -o '"status":"[a-z]*"' | cut -d'"' -f4)
[ -n "$cluster" ] || die "admin login failed: $health"

cat <<EOF

$STACK_NAME is running: cluster status $cluster.
  REST API     https://$INDEXER_BIND:$INDEXER_PORT  (published on every interface when 0.0.0.0)
  passwords    $cred  (root only)
  root CA      $ca  (root only; back it up)
  manage       cd $dir && docker compose ps | logs | restart

Next:
  - scripts/harden.sh, once per host, if not done yet (needs a reboot)
  - sudo aide-accept, after reviewing the next AIDE report
  - restrict who can reach port $INDEXER_PORT: docs/wazuh-indexer.md
EOF
