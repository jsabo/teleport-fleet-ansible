# Lab: onboard a fresh fleet, every time

The `lab/proxmox/` playbooks create fresh VMs on a Proxmox server, run the whole flow,
and tear everything down, so you can practise on a clean slate as often as you like.
This is optional: the tool itself needs only your inventory. Any other way of
producing three throwaway Linux VMs works just as well; only `up.yml`, `down.yml` and
the Terraform files are Proxmox-specific.

Everything is Ansible: Terraform runs through the `community.general.terraform` module.

## One-time setup

1. `cp lab/proxmox/vars.yml.example lab/proxmox/vars.yml` and fill in the Proxmox endpoint and API
   token, the Teleport proxy, and your SSH key paths. The token needs VM create/destroy
   rights plus `Sys.AccessNetwork` on the node (Proxmox downloads the cloud images
   itself). `lab/proxmox/vars.yml` is gitignored.
2. `ansible-galaxy collection install -r requirements.yml`.
3. `tsh login --proxy=<proxy>`. Your roles must grant the login in `teleport_ssh_login`
   (default `root`) on nodes carrying the lab labels (`env: <lab_env_label>`,
   `onboarded-by: ansible`). `tctl nodes ls` and `tsh ls` only show nodes your roles can
   access, so pick `lab_env_label` to match a role you hold.

## The loop

```bash
ansible-playbook lab/proxmox/up.yml                                   # ~1 min (first time ~2 min: image download), 3 VMs, inventory, wait for SSH
ansible-playbook -i inventory/lab.yml lab/proxmox/run.yml -e lab_pause=true   # narrated: each step explains itself, Enter to run it
ansible-playbook -i inventory/lab.yml lab/proxmox/show.yml           # cluster and host view at any time
ansible-playbook lab/proxmox/reset.yml                                # fresh VMs: down, then up
ansible-playbook lab/proxmox/down.yml                                 # shut the VMs down, remove their node records
```

Or drive it by hand, one playbook per step, and look around between them:

```bash
ansible-playbook -i inventory/lab.yml playbooks/00-preflight.yml
ansible-playbook -i inventory/lab.yml playbooks/10-enroll.yml
tsh ls                                                         # the three nodes appear with their labels
tctl get token/<name>                                          # (during enrol) bound_host_id fills in at the join
ansible-playbook -i inventory/lab.yml playbooks/20-verify.yml
ansible-playbook -i inventory/lab.yml playbooks/30-harden.yml
ssh ansible@<ip>                                               # refused
tsh ssh root@fleet-ubuntu-1                                    # works
```

Fresh VMs each time: `reset.yml` recreates the disks from the downloaded cloud images
(about three and a half minutes for the full destroy, recreate and onboard cycle,
measured: VMs up in 45 s with the images already on the datastore, the four phases in
1 min 15 s, teardown in 1 min 15 s to 1 min 30 s, most of it the probe that proves the
agents are gone). Two Ubuntu 24.04 hosts and one Rocky Linux 9 host by default
(`lab/proxmox/variables.tf`).

## Beats

| Step | What to say | What to show |
|---|---|---|
| `up` | Three plain Linux servers with OpenSSH and a cloud-init user. Nothing else. | the ping at the end of `up.yml` |
| 00 preflight | Fail fast: systemd, architecture, hostname, clock, disk, reachability of the proxy and of the exact artifact. One shape of check for Ubuntu and Rocky. | the controller guard: tctl targets the active login, so a stale profile is caught here |
| 10 enrol | One bound token per host. Each host downloads the small updater tarball, `teleport-update enable` installs the advertised version and sets up Managed Updates, the agent starts. One wait for the fleet to register, then each one-time secret is deleted and each token removed. | `show.yml`: nodes, labels, updater and group |
| 20 verify | Ansible now connects *through Teleport*. Read-only checks: updater enabled and in the right group, labels present. | `changed=0` and the fleet summary line |
| 30 harden | Also through Teleport, in batches. OpenSSH is stopped and disabled; unit files stay. A host that Teleport could not reach would have kept OpenSSH. | `ssh ansible@<ip>` refused; `tsh ssh root@fleet-ubuntu-1` works |
| reclassify | `labels.yml` moves one host to `team: payments, lifecycle: active`. Access follows the labels. | `tctl nodes ls`; `journalctl -u teleport` shows the SIGHUP reload |
| kill switch | `tctl lock --server-id <uuid>`, then `tctl rm` (which alone does nothing). | `tsh ssh` denied |
| mirror | Same flow with a fourth VM serving the artifacts over HTTPS from a private CA, and `cdn.teleport.dev` unreachable from the fleet. | the mirror's access log: updater tarball and agent tarball with checksums, per host |

