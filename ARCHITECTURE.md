# Architecture

Top-level map of the system. This file is the canonical home for the version-pin table, the deploy-pipeline summary, and the layering rules. Update it whenever a pin moves or a boundary changes.

For the current in-flight plan, see [`docs/exec-plans/active/add-nebius-target.md`](docs/exec-plans/active/add-nebius-target.md). For agent-facing operating principles, see [`CLAUDE.md`](CLAUDE.md).

## System map

```
┌──────────────────────────┐                                    ┌───────────────────────────────────────────┐
│  Host (Mac / Linux)      │                                    │  Workstation VM (single GPU)              │
│                          │                                    │                                           │
│  - editor + git          │                                    │  ┌─────────────────────────────────────┐  │
│  - isaac_automator       │   ── Terraform (cloud API) ─────►  │  │ Isaac Sim 5.0.0 (NATIVE)            │  │
│    container (./run)     │                                    │  │   installed by `workstation` role   │  │
│      ./deploy-aws        │   ── Ansible over ssh ──────────►  │  └─────────────────────────────────────┘  │
│      ./deploy-nebius 🟡  │                                    │                                           │
│      ./ssh ./start ./stop│                                    │  ┌─────────────────────────────────────┐  │
│      ./destroy ./repair  │                                    │  │ NoMachine server (TCP, port ~4000)  │  │
│      ./image-aws         │                                    │  │   installed by `remote-desktop`     │  │
│      ./image-nebius 🟡   │                                    │  └─────────────────────────────────────┘  │
│                          │                                    │                ▲                          │
│  - NoMachine client      │                                    │                │                          │
│       ▼                  │   ── NoMachine NX (TCP) ───────────│────────────────┘                          │
│                          │                                    │                                           │
│                          │                                    │  Cloud disk: deploy state, image cache   │
└──────────────────────────┘                                    └───────────────────────────────────────────┘
```

Key invariants:

- **Isaac Sim runs natively** on the VM so the NoMachine session can drive its GUI. Containerizing Isaac would defeat the GUI access the deployer is built around.
- **NoMachine is the GUI transport** — works over TCP on any cloud (it can fall back from UDP), which is what lets the fork run on clouds that block UDP (sidestepping the problem that ruled out Runpod for our sibling project). Where the cloud allows UDP, upstream opens both UDP and TCP on port 4000 for better video performance (see `src/terraform/gcp/ovkit/security.tf`); Nebius should follow the same pattern.
- **The host machine only runs the `./run` container.** Cloud APIs, Terraform, Packer, and Ansible all execute inside the container; the host has no provider CLIs installed and no Ansible state.
- **The AWS path stays a working reference.** Every Nebius change lives in new files (`src/terraform/nebius/`, `src/python/nebius.py`, `deploy-nebius`, `src/packer/nebius/`) plus one `when:` branch in the `nvidia-driver` Ansible role. AWS is the A/B baseline for hour-cost and bring-up time.

## Pinned versions (canonical)

This table is the source of truth. Anywhere else (CLAUDE.md, plans, READMEs, comments) that names a version must agree with it — update both, or update the link.

| Component | Pin | Source / notes |
|---|---|---|
| Upstream IsaacAutomator commit | `221b5d2` (v4.0.0; merged into `nebius` 2026-05-28) | Brings in `image-azure`/`image-gcp` Packer wrappers, GCP static IP (`c54374c`), cross-cloud "public IP preserved across stop/start" invariant (`26253f4`), NVIDIA driver/library mismatch reboot (`a573529`), AWS env-var credential support (`60e4695`), and the new `src/tests/` suite. |
| Isaac Sim | `5.0.0` | Installed natively by the `workstation` Ansible role. |
| NoMachine | `9.5.7_2` | Per upstream `685bc29`; mirror URL set in `src/ansible/roles/remote-desktop/defaults/main.yml`. |
| Nebius Terraform provider | `nebius/nebius` v`0.6.8` | Community-tier, pre-1.0. Pin exactly in `src/terraform/nebius/main.tf`. Expect breaking changes on upgrade. |
| Nebius default platform / preset | `gpu-l40s-a` / `1gpu-32vcpu-128gb` | Closest analogue to AWS `g6e.2xlarge`. |
| Nebius base image family | `ubuntu24.04-driverless` | NVIDIA driver installed via Ansible at bring-up. |
| Nebius `parent_id` | (user-supplied; tenant/project ID) | No default; required CLI arg on `./deploy-nebius`. |
| AWS default instance | `g6e.2xlarge` (L40S, 48 GB) | Upstream default; the cheaper fallback is `g5.2xlarge` (A10G, 24 GB). |
| Packer plug-in (Nebius) | `github.com/nebius/nebius` | Same provisioner shape as AWS Packer template. |
| Python (deployer wrappers) | 3.10+ (whatever upstream pins) | `deploy-<cloud>` scripts are `#!/usr/bin/env python3`. |

## Deploy pipeline

Every `./run ./deploy-<cloud> <name>` invocation runs the same four-stage pipeline, with the cloud-specific Python wrapper and Terraform module swapped in. The shared spine lives in `src/python/` and `src/ansible/` and must stay cloud-agnostic.

