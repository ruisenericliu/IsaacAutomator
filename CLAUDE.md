# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A fork of [`isaac-sim/IsaacAutomator`](https://github.com/isaac-sim/IsaacAutomator) ([`ruisenericliu/IsaacAutomator`](https://github.com/ruisenericliu/IsaacAutomator)) that adds **Nebius** as a deploy target alongside the upstream AWS / GCP / Azure / Alicloud providers. The fork is pinned at upstream commit `685bc29` (the NoMachine install fix); Nebius work lives on the `nebius` branch. Everything user-facing still flows through `./run ./deploy-<cloud> <name>` → Terraform → Ansible → Isaac Sim + NoMachine on a GPU VM, driven from a host machine that only runs the `isaac_automator` Docker image.

## Current state — read before doing anything

**Fork bring-up complete; Nebius implementation is 🟡 (not started).** Upstream AWS / GCP / Azure / Alicloud paths are untouched and track upstream `685bc29` exactly — no shared source files have been modified. The harness scaffolding (this file, `ARCHITECTURE.md`, `.claude/`, `docs/`) is the only delta on the `nebius` branch so far.

The current source of truth for what we're building is **[`docs/exec-plans/active/add-nebius-target.md`](docs/exec-plans/active/add-nebius-target.md)** — read it (especially §Critical files to create or modify) before proposing changes. The Nebius Terraform provider is community-tier (`nebius/nebius` v0.6.8, pre-1.0), and NoMachine install on Nebius's `ubuntu24.04-driverless` image is the highest-risk unverified step.

## Operating principles (agent-first harness)

We are intentionally following the OpenAI Codex "harness engineering" model: humans steer, agents execute, and the repo itself is the system of record. Concretely:

1. **Keep this CLAUDE.md as a table of contents, not an encyclopedia.** Push details into `docs/`, link out from here. Target ≤ ~100 lines.
2. **Anything an agent can't see in-repo effectively doesn't exist.** If a decision was made in chat, encode it into a plan, a reference doc, or a code-level invariant.
3. **Plans are first-class artifacts.** Non-trivial work goes through `docs/exec-plans/active/<slug>.md`; completed plans move to `docs/exec-plans/completed/`. Update the plan as decisions land; don't let it drift from the code.
4. **Verify before recommending.** Nebius's Terraform provider, NoMachine's installer URL, and Isaac Sim 5.0.0 APIs all change between releases — read the pinned source, don't pattern-match from memory.
5. **The host machine only runs the `./run` container.** Cloud APIs, Terraform, Packer, and Ansible all execute inside the container; GPU work happens on the provisioned VM. The host's role is to drive `./run` and to connect to the VM with a NoMachine client.

## Repo layout (current)

```
.
├── CLAUDE.md                              (this file — ToC for agents)
├── ARCHITECTURE.md                        (system map, pin table, deploy-pipeline summary)
├── README.md                              (upstream human-facing quickstart)
├── CONTRIBUTING.md / ISAACLAB_QA.md / LICENSE
├── .claude/
│   └── settings.local.json                (Bash allowlist; no hooks, no MCP)
├── docs/
│   ├── exec-plans/
│   │   ├── active/
│   │   │   └── add-nebius-target.md       ← READ THIS FIRST
│   │   └── completed/                     (empty; retired plans land here)
│   └── references/                        (empty; frozen upstream snapshots land here)
├── build / run / ssh / start / stop / destroy / repair / import / download / upload / novnc
├── deploy-aws / deploy-gcp / deploy-azure / deploy-alicloud   ✅ upstream, untouched
├── deploy-nebius                          🟡 to create (mirror of deploy-aws)
├── image-aws                              ✅ upstream (only AWS has a Packer wrapper today)
├── image-nebius                           🟡 to create
├── Dockerfile                             ✅ upstream (Nebius CLI install to add)
└── src/
    ├── ansible/                           ✅ cloud-agnostic except one branch in nvidia-driver
    ├── packer/{aws,azure}/                ✅ upstream (no gcp/, no alicloud/)
    ├── packer/nebius/                     🟡 to create
    ├── python/                            ✅ deployer.py / deploy_command.py / utils.py are cloud-agnostic
    ├── python/nebius.py                   🟡 to create (mirror of aws.py)
    ├── terraform/{aws,gcp,azure,alicloud}/ ✅ upstream
    ├── terraform/nebius/                  🟡 to create
    └── tests/                             ✅ upstream
```

