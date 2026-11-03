# teleport-fleet-ansible

Move a fleet of Linux servers from OpenSSH to Teleport. Point the playbooks at your own
Ansible inventory and they install the Teleport agent with Managed Updates, join each
host with a token only it could use, stamp a standard set of labels for segmentation,
verify access through the Teleport proxy, and switch OpenSSH off.

Verified against Teleport 18.11 (Teleport Enterprise Cloud) on Ubuntu 24.04 and
Rocky Linux 9; the playbooks run unchanged on both.

New to this? [docs/concepts.md](docs/concepts.md) explains an agent, a join token,
Managed Updates and labels in ten minutes, and
[docs/manual-walkthrough.md](docs/manual-walkthrough.md) does one host by hand so you can
see what the playbooks automate.

## What each host ends up with

- The Teleport agent, installed and kept current by Managed Updates. No version is
  pinned in this repo; the cluster decides which one the host runs.
- A host identity of its own, stored in `/var/lib/teleport`. Its join token was usable
  once, by that host, and is deleted afterwards.
- `/etc/teleport.yaml` carrying its labels, with port forwarding and file copy both off.
- OpenSSH stopped and disabled. Nothing is masked or uninstalled, so a console can turn
  it back on.

## Before you start

**On the controller** — your laptop or a CI runner: `ansible-core` 2.15 or later, `tsh`
and `tctl` matching the cluster, and `jq`.

**A Teleport role that can onboard hosts.**
`teleport-resources/role-fleet-onboarding-operator.yaml` is the reference: create, read,
update and delete tokens; read nodes and instances; and a login on hosts labelled
`lifecycle: provisioning`. Its `node_labels` must match the labels you stamp, because
`tctl nodes ls` and `tsh ls` show only the nodes your roles can reach — a mismatch makes
a correctly enrolled host invisible rather than denied.

**Hosts**: any Linux with systemd, reachable over SSH as a user who can `sudo` (a key,
or a password with `--ask-pass --ask-become-pass`), with outbound HTTPS to the proxy and
to the download source (`cdn.teleport.dev`, or your own mirror).

For an unattended controller, swap the person's login for a Machine ID bot:
`teleport-resources/bot-fleet-onboarder.yaml`, `controller/tbot.yaml`, and
`-e teleport_controller_identity=bot`. Everything else is identical.

## Run it

```bash
ansible-galaxy collection install -r requirements.yml
cp inventory/example.yml inventory/fleet.yml
tsh login --proxy=example.teleport.sh:443
ansible-playbook -i inventory/fleet.yml site.yml
```

Edit `inventory/fleet.yml` before that last command. Three variables decide the rest:

| Variable | What it sets |
|---|---|
| `teleport_proxy` | Your cluster's address. Hosts are reached through Teleport at `<node>.<this address without its port>`, which is the name `tsh config` writes a Host block for. |
| `teleport_ssh_login` | The login the playbooks use once a host is on Teleport. It must exist on the hosts and be granted by your role. |
| `teleport_trust_labels` | The `env` and `site` labels each group of hosts gets. These are what your access roles match on later. |

Each host is reached over OpenSSH at its `ip:` variable, or at its inventory name if that
resolves. Do not set `ansible_host` — the playbooks derive it per phase. Any inventory
format works: YAML, INI, or a dynamic source. Every other variable has a default in
`roles/teleport_node/defaults/main.yml`.

## The four phases

`site.yml` runs all four in order. Each is also a playbook you can run on its own, so you
can stop and look between them.

| Phase | Connects over | What it does | What to look at |
|---|---|---|---|
| `00-preflight.yml` | OpenSSH | Checks each host (systemd, architecture, hostname, clock, disk) and the controller (your login, one `tctl` call), then learns which agent version the cluster advertises. Nothing is installed. | A failing host drops out and the rest continue |
| `10-enroll.yml` | OpenSSH | Mints one token per host, installs the agent through `teleport-update`, writes `/etc/teleport.yaml`, starts the agent. Then waits once for the whole fleet to register, deletes each one-time secret and removes each token. | `tsh ls` — the new nodes with their labels |
| `20-verify.yml` | Teleport | Read-only. Proves every host answers through the proxy, that Managed Updates are on and in the right group, and that the labels arrived. | `changed=0` and the fleet summary line |
| `30-harden.yml` | Teleport | Stops and disables OpenSSH, in batches. | `ssh <user>@<host>` refused, `tsh ssh <login>@<node>` works |

Running them one at a time:

```bash
ansible-playbook -i inventory/fleet.yml playbooks/00-preflight.yml
ansible-playbook -i inventory/fleet.yml playbooks/10-enroll.yml
tsh ls
ansible-playbook -i inventory/fleet.yml playbooks/20-verify.yml
ansible-playbook -i inventory/fleet.yml playbooks/30-harden.yml
```

**The last two phases connect through Teleport on purpose.** A first play writes the
`tsh config` output to `controller/.tsh-ssh.cfg`; `ansible_host` then becomes
`<node>.<cluster>` and `-F` points at that file. So OpenSSH is switched off by a play
that could only reach the host because Teleport already works. A host whose Teleport path
is broken is simply not reached, and keeps OpenSSH.