## Headless controller (bot)

The same flow without a human login, the way a CI runner would do it:

```bash
tctl create -f teleport-resources/bot-fleet-onboarder.yaml
tctl get token/fleet-onboarder-bound-keypair --with-secrets --format=json | jq -r '.[0].status.bound_keypair.registration_secret'
cp controller/tbot.yaml controller/tbot.local.yaml        # set proxy_server and the secret; gitignored
tbot start -c controller/tbot.local.yaml &                # writes controller/tbot-out/{identity,ssh_config}
ansible-playbook -i inventory/lab.yml lab/proxmox/run.yml -e teleport_controller_identity=bot
```

The bot's role reaches only hosts labelled `onboarded-by: ansible, lifecycle: provisioning`
and never `env: prod`. Remove the secret from `tbot.local.yaml` after the first join; the
keypair in `controller/.tbot-store` is the identity from then on.

## Mirror variant

```bash
ansible-playbook lab/proxmox/up.yml -e lab_mirror=true
ansible-playbook -i inventory/lab.yml lab/proxmox/mirror.yml          # sync artifacts, provision fleet-mirror
ansible-playbook -i inventory/lab.yml lab/proxmox/run.yml -e lab_pause=true
```

`up.yml -e lab_mirror=true` adds the `fleet-mirror` VM and writes an inventory whose
group vars point the fleet at `https://<mirror ip>/teleport`, install the mirror's CA, and
add one `/etc/hosts` line: `cdn.teleport.dev` to `127.0.0.1`. `mirror.yml` syncs the artifacts to
`lab/proxmox/.mirror/teleport` with `playbooks/mirror-sync.yml`, then provisions nginx and a
private CA on the mirror VM.

## Cleaning up

`down.yml` stops the agents through Teleport (hosts it cannot reach are skipped),
waits until Teleport can no longer reach each host, destroys the VMs, removes any node
records still carrying `onboarded-by=ansible` and the lab site label, and deletes the
generated inventory. The downloaded cloud images stay on the Proxmox datastore so the
next `up.yml` does not fetch them again; `-e lab_keep_images=false` removes them too.

Stopping the agents first matters. A node record outlives its agent by up to 15
minutes, and while the Auth Service still holds the agent's control stream it
re-creates a record that `tctl rm` deleted. Measured against Teleport 18.11: an agent
that exits on its own closes the stream at once and the record stays deleted; a VM
killed (or powered off) with the agent still connected leaves the stream open for about
four minutes, and the record comes back after every deletion in that window. A stale
record with the same name makes `tsh ssh <name>` ambiguous for the next fleet; the
playbooks are unaffected because they address hosts by UUID, the manual walkthrough
is not. The stop runs through the agent itself, so it is scheduled five seconds ahead
with a transient systemd timer, Ansible drops its connection, and a `tsh ssh` probe
must fail before the VMs are destroyed. The failing probe is the slow part of the
teardown: once the tunnel is gone the proxy falls back to dialling the node's own
address and gives up after about a minute. `up.yml` removes any leftovers again before
creating VMs. Any token a broken run left behind expires on its own within 15 minutes.