## Target architecture (delta only — full picture in the active plan)

```
host (Mac/Linux)  ──`./run ./deploy-<cloud>`──►  isaac_automator container
                                                   │
                                                   ├── deploy-aws ──► AWS API ──┐
                                                   └── deploy-nebius ──► Nebius API ─┐
                                                                                     ▼
                                                                          Workstation VM (single GPU)
                                                                          ├── Isaac Sim 5.0.0 (native)
                                                                          └── NoMachine server (TCP)
                                                                                     ▲
                                       host NoMachine client  ──TCP NX────────────────┘
```

- **AWS path is unchanged** and remains a working reference for A/B comparison against Nebius hour-cost and bring-up time.
- **Nebius mirrors AWS file-for-file.** Terraform module, Python wrapper, deploy script, Packer template, image wrapper — same shapes, swap providers. No generic-cloud abstraction layer.
- **Ansible is cloud-agnostic** except a single `when: cloud == "nebius"` branch in `src/ansible/roles/nvidia-driver/tasks/main.yml`. NoMachine, Isaac Sim install, and inventory templating are all unchanged.

## Pinned versions (digest — `ARCHITECTURE.md` is canonical)

Anywhere a version is named, it must agree with the canonical table in [`ARCHITECTURE.md`](ARCHITECTURE.md). This digest is for fast lookup.

| Component | Pin |
|---|---|
| Upstream IsaacAutomator commit | `685bc29` (2026-05-14; NoMachine install fix) |
| Isaac Sim | `5.0.0` (native install via the workstation role) |
| NoMachine | `9.5.7_2` (mirror URL per upstream `685bc29`) |
| Nebius Terraform provider | `nebius/nebius` v`0.6.8` (community-tier, pre-1.0) |
| Nebius default instance | platform `gpu-l40s-a`, preset `1gpu-32vcpu-128gb` |
| Nebius base image family | `ubuntu24.04-driverless` |
| AWS default instance | `g6e.2xlarge` (L40S, 48 GB) per upstream default |
| Packer plug-in (Nebius) | `github.com/nebius/nebius` |

## Commands

Host-side (these are the only commands the host ever needs):

- `./build` — build the `isaac_automator` container image.
- `./run ./deploy-aws <name>` — provision an AWS workstation (upstream-default behavior).
- `./run ./deploy-nebius <name>` — 🟡 provision a Nebius workstation (after the active plan lands).
- `./run ./ssh <name>` / `./run ./start <name>` / `./run ./stop <name>` / `./run ./destroy <name>` / `./run ./repair <name>` — lifecycle. NoMachine is reached from the host NoMachine client using the IP + port in `state/<name>/info.txt`.
- `./run ./image-aws` / `./run ./image-nebius` (🟡) — bake a custom VM image via Packer.

Inside the container (when iterating on Terraform/Packer/Ansible during Nebius work):

- `terraform -chdir=src/terraform/<cloud> fmt -check` / `terraform -chdir=src/terraform/<cloud> validate` — format + sanity-check a provider module.
- `packer fmt src/packer/<cloud>/*.pkr.hcl` / `packer validate src/packer/<cloud>/*.pkr.hcl` — same for Packer templates.
- `shellcheck deploy-* run ssh start stop destroy repair build` — shell lint on the top-level scripts.
- `python3 -c "import ast; ast.parse(open('<path>').read())"` — syntax check for Python wrappers when no test runner is available.

There is no project-level lint config or test harness wired up today; `src/tests/` is upstream's own pytest tree, scoped to the deployer logic.

> The `.claude/settings.local.json` Bash allowlist is hard-coded to the absolute path `/Users/ruisenliu/Repositories/IsaacAutomator`. If you clone the fork to a different path, edit that file.

## When to add to this file vs. elsewhere

- New cross-cutting invariant or convention → here (briefly), with a link to a detail doc.
- New design decision with non-obvious rationale → a plan in `docs/exec-plans/active/`, or its decision log.
- External setup walkthrough → `docs/references/<thing>.md`.
- Code-level rule that can be mechanically enforced → encode as a lint or a test, not prose.
