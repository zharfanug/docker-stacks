# Stack: wazuh-indexer

One Wazuh indexer node (OpenSearch, image `wazuh/wazuh-indexer`), on its own
host or next to other stacks. The Wazuh manager and dashboard connect to it
over HTTPS on port 9200. First read [deploying.md](deploying.md).

## Requirements

| | Minimum | Recommended |
|---|---|---|
| CPU | 2 | 4 or more |
| RAM | 4 GB | 8 GB or more; half of it for the JVM heap |
| `/stacks` disk | 50 GB | 100 GB or more, fast storage (SSD) |

The indexer is usually the bottleneck of a Wazuh deployment: heap first,
then disk throughput and latency, then CPU.

## Deploy

```sh
cd stacks/wazuh-indexer
cp .env.example .env
```

| Setting | Meaning |
|---|---|
| `STACK_NAME` | instance name: `/stacks/<STACK_NAME>/`, container, Compose project, node name (certificate CN). E.g. `wdl01` |
| `WAZUH_VERSION` | image tag, e.g. `4.14.1`. Manager and dashboard must run the same version |
| `INDEXER_HEAP` | JVM heap (`-Xms` = `-Xmx`), e.g. `8g`. Empty: half of the host's RAM, at most `31g`; the rest stays free for the file system cache. Set it when the host runs other things too |
| `INDEXER_BIND`, `INDEXER_PORT` | where the REST API is published on the host (default every interface, port 9200) |
| `CERT_SAN` | extra names / IPv4 addresses in the certificate, comma separated |

```sh
sudo ./deploy.sh
```

On the first run it:

1. sets `vm.max_map_count = 262144` (`/etc/sysctl.d/90-wazuh-indexer.conf`),
   required by the indexer;
2. creates `/stacks/<STACK_NAME>/`;
3. creates a root CA and issues the indexer certificate (`CN=<STACK_NAME>`;
   names: the instance name, the host's short and full name, its IPv4
   addresses, `localhost`, `127.0.0.1`, plus `CERT_SAN`) and the `admin`
   client certificate (RSA 2048, SHA-256, 10 years);
4. creates random passwords for the indexer users `admin` and
   `kibanaserver` (the demo users of the image are not created);
5. starts the indexer and waits until it answers and `admin` can log in.

Settings in the configuration: memory locking (`bootstrap.memory_lock`;
the heap never goes to swap), default disk watermarks (at 85 / 90 / 95 % the
indexer stops allocating shards, then makes indices read-only, instead of
failing at 100 %).

## Files

`/stacks/<STACK_NAME>/`:

| Path | Content | Owner, mode |
|---|---|---|
| `docker-compose.yml`, `.env` | copied from the checkout by `deploy.sh` | root, 0644 |
| `config/<STACK_NAME>-opensearch.yml` | indexer configuration, rendered from `opensearch.yml.in` | root:1000, 0640 |
| `config/<STACK_NAME>-jvm.env` | JVM heap, written from `INDEXER_HEAP` on every run | root, 0644 |
| `config/<STACK_NAME>-internal_users.yml` | password hashes, loaded on the first start | root:1000, 0640 |
| `config/certs/` | root CA certificate, indexer and admin key pairs | root:1000, 0640 |
| `credentials/indexer.env` | the passwords, the **only** record of them | root, 0600 |
| `ca/` | root CA key: issues the certificates of the other Wazuh nodes | root, 0700 |
| `data/` | indexes (Docker volume `<STACK_NAME>-data`) | 1000:1000, 0750 |
| `logs/` | indexer logs (Docker volume `<STACK_NAME>-logs`) | 1000:1000, 0750 |

`data/` and `logs/` are mounted through named volumes bound to these
folders, so `docker volume ls` shows them, but the files stay on the data
disk: `docker compose down -v` or `docker volume rm` removes only the
volume entry, not the files.

The indexer runs as user and group 1000 inside the container, so on the
host these files show the name of whatever account has ID 1000 (often the
first admin account). Members of the `docker` group can read everything
anyway.

Read a password:

```sh
sudo grep '^WAZUH_INDEXER_ADMIN_PASSWORD=' /stacks/<STACK_NAME>/credentials/indexer.env | cut -d= -f2-
```