1. **`./run` wraps the host in the `isaac_automator` container.** No cloud CLIs are installed on the host. The container has `aws` / `gcloud` / `az` / `aliyun` installed by `Dockerfile`; Nebius work adds `nebius` to that list.
2. **`deploy-<cloud>` (Python) validates credentials and shells to Terraform.** Each wrapper imports `<cloud>_validate_credentials()` from `src/python/<cloud>.py`, then constructs a `DeployCommand` (`src/python/deploy_command.py`) and a `Deployer` (`src/python/deployer.py`).
3. **Terraform provisions the VM.** Each `src/terraform/<cloud>/` module produces the same output names (`isaac_workstation_ip`, `cloud`, `ssh_key`) so `Deployer.tf_output()` can read them without knowing the cloud.
4. **`Deployer` runs Ansible against `src/ansible/inventory.template`.** The template is cloud-agnostic (it uses a `{cloud}` variable). The single playbook `src/ansible/isaac-workstation.yaml` invokes one top-level role, `isaac-workstation`, which pulls in (in order, via `roles/isaac-workstation/meta/main.yml`): `system`, `nvidia-driver`, `remote-desktop`, `isaacsim-source`, `isaaclab-source`, `isaaclab-arena-source`. Only `nvidia-driver` cares about the cloud — and only via existing `when: cloud == "..."` branches (today: `azure`, `aws or alicloud`, `gcp`). The post-import driver/library mismatch reboot block (`src/ansible/roles/nvidia-driver/tasks/main.yml:33-51`, added in `a573529`) is cloud-agnostic and applies to every provider.

Reuse — do not re-implement:

- `src/python/deployer.py` — `Deployer` class, fully cloud-agnostic. Reads Terraform outputs, exports the SSH key, drives Ansible.
- `src/python/deploy_command.py` — `DeployCommand` base class, click options shared across all `deploy-*` scripts.
- `src/python/utils.py` — `shell_command`, `colorize_info`, `colorize_error`, `get_my_public_ip`, `subnet_from_ip`.
- `src/ansible/inventory.template` — uses `{cloud}` cleanly; no per-cloud forks needed.
- All Ansible roles except `nvidia-driver` (one new `when:` branch there).

## Repository layering

The repo divides into a small number of layers with one-way dependencies. The Nebius work adds new leaves in `src/terraform/`, `src/python/`, `src/packer/`, and one new top-level script (`deploy-nebius`); the shared spine and all roles below `nvidia-driver` are untouched.

```
src/terraform/<cloud>/    ──►  src/python/<cloud>.py   ──►  deploy-<cloud>
                                                              │
                                                              ▼
                                                    src/python/deployer.py
                                                    src/python/deploy_command.py
                                                    src/python/utils.py          (cloud-agnostic spine)
                                                              │
                                                              ▼
                                                    src/ansible/  (inventory.template + roles)

src/packer/<cloud>/       ──►  image-<cloud>           (custom AMI / Nebius image bake)
docs/                                                  (knowledge base — orthogonal to code layers)
```

Rules of thumb:

- **The cloud-agnostic spine (`deployer.py`, `deploy_command.py`, `utils.py`) must not import any `src/python/<cloud>.py` module.** Cloud wrappers depend on the spine, never the reverse.
- **`src/ansible/` does not encode cloud-specific behavior** outside of the existing `when: cloud == "..."` branches. Adding a Nebius branch is acceptable; adding a per-cloud role is not.
- **`src/terraform/<cloud>/` produces a fixed output contract** (`isaac_workstation_ip`, `cloud`, `ssh_key`). The deployer reads outputs by name; the cloud doesn't leak into the deployer.
- **`src/packer/<cloud>/` is independent of `src/terraform/<cloud>/`.** Packer bakes an image; Terraform consumes it by family name. The handoff is the image family string, nothing more.

## Decision-log pointers

Architectural decisions live with the plan that made them. When a decision is broad enough to affect future work, link it from here:

- **Why fork rather than contribute Nebius upstream** — upstream `isaac-sim/IsaacAutomator` is NVIDIA-owned and unlikely to take a community-tier cloud provider. The fork keeps the AWS path tracking upstream while letting us iterate on Nebius without coordination. See [`docs/exec-plans/active/add-nebius-target.md`](docs/exec-plans/active/add-nebius-target.md) §Risks.
- **Why mirror AWS's file structure rather than build a generic provider interface** — the existing per-cloud directories (`aws/`, `gcp/`, `azure/`, `alicloud/`) already are the abstraction. A separate `provider/` layer would invite churn across every cloud on every Nebius change; mirroring AWS confines Nebius to new files plus a single `when:` branch. Rebase burden against upstream stays at the minimum.

## Out of scope (until a plan says otherwise)

- Maintaining the GCP / Azure / Alicloud paths beyond upstream parity. We track them passively; we do not extend them.
- Re-implementing or porting upstream's IsaacLab QA workflow (`ISAACLAB_QA.md`) for Nebius.
- Multi-GPU, multi-node, or autoscaling deployments on Nebius. Single GPU, single VM — same as upstream's defaults.
- CI in the cloud, deploy bots, cost dashboards. Cost discipline is manual via `./stop` and `./destroy`.
- A public hosted viewer or web UI for Isaac Sim output.
