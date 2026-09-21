# Concepts: what changes when a server moves from OpenSSH to Teleport

Read this once before the walkthrough. Each term is defined the first time it appears.

## What you are replacing

With OpenSSH, every server runs `sshd`, trusts a list of public keys per user, and is
reached directly or through a bastion. Who can log in is decided by files on each host
(`authorized_keys`), access is by long-lived keys, and there is no central record of who
did what.

With Teleport, every server runs the **Teleport agent** (the `teleport` binary with its
SSH Service enabled). The agent does not listen for inbound connections; it opens an
outbound tunnel to the **Teleport Proxy**, the cluster's single public endpoint. Users
log in once (`tsh login`) with single sign-on and receive a short-lived certificate;
`tsh ssh user@host` goes to the proxy, the proxy checks the user's roles, and the
session is relayed down the agent's tunnel and recorded. Nothing about who may log in
lives on the host any more. Once the agent works, `sshd` can be switched off.

## The pieces

| Piece | What it is | Where it lives |
|---|---|---|
| **Proxy** | The cluster's front door: terminates user connections and agent tunnels. `example.teleport.sh:443` | Cloud tenant or your own cluster |
| **Auth Service** | Issues certificates, stores the cluster state (nodes, roles, tokens), keeps the audit log | Behind the proxy; agents never need to reach it directly |
| **Agent** | `teleport start --config /etc/teleport.yaml` with `ssh_service.enabled: true`. Dials the proxy, heartbeats its labels, runs sessions as the requested local user | Every server; `/var/lib/teleport` is its state |
| **Host identity** | The certificate the agent receives when it joins. Stored under `/var/lib/teleport/proc`; restarts reuse it, so the join token is needed once | On the server |
| **Join token** | A one-time credential that lets a new agent request its host identity. This repo uses one token per host, `join_method: bound_keypair` | Created on the cluster with `tctl`, removed after the join |
| **Node** | The cluster's record of one agent: a UUID, the hostname, the labels | `tctl nodes ls`, `tsh ls` |
| **Labels** | Key/value pairs on the node (`env: prod`, `team: payments`). Roles grant access by matching them | In `/etc/teleport.yaml` (static) or produced by commands on a schedule (dynamic) |
| **Role** | Who may log in where, as which local user. `allow.node_labels` plus `allow.logins` | On the cluster; granted to users by the identity provider mapping or by Access Lists |
| **Managed Updates** | `teleport-update`, a small binary that installs the agent version the cluster advertises and keeps it current on a schedule the cluster controls | `/opt/teleport/default`, `teleport-update.timer` |

## The join, step by step

1. The controller creates a token on the cluster: `roles: [Node]`, `join_method:
   bound_keypair`, an expiry, and a recovery limit of one. The Auth Service answers with a
   one-time **registration secret**.
2. The secret is placed on the host (`/var/lib/teleport/registration-secret`, mode 0600)
   and `/etc/teleport.yaml` names the token and the secret's path.
3. The agent starts, generates a keypair, presents the secret, and receives its host
   identity. The Auth Service records the keypair's public half on the token
   (`status.bound_keypair.bound_host_id` = this host's UUID). The token can no longer be
   used by any other machine.
4. The agent registers: it appears in `tctl inventory ls` (every connected agent) and,
   for users whose roles match its labels, in `tctl nodes ls` and `tsh ls`.
5. The secret file is deleted and the token removed. The agent restarts from the
   identity under `/var/lib/teleport/proc` for the rest of its life.

Why `bound_keypair` and not a plain token: a plain `token` join is not consumed for
hosts, so a copied token could enrol more machines until it expires, and it cannot be
tied to one host. A bound keypair token is tied to the first machine that uses it.

## How the agent is installed and kept current

The cluster advertises the agent version it wants (`https://<proxy>/v1/webapi/find`,
field `auto_update.agent_version`). `teleport-update enable --proxy <proxy> --group <g>`
downloads that version, installs it under `/opt/teleport/default/versions/`, links the
binaries into `/usr/local/bin`, writes `teleport.service`, and installs a timer that
asks the proxy every five minutes whether this **update group** should move to a new
version. The group is a name the cluster's `autoupdate_config` orders (for example
`staging` before `production`). Nothing on the host pins a version.

## Labels are how a fleet is segmented

Roles do not name hosts; they match labels. A host stamped `env: prod, team: payments`
is reachable by anyone holding a role with `node_labels: {env: prod, team: payments}`.
Changing a host's `team` label and reloading the agent moves it to a different set of
people without touching a single role. This repo stamps a standard set at enrolment
and changes the classification later with one playbook ([labels.md](labels.md)).

## Two transports, one safety property

The enrol phase reaches hosts over OpenSSH because nothing else exists yet. Everything
after that (verify, harden, later changes) reaches hosts **through Teleport**: Ansible
connects to `<node>.<cluster>` with an ssh config that `tsh config` generates. The play
that switches OpenSSH off can therefore only run on a host that Teleport already
reaches. A host whose Teleport path is broken keeps OpenSSH.

## What "hardened" means here

`ssh.socket` and `ssh.service` (Debian family) or `sshd.service` (Red Hat family) are
stopped and disabled. The unit files stay installed, so console access can re-enable
OpenSSH with one command, and `unenroll.yml` does exactly that before removing Teleport.
