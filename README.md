# Docker Stacks

Docker Compose stacks with a deploy script each, for a hardened Debian host
running Docker Engine. Every instance lives in `/stacks/<name>/` on its own
data disk, with its configuration, certificates, passwords and data in one
place.

| Path | |
|---|---|
| `scripts/data-disk.sh` | puts `/stacks` on a blank disk (LVM + ext4) |
| `scripts/harden.sh` | adds `/stacks` to AIDE and auditd |
| `stacks/wazuh-indexer/` | Wazuh indexer, one node |

Start with [docs/deploying.md](docs/deploying.md).
