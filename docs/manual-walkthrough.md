# Manual walkthrough: one server, by hand

This is exactly what the playbooks do, typed one command at a time, so you can watch
each step and understand it before automating it. It takes about ten minutes for one
host. Terms are explained in [concepts.md](concepts.md).

You need: a Linux server with systemd you can reach over SSH as a sudo user; a
Teleport cluster (`example.teleport.sh:443` below); `tsh` and `tctl` on your
workstation, logged in as a user whose role can create tokens and read nodes.

Two shells: **controller** (your workstation) and **host** (the server, as root).

## 1. Preflight (host)

```bash
systemctl --version | head -1                      # systemd is required by teleport-update
uname -m                                           # x86_64 → amd64, aarch64 → arm64
hostname                                           # becomes the node name
date -u; df -h /opt /var/lib                       # clock within 2 min of real time, ≥1 GB free
curl -s https://example.teleport.sh/webapi/ping | jq .server_version
curl -s https://example.teleport.sh/v1/webapi/find | jq '{edition, agent_version: .auto_update.agent_version}'
```

The last command tells you which artifact to fetch: `edition: ent` means the
`teleport-ent` package; `agent_version` is the version the cluster wants its agents on.

## 2. Create the join token (controller)

One token, for this host only, valid for fifteen minutes:

```bash
EXP=$(date -u -v+15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+15 min' +%Y-%m-%dT%H:%M:%SZ)
cat > token.yaml <<EOF
kind: token
version: v2
metadata:
  name: node-web-01
  expires: "$EXP"
spec:
  roles: [Node]
  join_method: bound_keypair
  bound_keypair:
    onboarding:
      must_register_before: "$EXP"
    recovery:
      limit: 1
      mode: standard
EOF
tctl create -f token.yaml
tctl get token/node-web-01 --with-secrets --format=yaml | grep registration_secret
```

Copy the registration secret. It works once.

## 3. Install the agent through Managed Updates (host)

```bash
V=18.11.1; ARCH=amd64                              # from step 1
cd /tmp
curl -fsSLO https://cdn.teleport.dev/teleport-update-v$V-linux-$ARCH-bin.tar.gz
curl -fsSLO https://cdn.teleport.dev/teleport-update-v$V-linux-$ARCH-bin.tar.gz.sha256
sha256sum -c teleport-update-v$V-linux-$ARCH-bin.tar.gz.sha256
tar xzf teleport-update-v$V-linux-$ARCH-bin.tar.gz teleport/teleport-update
./teleport/teleport-update enable --proxy example.teleport.sh:443 --group staging
teleport-update status                             # enabled: true, active.version, group
ls -l /usr/local/bin/teleport                      # symlink into /opt/teleport/default/versions/...
systemctl cat teleport | head -12                  # the unit teleport-update wrote
```

`enable` downloaded the full agent for the advertised version, installed it, and set up
the five-minute update timer. It did not start the agent yet. It prints a note that tbot
is installed but not running: the updater manages Machine ID's `tbot` as well, and the
note is expected on a plain server. Replace
`https://cdn.teleport.dev` with your mirror and add `--base-url` if you run one
([mirror.md](mirror.md)).

## 4. Configure and join (host)

```bash
install -m 0600 /dev/null /var/lib/teleport/registration-secret
echo '<registration secret from step 2>' > /var/lib/teleport/registration-secret

cat > /etc/teleport.yaml <<'EOF'
version: v3
teleport:
  nodename: web-01
  data_dir: /var/lib/teleport
  proxy_server: example.teleport.sh:443
  join_params:
    token_name: node-web-01
    method: bound_keypair
    bound_keypair:
      registration_secret_path: /var/lib/teleport/registration-secret
auth_service:
  enabled: false
proxy_service:
  enabled: false
ssh_service:
  enabled: true
  labels:
    env: lab
    site: dc1
    team: unassigned
    service: unassigned
    tier: unclassified
    lifecycle: provisioning
    onboarded-by: manual
  commands:
    - name: kernel
      command: [uname, -r]
      period: 1h
    - name: distro
      command: [sh, -c, '. /etc/os-release && printf "%s-%s" "$ID" "$VERSION_ID"']
      period: 24h
  port_forwarding: false
  ssh_file_copy: false
  disable_create_host_user: true
EOF
teleport configure --test /etc/teleport.yaml       # syntax check
systemctl enable --now teleport
journalctl -u teleport -f                          # watch: "Successfully obtained credentials", "starting in tunnel mode"
```

## 5. Confirm the join and clean up

Controller:

```bash
tctl nodes ls                                      # web-01 appears within seconds (if your role can see it)
tctl inventory ls --services node                  # every connected agent, role-independent; can lag by minutes
tctl get token/node-web-01 --format=yaml | grep -A4 'status:'   # bound_host_id = the host's UUID
cat /var/lib/teleport/host_uuid                    # (on the host) the same UUID
tsh ls                                             # visible if your role matches its labels
tctl tokens rm node-web-01                         # the token has done its job
```

Host:

```bash
rm /var/lib/teleport/registration-secret           # read once, at the first join; not needed again
systemctl restart teleport && journalctl -u teleport -n 5   # restarts from /var/lib/teleport/proc, no token
```

## 6. Verify through Teleport (controller)

```bash
tsh ssh root@web-01 'hostname; teleport-update status | grep -E "enabled|group"'
```

Everything from here on goes through Teleport. This is the moment OpenSSH becomes
optional.

Right after the restart in step 5 this can fail with "no tunnel connection found": the
agent re-opens its tunnel to the proxy a few seconds after it starts. Try again.

If this replaces a server that had the same name, `tsh ssh` may answer "ambiguous
host could match multiple nodes": the old node record lives for up to 15 minutes after
its agent is gone. Use the UUID from step 5 instead (`tsh ssh root@<uuid>`), or delete
the old record with `tctl rm node/<old uuid>`.

## 7. Switch OpenSSH off (controller, through Teleport)

```bash
tsh ssh root@web-01 'systemctl disable --now ssh.socket ssh.service'      # Debian / Ubuntu
tsh ssh root@web-01 'systemctl disable --now sshd.service'                # RHEL / Rocky / Alma / Amazon
ssh root@<ip>                                      # "Connection refused"
tsh ssh root@web-01 uptime                         # works
```

(`systemctl is-enabled` exits non-zero for a disabled unit, so `tsh ssh` reports
"Process exited with status 1" if you check that way; the refused connection above is
the proof.)

The unit files stay; a console session can `systemctl enable --now ssh` at any time.

## 8. Change a label later

```bash
tsh ssh root@web-01 'sed -i "s/team: unassigned/team: payments/" /etc/teleport.yaml && systemctl reload teleport'
tctl nodes ls | grep web-01                        # new label within seconds, same UUID
```

`reload` sends SIGHUP; the agent forks a child that re-reads the file and takes over
without dropping sessions.

## 9. Undo everything

```bash
tsh ssh root@web-01 'systemctl enable --now ssh.socket ssh.service'       # or sshd.service
ssh root@<ip> 'systemctl disable --now teleport && teleport-update uninstall --force && rm -rf /etc/teleport.yaml /var/lib/teleport'
tctl rm node/<uuid>
```

## What the playbooks add

The same steps for many hosts at once: preflight fails fast per host, all tokens are
created in one `tctl create`, hosts install in parallel, one wait covers the whole
fleet's registration, and the verify and harden phases run through Teleport so a host
that Teleport cannot reach keeps OpenSSH. See the README.