## How long it takes

Measured on three hosts (two Ubuntu 24.04, one Rocky 9) against Teleport 18.11.1, with
the per-task profile and timer that `ansible.cfg` enables (`ansible.posix.profile_tasks`,
`ansible.posix.timer`; every run ends with a slowest-tasks list and a total):

| Phase | Time | Where it goes |
|---|---|---|
| 00 preflight | 7 s | facts, six asserts, two HTTPS checks per host, the controller checks (`tsh status`, one `tctl` call) |
| 10 enroll | 50 s | `teleport-update enable` (downloads and installs the agent, ~12 s), the agent's first join (~10 s), one wait for all node records (~6 s), three fleet-wide `tctl` calls and one token removal per host |
| 20 verify | 4 s | read-only; a second run reports `changed=0` |
| 30 harden | 4 s | two batches (`serial: [2, 10, "25%"]`) |

Hosts install in parallel, so a larger fleet costs little more wall-clock time. The
controller makes three `tctl` calls for the whole fleet (create the tokens, read the
secrets, read the bindings) and one `tctl tokens rm` per host, which run in parallel.
The controller checks and the Teleport ssh config are done once per run; a playbook run
on its own adds about 4 s for them.

## Host keys are checked on both transports

The OpenSSH transport accepts a host's key on first contact and refuses a changed one
afterwards (`StrictHostKeyChecking=accept-new`), so a rebuilt host needs
`ssh-keygen -R <address>` before it is enrolled again. The Teleport transport verifies
host certificates against the cluster certificate authority that `tsh config` writes into
its `known_hosts` file.

## Labels

Every node gets a trust tier (`env`, `site`), a classification (`lifecycle`,
`onboarded-by`) and dynamic facts (`arch`, `kernel`, `distro`).
Classification changes with `labels.yml` and an agent reload; the trust tier changes by
re-enrolling. [docs/labels.md](docs/labels.md).

## After the fleet is onboarded

| Task | Command |
|---|---|
| Reclassify a host (team, service, tier, lifecycle) | `ansible-playbook -i … playbooks/labels.yml --limit web-01 -e '{"teleport_class_labels":{...}}'` ([docs/labels.md](docs/labels.md)) |
| Onboard more hosts later | add them to the inventory and run `site.yml --limit <new hosts>`; enrolled hosts are skipped |
| Use an internal artifact mirror | `playbooks/mirror-sync.yml` to populate it, set `teleport_download_base_url`, re-run `playbooks/10-enroll.yml -e transport=teleport` ([docs/mirror.md](docs/mirror.md)) |
| Put hosts in a Managed Updates group | `teleport_update_group: staging`, re-run `playbooks/10-enroll.yml -e transport=teleport` (groups: `teleport-resources/autoupdate-config-groups.yaml`) |
| Remove Teleport and bring OpenSSH back | `ansible-playbook -i … playbooks/unenroll.yml --limit web-01` |
| Re-join a host with a fresh identity | `-e teleport_force_rejoin=true -e transport=teleport` on `10-enroll.yml` |

All variables and their defaults: `roles/teleport_node/defaults/main.yml`.

## Why it works this way

| Question | Answer |
|---|---|
| How is the agent installed? | Download the small `teleport-update` tarball (17 MB) for the version the cluster advertises, run `teleport-update enable --proxy … --group …`, and let the updater install the full agent, write `teleport.service` and keep the agent current. Version and edition come from `/v1/webapi/find`; the repo carries no version pin. The only host requirement is systemd. |
| Why not the apt or yum repositories? | They install a second copy of the binary that the updater then takes over. Needless for agents. |
| Why not pipe the cluster's install script? | It hardcodes `cdn.teleport.dev` and downloads the 234 MB agent tarball twice. Doing the steps in Ansible makes the download source a variable, so an internal mirror is one line ([docs/mirror.md](docs/mirror.md)). |
| Which join method? | `bound_keypair`, one token per host: the token binds to the host's keypair at first join, the registration secret works once, and the token is removed after the join (it would expire after 15 minutes anyway). |
| Why render `/etc/teleport.yaml` instead of running `teleport node configure`? | The command cannot emit the `bound_keypair` block, the `commands` labels, or `enhanced_recording`. |
| What can root on a node still do? | [docs/threat-model.md](docs/threat-model.md), which also covers what happens to a host that loses its identity. |

## Learning it before automating it

- **The concepts in plain words** — what an agent, a join token, Managed Updates and
  labels are, in ten minutes: [docs/concepts.md](docs/concepts.md).
- **One host by hand**, one command at a time, so you see what the playbooks automate:
  [docs/manual-walkthrough.md](docs/manual-walkthrough.md).
- **Throwaway VMs to practise on**, if you have a Proxmox server: `lab/proxmox/` creates
  a fleet, runs the whole flow with an explanation before each step, and tears it down
  again ([docs/lab-proxmox.md](docs/lab-proxmox.md)). Optional; nothing else depends on it.

## Layout

```
site.yml                  00 → 10 → 20 → 30
playbooks/                preflight, enroll, verify, harden, labels, unenroll, mirror-sync
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
