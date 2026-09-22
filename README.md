# teleport-fleet-ansible

Move a fleet of Linux servers from OpenSSH to Teleport. Point the playbooks at your own
Ansible inventory and they install the Teleport agent with Managed Updates, join each
host with a token only it could use, stamp a standard set of labels for segmentation,
verify access through the Teleport proxy, and switch OpenSSH off. The same steps are
written out for doing one server by hand, so you can learn the mechanism before you
automate it.

Verified against Teleport 18.11 (Teleport Enterprise Cloud) on Ubuntu 24.04 and
Rocky Linux 9; the playbooks run unchanged on both.

## Start here

1. **Understand** what changes: what an agent, a join token, Managed Updates and labels
   are, in plain words. [docs/concepts.md](docs/concepts.md), ten minutes.
2. **Do one host by hand**, one command at a time.
   [docs/manual-walkthrough.md](docs/manual-walkthrough.md).
3. **Run the playbooks on your hosts**: the quick start below, phase by phase or all at once.

If you have a Proxmox server and want throwaway VMs to practise on, `lab/proxmox/`
creates them and narrates a run; it is optional and nothing else depends on it
([docs/lab-proxmox.md](docs/lab-proxmox.md)).

## Quick start

```bash
ansible-galaxy collection install -r requirements.yml
cp inventory/example.yml inventory/fleet.yml        # your proxy, your hosts, your labels
tsh login --proxy=example.teleport.sh:443
ansible-playbook -i inventory/fleet.yml site.yml
```

Your inventory is the input. Any Ansible inventory works (YAML, INI, dynamic) as long
as each host is either resolvable by its inventory name or carries an `ip:` variable,
and the group-level variables name your proxy. `inventory/example.yml` shows the shape
and every variable you are likely to set.

### Phase by phase

Each phase is its own playbook. Run one, look at the result, run the next:

```bash
ansible-playbook -i inventory/fleet.yml playbooks/00-preflight.yml   # nothing installed yet; every host checked
ansible-playbook -i inventory/fleet.yml playbooks/10-enroll.yml      # tokens, install, join, tokens removed
tsh ls                                                               # the new nodes, with their labels
ansible-playbook -i inventory/fleet.yml playbooks/20-verify.yml      # through Teleport; read-only; fleet summary
ansible-playbook -i inventory/fleet.yml playbooks/30-harden.yml      # through Teleport; OpenSSH off
ssh <user>@<host>                                                    # refused
tsh ssh root@<node>                                                  # works
```

`site.yml` runs the four in sequence for an unattended fleet.

### What to expect

Measured on three hosts (two Ubuntu 24.04, one Rocky 9) against Teleport 18.11.1, with
the per-task profile and timer that `ansible.cfg` enables (`ansible.posix.profile_tasks`,
`ansible.posix.timer`; every run ends with a slowest-tasks list and a total):

| Phase | Time | Where it goes |
|---|---|---|
| 00 preflight | 8 s | facts, six asserts, two HTTPS checks per host, three `tsh`/`tctl` calls on the controller |
| 10 enrol | 48 s | `teleport-update enable` (downloads and installs the agent, ~12 s), the agent's first join (~10 s), one wait for all node records (~9 s), three fleet-wide `tctl` calls and one token removal per host |
| 20 verify | 8 s | read-only; a second run reports `changed=0` |
| 30 harden | 8 s | two batches (`serial: [2, 10, "25%"]`) |

Hosts install in parallel, so a larger fleet costs little more wall-clock time. The
controller makes three `tctl` calls for the whole fleet (create the tokens, read the
secrets, read the bindings) and one `tctl tokens rm` per host, which run in parallel.

Host keys are checked. The OpenSSH transport accepts a host's key on first contact and
refuses a changed one afterwards (`StrictHostKeyChecking=accept-new`), so a rebuilt
host needs `ssh-keygen -R <address>` before it is enrolled again. The Teleport transport
verifies host certificates against the cluster CA that `tsh config` writes into its
known_hosts file.

### What you need

- **Controller**: `ansible-core` 2.15+, `tsh` and `tctl` matching the cluster, `jq`.
- **A Teleport user** with a role like `teleport-resources/role-fleet-onboarding-operator.yaml`:
  token create/read/update/delete, node and instance read, and a login on hosts labelled
  `lifecycle: provisioning`. `tctl nodes ls` and `tsh ls` only show nodes your roles can
  access, so the role's `node_labels` must match the labels you stamp.
- **Hosts**: any Linux with systemd, reachable over SSH as a sudo user (key, or password
  with `--ask-pass --ask-become-pass`), with outbound HTTPS to the proxy and to the
  download source (`cdn.teleport.dev` or your mirror).

