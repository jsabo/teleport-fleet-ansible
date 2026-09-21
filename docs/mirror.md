# Serving Teleport artifacts from your own mirror

By default hosts download the agent from `https://cdn.teleport.dev`, both at enrolment
and on every later update. Set one variable to use an internal source instead:

```yaml
teleport_download_base_url: https://mirror.example.internal/teleport
teleport_download_ca_cert: /path/to/mirror-ca.pem     # only if the mirror uses a private CA
```

The enrol play downloads the bootstrap tarball from that URL and passes it to
`teleport-update enable --base-url`, which persists it in
`/opt/teleport/default/update.yaml`. Every future Managed Update pulls from the mirror.

## What the mirror must contain

For each version and architecture two tarballs are needed, each with its `.sha256` and
`.sig`, in **one flat directory** with their **original names** (Teleport v18.11.0
`lib/autoupdate/agent/installer.go:163-240`, `lib/autoupdate/package_url.go:42-56`):

```
teleport-update-v18.11.0-linux-amd64-bin.tar.gz       the updater bootstrap (17 MB), fetched by the playbook
teleport-update-v18.11.0-linux-amd64-bin.tar.gz.sha256
teleport-update-v18.11.0-linux-amd64-bin.tar.gz.sig
teleport-ent-v18.11.0-linux-amd64-bin.tar.gz          the agent (234 MB), fetched by teleport-update
teleport-ent-v18.11.0-linux-amd64-bin.tar.gz.sha256   "<hex>  <filename>"
teleport-ent-v18.11.0-linux-amd64-bin.tar.gz.sig      detached cosign signature
```

Name patterns: `teleport-update-v{version}-linux-{amd64|arm64}-bin.tar.gz` and
`{teleport|teleport-ent}-v{version}-linux-{amd64|arm64}[-fips]-bin.tar.gz`. Use
`teleport-ent` for Teleport Enterprise (including Cloud), `teleport` for Community; the
updater tarball has no edition.

Rules:

- **HTTPS only.** `teleport-update` rejects a base URL that is not `https://`
  (`lib/autoupdate/agent/config.go:242-244`). The certificate must chain to a CA the
  hosts trust; `teleport_download_ca_cert` installs a private CA in preflight. The mirror
  may be addressed by IP if its certificate carries an IP SAN (the lab does this).
- **Copy, never rebuild.** The `.sig` is a cosign signature checked against public keys
  compiled into `teleport-update` (v18.11.0 `lib/autoupdate/agent/installer.go:236`), so a
  repacked or re-signed tarball fails verification.
- **All three files, every version.** The updater fetches the `.sha256` first, then the
  tarball, then the `.sig`. Measured against the lab mirror: the 18.11.1 updater
  requested all three; the 18.11.0 updater requested only the checksum and the tarball.
  Keep the `.sig` files on the mirror for every version.
- **Stay ahead of the rollout.** Agents ask for the version the cluster advertises in
  `https://<proxy>/v1/webapi/find` (`.auto_update.agent_version`). Sync before the
  maintenance window, on a timer.

## Populating it

```bash
ansible-playbook playbooks/mirror-sync.yml -e teleport_proxy=example.teleport.sh:443 -e mirror_dest=/srv/teleport
```

The playbook reads the cluster's advertised version and edition, fetches both tarballs
and their sidecars per architecture from `cdn.teleport.dev`, verifies each tarball against its `.sha256`,
skips files already present and intact, and prints the manifest. It fetches both the
advertised agent version and the current server version; add
`-e '{"mirror_extra_versions":["18.11.2"]}'` for more, and
`-e '{"mirror_archs":["amd64"]}'` to narrow the architectures.

Run it hourly:

```ini
# /etc/systemd/system/teleport-mirror-sync.timer  (service: ansible-playbook playbooks/mirror-sync.yml ...)
[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
[Install]
WantedBy=timers.target
```

## Serving it

Any static file server works; the updater only issues GET requests.

nginx:

```nginx
server {
    listen 443 ssl;
    server_name mirror.example.internal;
    ssl_certificate     /etc/nginx/tls/server.pem;
    ssl_certificate_key /etc/nginx/tls/server.key;
    location /teleport/ { alias /srv/teleport/; }
}
```

An S3 or GCS bucket behind HTTPS with the same flat key layout also works.

## Moving an enrolled fleet to a mirror

Set the variables and re-run `playbooks/10-enroll.yml -e transport=teleport` (OpenSSH is
off by then). Hosts that are already enrolled skip token minting; the install step notices the base URL in `teleport-update status`
differs and re-runs `teleport-update enable` with the new `--base-url`. Nothing else
changes and the agent is not restarted.

For a one-off run the updater also honours `TELEPORT_CDN_BASE_URL` in its environment;
the persisted `--base-url` is the durable setting.

## Demo

`lab/proxmox/up.yml -e lab_mirror=true` plus `lab/proxmox/mirror.yml` add a fourth VM serving the synced
artifacts over HTTPS with a private CA (addressed by IP) and point `cdn.teleport.dev` at
`127.0.0.1` on the fleet VMs, so any fetch that bypassed the mirror would fail visibly.
The mirror's nginx access log shows, per host, the updater tarball and the agent tarball
with their checksums.
