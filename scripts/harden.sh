#!/usr/bin/env bash
# Adds /stacks to the host's file integrity checks (AIDE) and audit rules
# (auditd), for every stack, present and future. Run once per host, after
# /stacks exists (scripts/data-disk.sh or a stack's deploy.sh):
#
#   sudo scripts/harden.sh
#
# New audit rules load at the next boot only (the rules are locked).
set -euo pipefail

STACKS=/stacks
AIDE_FILE=/etc/aide/aide.conf.d/70_aide_docker_stacks
AUDIT_FILE=/etc/audit/rules.d/70-docker-stacks.rules

log() { printf '==> %s\n' "$*"; }
die() { printf 'harden.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
# A watch on a missing directory stops the whole audit rule load at boot.
[ -d "$STACKS" ] || die "$STACKS does not exist yet; create it first (scripts/data-disk.sh)"
[ -d /etc/aide/aide.conf.d ] || die "AIDE is not installed"
[ -d /etc/audit/rules.d ] || die "auditd is not installed"

# Writes $2 to $1 (mode $3) if the content differs; returns 0 if it changed.
put() {
  local file=$1 content=$2 mode=$3 tmp
  [ -f "$file" ] && [ "$(cat "$file")" = "$content" ] && return 1
  tmp=$(mktemp "$file.XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$file"
}

aide_rules='# docker-stacks: configuration, certificates, passwords and CAs of every
# stack in /stacks. Not their data/ and logs/ folders: they change all the time.
/stacks Full
!/stacks/[^/]+/data(/|$)
!/stacks/[^/]+/logs(/|$)'

audit_rules='## docker-stacks: changes under /stacks by logged-in users (also through
## sudo). Containers write with no login id (auid unset), so the data the
## stacks write themselves is not recorded.
-a always,exit -F arch=b64 -F dir=/stacks -F perm=wa -F auid>=1000 -F auid!=unset -F key=docker-stacks
-a always,exit -F arch=b32 -F dir=/stacks -F perm=wa -F auid>=1000 -F auid!=unset -F key=docker-stacks
## docker-stacks: every docker command run by a logged-in user, with its
## arguments (members of the docker group are root-equivalent).
-a always,exit -F arch=b64 -F path=/usr/bin/docker -F perm=x -F auid>=1000 -F auid!=unset -F key=docker-cmd
-a always,exit -F arch=b32 -F path=/usr/bin/docker -F perm=x -F auid>=1000 -F auid!=unset -F key=docker-cmd'

if put "$AIDE_FILE" "$aide_rules" 0644; then
  log "AIDE: wrote $AIDE_FILE"
  if ! aide --config /etc/aide/aide.conf --config-check >/dev/null; then
    rm -f "$AIDE_FILE"
    die "AIDE rejected $AIDE_FILE; removed it again"
  fi
else
  log "AIDE: $AIDE_FILE unchanged"
fi

reboot_needed=0
if put "$AUDIT_FILE" "$audit_rules" 0640; then
  log "auditd: wrote $AUDIT_FILE"
  reboot_needed=1
else
  log "auditd: $AUDIT_FILE unchanged"
fi
rules_now=$(auditctl -l 2>/dev/null || true)
if ! grep -q 'key=docker-stacks' <<< "$rules_now" || ! grep -q 'key=docker-cmd' <<< "$rules_now"; then
  reboot_needed=1
fi

echo
if [ "$reboot_needed" = 1 ]; then
  echo "Reboot to load the audit rules (the rules are locked until then)."
  echo "Afterwards: sudo auditctl -l | grep -E 'docker-(stacks|cmd)'"
else
  echo "The audit rules are loaded."
fi
echo "After reviewing the next AIDE report (new files in /stacks, /etc/aide):"
echo "  sudo aide-accept"