Unattended runs (a CI runner, a scheduler) use a Machine ID bot instead of a person's
login: `teleport-resources/bot-fleet-onboarder.yaml`, `controller/tbot.yaml`, and
`-e teleport_controller_identity=bot`. Everything else is identical.

## How it works

```
OpenSSH  ──► 00 preflight   fail fast per host; learn which version the cluster advertises
OpenSSH  ──► 10 enrol       one token per host, teleport-update enable, write /etc/teleport.yaml, start;
                            then one wait for the fleet to register, delete each one-time secret, remove the tokens
Teleport ──► 20 verify      read-only: updater on and in the right group, labels present, fleet summary
Teleport ──► 30 harden      stop and disable OpenSSH, in batches (unit files stay)
```

Verify and harden connect *through Teleport*: a first play writes the `tsh config`
output to `controller/.tsh-ssh.cfg`, then `ansible_host` becomes `<node>.<cluster>` and
`-F` points at that file. OpenSSH is switched off by a play that could only reach the
host because Teleport already works; a host whose Teleport path is broken is skipped
and keeps OpenSSH.

| Question | Answer |
|---|---|
| How is the agent installed? | Download the small `teleport-update` tarball (17 MB) for the version the cluster advertises, run `teleport-update enable --proxy … --group …`, and let the updater install the full agent, write `teleport.service` and keep the agent current. Version and edition come from `/v1/webapi/find`; the repo carries no version pin. The only host requirement is systemd. |
| Why not the apt/yum repositories? | They install a second copy of the binary that the updater then takes over. Needless for agents. |
| Why not pipe the cluster's install script? | It hardcodes `cdn.teleport.dev` and downloads the 234 MB agent tarball twice. Doing the steps in Ansible makes the download source a variable, so an internal mirror is one line ([docs/mirror.md](docs/mirror.md)). |
| Which join method? | `bound_keypair`, one token per host: the token binds to the host's keypair at first join, the registration secret works once, and the token is removed after the join (it would expire after 15 minutes anyway). |
| Why render `/etc/teleport.yaml` instead of `teleport node configure`? | The CLI cannot emit the `bound_keypair` block, the `commands` labels, or `enhanced_recording`. |
| What about a root compromise on a node? | [docs/threat-model.md](docs/threat-model.md). |

## Day two

| Task | Command |
|---|---|
| Reclassify a host (team, service, tier, lifecycle) | `ansible-playbook -i … playbooks/labels.yml --limit web-01 -e '{"teleport_class_labels":{...}}'` ([docs/labels.md](docs/labels.md)) |
| Onboard more hosts later | add them to the inventory and run `site.yml --limit <new hosts>`; enrolled hosts are skipped |
| Use an internal artifact mirror | `playbooks/mirror-sync.yml` to populate it, set `teleport_download_base_url`, re-run `playbooks/10-enroll.yml -e transport=teleport` ([docs/mirror.md](docs/mirror.md)) |
| Put hosts in a Managed Updates group | `teleport_update_group: staging`, re-run `playbooks/10-enroll.yml -e transport=teleport` (groups: `teleport-resources/autoupdate-config-groups.yaml`) |
| Remove Teleport and bring OpenSSH back | `ansible-playbook -i … playbooks/unenroll.yml --limit web-01` |
| Re-join a host with a fresh identity | `-e teleport_force_rejoin=true -e transport=teleport` on `10-enroll.yml` |

All variables and their defaults: `roles/teleport_node/defaults/main.yml`.

## Labels

Every node gets a trust tier (`env`, `site`), a classification (`team`, `service`,
`tier`, `lifecycle`, `onboarded-by`) and dynamic facts (`arch`, `kernel`, `distro`).
Classification changes with `labels.yml` and an agent reload; the trust tier changes by
re-enrolling. [docs/labels.md](docs/labels.md).

## Layout

```
site.yml                  00 → 10 → 20 → 30
playbooks/                preflight, enrol, verify, harden, labels, unenroll, mirror-sync
roles/teleport_node/      one role; playbooks pick task files with tasks_from
vars/transport-*.yml      the OpenSSH ↔ Teleport connection switch
inventory/example.yml     the inventory shape; copy it and point it at your hosts
controller/               tbot config for an unattended controller (the tsh ssh config lands here too)
teleport-resources/       roles, bot, reference cluster settings (applied by hand)
lab/proxmox/              optional: throwaway VMs on Proxmox and a narrated run
docs/                     concepts, manual walkthrough, labels, mirror, threat model, lab
```

## License

Apache-2.0. See [LICENSE](LICENSE).
