# Threat model: a root compromise on an enrolled node

Assume an attacker has root on one enrolled Linux server. Root owns everything on that
machine, including the Teleport agent, its configuration and its identity. The question
is what that buys the attacker beyond the machine they already hold, and what this repo
does to keep the answer small. Behaviour below is as documented and observed on
Teleport 18.11.

## What root on one node reaches

| If the attacker... | What limits it | What this repo does |
|---|---|---|
| **Changes the node's labels** to look like a more trusted host | Labels are reported by the agent itself, so the cluster accepts what the node says about itself. Roles that match on labels then match the forged ones. | Roles for sensitive fleets match on the trust label (`env`) together with the team label, not on the team label alone ([labels.md](labels.md)). Immutable labels close this fully (below). |
| **Pretends to be a different node** | The cluster ties a node's record to the identity it joined with; one agent cannot announce itself under another node's identity. | Nothing needed. |
| **Reuses the join token** to enroll more machines with labels of their choosing | A plain shared token can enroll any number of hosts until it expires. | One token per host, bound to that host's keypair at the first join, valid for fifteen minutes, and the one-time secret is deleted from the host right after the join. A restart needs no token: the agent keeps its identity in its data directory. |
| **Copies the agent's identity** to another machine | Host identities are long-lived; a stolen one keeps working until it is locked or the Host CA is rotated. | Kill switch: `tctl lock --server-id <uuid>`. Permanent fix: `tctl auth rotate` for the Host CA. The bound keypair also refuses a re-registration from a second machine once its recovery limit is spent. |
| **Alters or deletes a session recording** before it uploads | In the default recording mode the recording is buffered on the node's own disk until the session ends. | `teleport-resources/session-recording-config-node-sync.yaml` switches the cluster to streaming events live; pair it with the role option `record_session.ssh: strict`. Cluster-wide; apply by hand. |
| **Disables enhanced recording or PAM** mid-session | Both run inside the agent process that root controls. | Treat enhanced recording as a detection aid against non-root users, not as a control against root. |
| **Pivots** with port forwarding or **exfiltrates** with file copy | Allowed unless the node's configuration says otherwise. | `port_forwarding: false` and `ssh_file_copy: false` on every node (role variables). |

The short version: root on a node can lie about that node and can misuse that node's
sessions. It cannot become another node, and with per-host bound tokens it cannot mint
more nodes. The remaining gap is label trust, which is what immutable labels are for.

### A host that loses its identity has to be enrolled again

The protection above has an operational cost worth planning for. Each token allows one
recovery — a join by a host that holds the bound keypair but no longer has a valid
identity — and the first join spends it. The playbooks then delete the token outright.

So a host whose identity is gone cannot rejoin on its own. It asks for a recovery and the
cluster answers `no recovery attempts remaining`. Three ordinary events get you there:
restoring a machine from a snapshot taken before it enrolled, rebuilding it, or losing
`/var/lib/teleport`. A running agent that simply restarts is unaffected — it reuses the
identity in its data directory and never asks.

The fix is to enroll the host again, which mints it a fresh token:

```bash
ansible-playbook -i inventory/fleet.yml playbooks/10-enroll.yml --limit web-01 \
  -e teleport_force_rejoin=true
```

That runs over OpenSSH, because a host with no identity is not reachable through Teleport.
On a host that has already been hardened, OpenSSH is stopped and disabled, so neither
transport can reach it: start `ssh.socket` (Debian) or `sshd.socket` (RHEL) from the
console first. Nothing is masked or uninstalled, which is why that is possible. The same
command with `-e transport=teleport` is for the other case — a host that is still working
and reachable, which you want to move onto a fresh identity.

This is the right trade for a fleet: a token that still works after an outage is also a
token an attacker can replay from a copy of the keypair. The controller's own bot token is
set the other way (`recovery.mode: relaxed` in
[bot-fleet-onboarder.yaml](../teleport-resources/bot-fleet-onboarder.yaml)) because it runs
on a laptop or a runner that regularly sleeps past its certificate lifetime, and a
controller that cannot log in blocks every run.

## The controls, in the order you would use them in an incident

1. `tctl lock --server-id <host uuid>` cuts the node off immediately.
2. `tctl lock --join-token <token name>` if a token may have leaked; host certificates
   record the token they joined with.
3. `tctl auth rotate` for the Host CA invalidates a stolen identity for good.
4. `tctl rm node/<uuid>` on its own achieves nothing while the agent is running: the
   node re-heartbeats within seconds unless it is locked. The reverse also holds: a node
   record outlives its agent by up to fifteen minutes, so a decommissioned host stays
   listed until `tctl rm` removes it (the unenroll playbook does this).

## Immutable labels (roadmap)

Teleport is adding labels that travel inside the host certificate rather than in the
agent's configuration: a scoped join token carries them, the cluster stamps them into the
identity at the join, checks them on every heartbeat, and lets them override whatever
the agent reports. A node then cannot relabel itself, and a single-use token gives the
one-host guarantee without a bound keypair.

The feature is present in 18.11 behind a flag that marks it as not ready for production
and that Cloud tenants cannot set. When it ships, `teleport_trust_labels` becomes the
token's label set and nothing else in the label contract changes.