The manager logs in as `admin`, the dashboard as `kibanaserver` (and
`admin`); both need `config/certs/root-ca.pem` to verify the indexer.

## Port 9200 is reachable from every network

The REST API is published on every interface, and the `admin` account
administers all data. Docker publishes ports through NAT and the forward
path, **not** the host's input firewall: `custom-input.nft` does not
restrict it. Either:

- set `INDEXER_BIND` to one address of the host and run `deploy.sh` again;
- or allow only the Wazuh manager and dashboard in Docker's `DOCKER-USER`
  chain (checked before Docker's own rules), e.g.:

  ```sh
  sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 9200 --ctdir ORIGINAL -j DROP
  sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 9200 --ctdir ORIGINAL -s <manager-ip> -j RETURN
  sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 9200 --ctdir ORIGINAL -s <dashboard-ip> -j RETURN
  ```

  `iptables` rules are lost at reboot unless saved (a systemd unit that
  runs after `docker.service`, or `iptables-persistent`).

## Check

```sh
cd /stacks/<STACK_NAME>
docker compose ps                      # healthy
docker compose logs --tail 50
```

```sh
d=/stacks/<STACK_NAME>
sudo sh -c "printf 'user = \"admin:%s\"\n' \"\$(sed -n 's/^WAZUH_INDEXER_ADMIN_PASSWORD=//p' $d/credentials/indexer.env)\" \
  | curl -s --cacert $d/config/certs/root-ca.pem --config - 'https://127.0.0.1:9200/_cluster/health?pretty'"
```

A single node reports `green` until indices with replicas exist, then
`yellow` (replicas can't be placed on the same node).

## Change a password

`<STACK_NAME>-internal_users.yml` is read on the first start only; afterwards the
users live in the indexer's security index. To change e.g. `kibanaserver`:

```sh
d=/stacks/<STACK_NAME>
# 1. hash the new password (12-64 characters, upper, lower, digit and one of . , _ + : @ % ^ = ~ -)
read -rs PW && export PW
docker exec -e PW <STACK_NAME> bash -c \
  'JAVA_HOME=/usr/share/wazuh-indexer/jdk bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -env PW'
unset PW
# 2. replace the user's hash in $d/config/<STACK_NAME>-internal_users.yml (sudo), and
#    the password in $d/credentials/indexer.env
# 3. load the file into the security index
docker exec <STACK_NAME> bash -c 'C=/usr/share/wazuh-indexer/config; JAVA_HOME=/usr/share/wazuh-indexer/jdk \
  bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
  -f $C/opensearch-security/internal_users.yml -t internalusers -icl -nhnv -h 127.0.0.1 \
  -cacert $C/certs/root-ca.pem -cert $C/certs/admin.pem -key $C/certs/admin-key.pem'
```

Then update the password wherever the manager or dashboard use it.

## New certificate

When the host's names or addresses change (the certificate holds the IPv4
addresses it had at deploy time; `deploy.sh` warns when they no longer
match):

```sh
sudo rm /stacks/<STACK_NAME>/config/certs/indexer.pem /stacks/<STACK_NAME>/config/certs/indexer-key.pem
sudo ./deploy.sh
cd /stacks/<STACK_NAME> && docker compose restart
```

The new certificate is signed by the same root CA, so clients keep
trusting it. Deleting `ca/` creates a new CA: every client then needs the
new `root-ca.pem`.

## Backup

Keep a copy of `ca/`, `credentials/`, `config/` and `.env` (root only, as
restricted as the originals). For the indexes, either stop the stack and
copy `data/`, or use the indexer's snapshot API.

```sh
cd /stacks/<STACK_NAME> && docker compose stop
sudo tar -C /stacks -czf /root/<STACK_NAME>-$(date +%F).tgz <STACK_NAME>
docker compose start
```

## Upgrade

Within 4.14.x only: `deploy.sh` refuses other versions, because 5.x
changes the image's user, password handling and mounts and needs a
migration. Set the new `WAZUH_VERSION` in `/stacks/<STACK_NAME>/.env`
(manager and dashboard to the same version) and run
`sudo ./deploy.sh /stacks/<STACK_NAME>/.env`: Compose replaces the
container, data, certificates and passwords stay. Check Wazuh's release notes first; going
back to an older version is not possible once the data has been upgraded.
