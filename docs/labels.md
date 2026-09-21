# Labels: what the playbooks stamp on a node, and how to change it later

Teleport authorizes SSH access by matching a role's `node_labels` against the labels a
node carries. These playbooks stamp every node with a standard set at enrolment so a
fleet can be onboarded first and segmented later, without re-enrolling.

## Three classes of label

| Class | Labels | Where set | How it changes later |
|---|---|---|---|
| **Trust tier** | `env`, `site` | `teleport_trust_labels` (group vars) | Re-enrol (`unenroll.yml`, then `site.yml`). |
| **Classification** | `team`, `service`, `tier`, `lifecycle`, `onboarded-by` | `teleport_class_labels` (group or host vars) | `playbooks/labels.yml` rewrites the config and reloads the agent. |
| **Facts** | `arch`, `kernel`, `distro` | `commands:` in the agent config | Refresh themselves on a period (1 h for kernel, 24 h for the rest). |

Static labels are read by the agent once at start. `labels.yml` therefore reloads the
service after writing the file: the unit that `teleport-update` installs maps `reload`
to SIGHUP, and the agent forks a child that re-reads the configuration and takes over
without dropping sessions.

## Why the trust tier is separate

Where a host sits (`env: prod`, `site: dc1`) is a placement decision, not a
classification. Two consequences:

1. Roles that grant sensitive access should pin the trust tier, not only the team.
   `node_labels: {env: prod, team: payments}` cannot be satisfied by a lab host that
   someone labelled `team: payments`.
2. Teleport 18 ships a mechanism for labels that a node cannot change about itself:
   labels assigned by a scoped join token are hashed into the host certificate and
   checked on every heartbeat. It is not yet enabled on Teleport Enterprise (Cloud)
   tenants. When it is, the trust tier is the set that moves onto the token, and nothing
   else in this repo has to change. See [threat-model.md](threat-model.md).

## Reclassifying a host

```bash
ansible-playbook playbooks/labels.yml --limit web-01 \
  -e '{"teleport_class_labels":{"team":"payments","service":"api","tier":"internal","lifecycle":"active","onboarded-by":"ansible"}}'
```

Within about ten seconds `tctl nodes ls` shows the new labels and the host UUID is
unchanged. Access follows immediately:

- A role with `allow.node_labels: {env: prod, team: payments}` now matches the host.
  Grant that role through an Access List and membership reviews govern who is on it.
- The onboarding role matches `lifecycle: provisioning` only, so the moment a host is
  classified `active` the onboarding identity (operator or bot) can no longer reach it.
  The tool that enrolled the fleet loses access to it by design.

## Suggested lifecycle values

| `lifecycle` | Meaning |
|---|---|
| `provisioning` | Enrolled, not yet classified. Reachable by the onboarding role. |
| `active` | Classified and in service. |
| `decommissioning` | Scheduled for removal; roles can exclude it. |
