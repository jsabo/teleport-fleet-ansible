# Threat model: a root compromise on an enrolled node

Assume an attacker has root on one enrolled Linux server. Root owns everything on that
machine, including the Teleport agent, its configuration and its identity. The question
is what that buys the attacker beyond the machine they already hold, and what this repo
does to keep the answer small. Behaviour below is as documented and observed on
Teleport 18.11.

## What root on one node reaches

| If the attacker... | What limits it | What this repo does |
|---|---|---|
| **Changes the node's labels** to look like a more trusted host | Labels are reported by the agent itself, so the cluster accepts what the node says about itself. Roles that match on labels then match the forged ones. | Roles for sensitive fleets match on the trust labels (`env`, `site`) together with the team label, not on the team label alone ([labels.md](labels.md)). Immutable labels close this fully (below). |
| **Pretends to be a different node** | The cluster ties a node's record to the identity it joined with; one agent cannot announce itself under another node's identity. | Nothing needed. |
| **Reuses the join token** to enrol more machines with labels of their choosing | A plain shared token can enrol any number of hosts until it expires. | One token per host, bound to that host's keypair at the first join, valid for fifteen minutes, and the one-time secret is deleted from the host right after the join. A restart needs no token: the agent keeps its identity in its data directory. |
| **Copies the agent's identity** to another machine | Host identities are long-lived; a stolen one keeps working until it is locked or the Host CA is rotated. | Kill switch: `tctl lock --server-id <uuid>`. Permanent fix: `tctl auth rotate` for the Host CA. The bound keypair also refuses a re-registration from a second machine once its recovery limit is spent. |
| **Alters or deletes a session recording** before it uploads | In the default recording mode the recording is buffered on the node's own disk until the session ends. | `teleport-resources/session-recording-config-node-sync.yaml` switches the cluster to streaming events live; pair it with the role option `record_session.ssh: strict`. Cluster-wide; apply by hand. |
| **Disables enhanced recording or PAM** mid-session | Both run inside the agent process that root controls. | Treat enhanced recording as a detection aid against non-root users, not as a control against root. |
| **Pivots** with port forwarding or **exfiltrates** with file copy | Allowed unless the node's configuration says otherwise. | `port_forwarding: false` and `ssh_file_copy: false` on every node (role variables). |

The short version: root on a node can lie about that node and can misuse that node's
sessions. It cannot become another node, and with per-host bound tokens it cannot mint
more nodes. The remaining gap is label trust, which is what immutable labels are for.

## The controls, in the order you would use them in an incident

1. `tctl lock --server-id <host uuid>` cuts the node off immediately.
2. `tctl lock --join-token <token name>` if a token may have leaked; host certificates
   record the token they joined with.
3. `tctl auth rotate` for the Host CA invalidates a stolen identity for good.
4. `tctl rm node/<uuid>` on its own achieves nothing while the agent is running: the
   node re-heartbeats within seconds unless it is locked. The reverse also holds: a node
   record outlives its agent by up to fifteen minutes, so a decommissioned host stays
   listed until `tctl rm` removes it (the unenrol playbook does this).

## Immutable labels (roadmap)

Teleport is adding labels that travel inside the host certificate rather than in the
agent's configuration: a scoped join token carries them, the cluster stamps them into the
identity at the join, checks them on every heartbeat, and lets them override whatever
the agent reports. A node then cannot relabel itself, and a single-use token gives the
one-host guarantee without a bound keypair.

The feature is present in 18.11 behind a flag that marks it as not ready for production
and that Cloud tenants cannot set. When it ships, `teleport_trust_labels` becomes the
token's label set and nothing else in the label contract changes.
