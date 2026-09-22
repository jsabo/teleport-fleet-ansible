# Threat model: a root compromise on an enrolled node

Assume an attacker has root on one enrolled Linux server. What can they do with the
Teleport agent on it, and what does this repo do about it? Facts below were checked
against Teleport v18.11.0 source; file references are to that tag.

## What the attacker can and cannot do

| Attempt | Outcome in 18.11 | Control in this repo |
|---|---|---|
| **Relabel the node** to match a higher-trust role (edit `ssh_service.labels`, restart) | Works. Labels are self-reported in heartbeats and the Auth Service validates ownership, not content (`lib/srv/regular/sshserver.go:1225-1245`, `lib/auth/auth_with_roles.go:1119-1140`). The node's built-in role can also read every node, user and role, so the attacker can see which labels to forge. | Roles for sensitive fleets pin the trust tier (`env`, `site`) as well as the team ([labels.md](labels.md)). Immutable labels are the real fix (below). |
| **Impersonate another node** | Fails. The resource name must equal the agent's own host UUID (`lib/authz/scoped.go:370-372`, `lib/inventory/controller.go:966-968`). | none needed |
| **Reuse the join token** to enrol rogue nodes with any labels | Would work with a shared token: host join tokens are never consumed, only expired (`lib/auth/join.go:392-402`), and a token with no expiry lives forever. | One token per host, bound to that host's keypair (`bound_keypair`), expiring after 1 h, and the registration secret is deleted from the host right after the join. A restart needs no token: the identity lives in `<data_dir>/proc` (`lib/service/connect.go:183-198`). |
| **Copy the host identity** to another machine | The SSH host certificate never expires and the TLS host certificate is valid for ten years (`lib/sshca/identity.go:168-172`, `lib/defaults/defaults.go:703`). | Kill switch: `tctl lock --server-id <uuid>`. Permanent fix: Host CA rotation (`tctl auth rotate`). `bound_keypair` in `standard` mode also refuses a re-registration from a second machine once the recovery limit is spent. |
| **Alter or delete a session recording** before it uploads | Works in the default `node` recording mode: the recording is buffered under `<data_dir>/log/upload/streaming/` on the attacker's disk (`lib/events/recorder/recorder.go:129-138`). | `teleport-resources/session-recording-config-node-sync.yaml` (`mode: node-sync` streams events live) plus role option `record_session.ssh: strict`. Cluster-wide; apply by hand. |
| **Kill BPF or PAM mid-session** | Works; both run inside the agent process. | Enhanced recording stays a detection aid against non-root users, not a root control. |
| **Pivot** with TCP forwarding, exfiltrate with SCP | Allowed by default. | `port_forwarding: false`, `ssh_file_copy: false` on every node (variables). |

## The controls, in the order you would use them in an incident

1. `tctl lock --server-id <host uuid>` cuts the node off immediately.
2. `tctl lock --join-token <token name>` if a token may have leaked (host certificates
   record the token they joined with).
3. `tctl auth rotate` for the Host CA invalidates the stolen identity for good.
4. `tctl rm node/<uuid>` on its own achieves nothing: the node re-heartbeats within
   seconds unless it is locked. The reverse also holds: a record outlives its agent by
   up to 15 minutes, so a decommissioned host stays listed until `tctl rm` removes it
   (the unenrol playbook does this).

## Immutable labels (roadmap)

Teleport 18.11 already contains the mechanism: a *scoped* join token can carry
`immutable_labels`; their hash is placed in the host certificate, checked when the
agent registers its control stream (`lib/auth/auth_with_roles.go:894-899`) and on every
heartbeat (`lib/inventory/controller.go:981-983`), and they override static and dynamic
labels wherever labels are read (`api/types/server.go:443-459`). The CLI exists:

```bash
tctl scoped tokens add --type=node --mode=single_use --ssh-labels=env=prod,site=dc1
```

Joining with such a token requires `TELEPORT_UNSTABLE_SCOPES=yes` on the Auth Service
(`lib/scopes/feature.go:32,50`), which a Cloud tenant cannot set and which the flag
itself labels "not ready for production use". When it ships, `teleport_trust_labels`
becomes the `--ssh-labels` set and `single_use` replaces the bound keypair as the
one-host guarantee. Nothing else in the label contract changes.
