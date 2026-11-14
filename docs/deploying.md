# Deploying a stack

The stacks are made for a hardened Debian host with Docker Engine (Docker
CE, the admin user in the `docker` group, `/tmp` mounted `noexec`, AIDE and
auditd with locked rules). They work on any Debian host with Docker and
the Compose plugin; the AIDE / auditd step is then optional.

Every stack instance lives in its own folder, `/stacks/<STACK_NAME>/`: its
Compose file, configuration, certificates, passwords, data and logs (bind
mounts, or named volumes bound to a folder there). The repository checkout itself can be anywhere; a
stack's `deploy.sh` copies what the instance needs into its folder.

## Once per host

1. **Data disk.** Add a blank virtual disk for `/stacks`, so stack data
   can't fill the system disk (on the hardened image, auditd halts the VM
   when the system disk is 97 % full). Find it with `lsblk` (Linux may
   number disks differently from the hypervisor), then:

   ```sh
   sudo scripts/data-disk.sh /dev/sdX
   ```

   It refuses a disk that isn't blank, creates LVM volume group `vg_data`
   with one ext4 volume `lv_data`, mounts it on `/stacks` by UUID
   (`noatime,nodev,nosuid`) and makes `docker.service` wait for it. The
   empty mount point is made immutable, so nothing lands on the system
   disk if the data disk is ever missing.

   Without a data disk, `deploy.sh` refuses to run unless
   `STACKS_ON_SYSTEM_DISK=yes` is set.

2. **Integrity and audit.** After `/stacks` exists:

   ```sh
   sudo scripts/harden.sh
   sudo reboot
   ```

   - AIDE watches everything under `/stacks` except each stack's `data/`
     and `logs/` folders (`/etc/aide/aide.conf.d/70_aide_docker_stacks`).
   - auditd records changes under `/stacks` made by logged-in users, also
     through `sudo`, key `docker-stacks`
     (`/etc/audit/rules.d/70-docker-stacks.rules`). Containers write with
     no login id, so the data the stacks write themselves is not
     recorded.
   - auditd also records every `docker` command run by a logged-in user,
     with its arguments, key `docker-cmd`: members of the `docker` group
     are root-equivalent.
   - The audit rules are locked at boot: the new rules are loaded by the
     reboot.

   Both cover every stack, present and future: there is no need to run it
   again for a new stack.

## Per stack

```sh
cd stacks/<stack>
cp .env.example .env      # set STACK_NAME and the stack's settings
sudo ./deploy.sh
```

`STACK_NAME` names the instance: its folder, container, Compose project
and certificate name. Lowercase letters, digits and `-`, starting with a
letter, at most 32 characters. Two instances of the same stack need two
names (and two checkouts or two `.env` files: `sudo ./deploy.sh
/path/to/other.env`).

`deploy.sh` copies `.env` into `/stacks/<STACK_NAME>/.env`. From then on
that copy is the instance's settings: edit it and run

```sh
sudo ./deploy.sh /stacks/<STACK_NAME>/.env
```

`deploy.sh` can be run again at any time: it keeps existing certificates,
passwords and data, and applies changed settings. Running it with a
different `.env` for the same `STACK_NAME` overwrites the instance's copy
(it says so). The image is pulled only when it isn't on the host yet.

After the first deploy, the next daily AIDE report lists the new files
under `/stacks` (and the configuration files the scripts added). Review
it, then accept it:

```sh
sudo less /var/log/aide/aide.log
sudo aide-accept
```

## Reading the audit log

```sh
sudo ausearch -i -k docker-stacks     # changes under /stacks
sudo ausearch -i -k docker-cmd        # docker commands, with arguments
```

In scripts, add `--input-logs`: without it `ausearch` reads standard input
when that isn't a terminal.

## Stacks

| Stack | Docs |
|---|---|
| `wazuh-indexer` | [wazuh-indexer.md](wazuh-indexer.md) |
