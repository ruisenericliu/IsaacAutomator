# Plan: Fork IsaacAutomator to add Nebius as a deploy target

## Context

`groot_automator` currently assumes AWS for the Isaac Sim 5.0.0 + GR00T workstation, provisioned via Isaac Automator pinned to `685bc29` (the commit that fixes NoMachine install). We want **Nebius** as an alternative cloud target — primarily for cheaper L40S/H100 GPU hours — while keeping the AWS path working so we can A/B compare and fall back.

Investigation of Nebius's compute surface (docs.nebius.com) ruled out the "skip Ansible by booting from a Docker image" simplification: Nebius offers **only regular VMs** for GPU+GUI workloads. Their custom-disk-image and Packer flows are the same VM-base + provisioners model AWS already uses. So the cheapest path is to fork IsaacAutomator and add a Nebius provider alongside AWS/GCP/Azure/Alicloud, reusing all of IA's Ansible (NVIDIA driver, NoMachine, Isaac Sim install). NoMachine GUI is a hard requirement, which makes the cloud-agnostic Ansible the highest-value piece to preserve.

**Intended outcome:** `./run ./deploy-nebius <name>` provisions a Nebius L40S VM and lands at the same NoMachine + Isaac Sim experience as `./deploy-aws`, with `./stop` / `./start` / `./destroy` / `./repair` / `./ssh` all working against Nebius.

**Decisions locked in (from user):**
- Fork location: personal GitHub fork (`ruisenericliu/IsaacAutomator`), branch `nebius`.
- AWS and Nebius coexist; AWS path is not retired.
- Packer image baking is included in the first cut.

## Approach

Mirror IA's existing AWS provider structure. AWS is the closest analogue because both use Packer-baked custom images, both use SSH + Ansible bring-up, and both want a single GPU VM with public IP behind allow rules. Every per-provider file in IA's AWS path has a direct Nebius equivalent.

### A. New Terraform module `src/terraform/nebius/`

Mirror `src/terraform/aws/`'s structure exactly:

- `main.tf` — provider block for `nebius/nebius` (pin **v0.6.8**, the version published 2026-05-28; expect to revisit since the provider is community-tier and pre-1.0), modules for `common`, `vpc`, `isaac-workstation`.
- `variables.tf` — same input vars as AWS, plus Nebius-specific: `platform` (e.g. `gpu-l40s-a`), `preset` (e.g. `1gpu-32vcpu-128gb`), `parent_id` (Nebius tenant/project), `image_family` (default `ubuntu24.04-driverless`).
- `outputs.tf` — same names as AWS (`isaac_workstation_ip`, `cloud`, `ssh_key`) so `Deployer.tf_output()` in `src/python/deployer.py` works unchanged.
- `common/` — SSH keypair generation. Nebius doesn't have a managed keypair primitive; generate locally with `tls_private_key` + write public key into instance metadata `ssh-keys` field.
- `vpc/` — `nebius_vpc_v1_network` + `nebius_vpc_v1_subnet`. Single /24 subnet in one AZ, mirroring AWS's pattern in `src/terraform/aws/vpc/main.tf:14-24`.
- `isaac-workstation/` — `nebius_compute_v1_instance` with public IP (`assign_public_ip = true`), 256 GB boot disk (`disk.size_gibibytes = 256`), allow rules for `ssh_port` and `4000` (NoMachine) scoped to `var.ingress_cidrs`. ~50 LOC.

The trickiest piece is **mapping AWS-style single instance-type strings to Nebius's platform+preset pair**. Cleanest model: accept a Nebius-native `--instance-type <platform>/<preset>` string in `deploy-nebius` (e.g. `gpu-l40s-a/1gpu-32vcpu-128gb`), split it in the Python wrapper, and pass `platform` + `preset` as separate Terraform vars. Default = `gpu-l40s-a/1gpu-32vcpu-128gb` (closest to AWS `g6e.2xlarge`).

### B. New Python wrapper `src/python/nebius.py`

Mirror `src/python/aws.py` (~290 LOC). Nebius uses **service-account JSON** for IAM (no SSO equivalent of `aws login`), so credential validation is simpler than AWS:

- `nebius_validate_credentials()` — look for service account JSON at `state/.nebius/credentials.json` (mirror of AWS's `state/.aws/`). If missing, prompt the user to drop it there. Validate by calling `nebius iam whoami` via `shell_command` from `src/python/utils.py`.
- `nebius_stop_instance(instance_id)` — `nebius compute instance stop <id>`.
- `nebius_start_instance(instance_id)` — `nebius compute instance start <id>`.
- `nebius_get_instance_status(instance_id)` — `nebius compute instance get <id> --format json | jq -r .status` returning `running` / `stopping` / `stopped` / `pending` (matches AWS return contract).

Use `shell_command`, `colorize_info`, `colorize_error` from `src/python/utils.py` — same imports as `src/python/aws.py:24-31`.

### C. New CLI script `deploy-nebius`

Copy `deploy-aws` (~230 LOC). Changes:

- Replace `AWS_OVKIT_INSTANCE_TYPES` allowlist (`deploy-aws:44-77`) with `NEBIUS_OVKIT_INSTANCE_TYPES` listing Nebius `platform/preset` combos. Initial list: `gpu-l40s-a/1gpu-{8,16,32,40}vcpu-*`, `gpu-l40s-d/1gpu-{16,32,48}vcpu-*`, `gpu-h100-sxm/1gpu-16vcpu-200gb`, `gpu-h200-sxm/1gpu-16vcpu-200gb`.
- Default instance type: `gpu-l40s-a/1gpu-32vcpu-128gb`.
- Swap `from src.python.aws import aws_validate_credentials` → `from src.python.nebius import nebius_validate_credentials`.
- `--region` becomes `--parent-id` (Nebius's tenant/project identifier).
- Wire Terraform dir to `src/terraform/nebius`.

### D. Ansible adjustments

Single-line addition in `src/ansible/roles/nvidia-driver/tasks/main.yml`: add a `when: ... cloud == "nebius"` branch matching the existing `cloud == "aws"` block (line 28). On Ubuntu 24.04 driverless, the AWS apt-based install should work as-is; verify during bring-up.

`src/ansible/inventory.template` is already cloud-agnostic — no change.

`src/ansible/roles/remote-desktop/` (NoMachine) — no code change expected, but **NoMachine install on Nebius's `ubuntu24.04-driverless` image is the highest-risk unverified step**. Validate during bring-up.

### E. New Packer template `src/packer/nebius/`

Mirror `src/packer/aws/isaac-workstation.pkr.hcl`. Use the `github.com/nebius/nebius` Packer plug-in:

- `source.nebius.isaac-workstation` block — `base_image.family = "ubuntu24.04-driverless"`, `instance.platform = "gpu-l40s-a"`, `instance.preset = "1gpu-32vcpu-128gb"`, `disk.size_gibibytes = 256`, service-account credential block.
- Provisioners: identical shell+ansible provisioners as the AWS template — driver install, NoMachine install, Isaac Sim 5.0.0 install.
- Output: `image.name = "isaacworkstation"`, `image_family = "isaacworkstation"`.

Add a top-level `image-nebius` wrapper script analogous to `image-aws` to drive the Packer build from inside the IA container.

### F. `groot_automator` repo follow-ups (out of scope for this plan, listed for tracking)

These belong in a separate follow-up plan in `groot_automator/docs/exec-plans/active/` once the IA fork lands:

- `AWS_SETUP.md` stays; add sibling `NEBIUS_SETUP.md` (account creation, service-account credential download, quota request for L40S, NoMachine install — same shape as AWS_SETUP.md's 10 sections).
- `CLAUDE.md` pin table: note the **forked** IsaacAutomator commit alongside upstream, and Nebius's `gpu-l40s-a / 1gpu-32vcpu-128gb` as the default Nebius preset.
- `ARCHITECTURE.md`: update the topology diagram to show "AWS workstation VM **or** Nebius workstation VM" — the GR00T container + ZMQ wire are unchanged.

## Critical files to create or modify (in the forked IA repo)

| Path | Action | Notes |
|---|---|---|
| `src/terraform/nebius/main.tf` | create | mirror `src/terraform/aws/main.tf` |
| `src/terraform/nebius/variables.tf` | create | add `platform`, `preset`, `parent_id`, `image_family` |
| `src/terraform/nebius/outputs.tf` | create | keep output names identical to AWS |
| `src/terraform/nebius/common/*.tf` | create | SSH keypair via `tls_private_key` |
| `src/terraform/nebius/vpc/*.tf` | create | `nebius_vpc_v1_network` + subnet |
| `src/terraform/nebius/isaac-workstation/*.tf` | create | `nebius_compute_v1_instance` + allow rules |
| `src/python/nebius.py` | create | mirror `src/python/aws.py`, simpler (no SSO) |
| `deploy-nebius` | create | mirror `deploy-aws`, new instance-type allowlist |
| `src/ansible/roles/nvidia-driver/tasks/main.yml` | edit | one new `when: cloud == "nebius"` branch |
| `src/packer/nebius/isaac-workstation.pkr.hcl` | create | Nebius Packer plug-in |
| `image-nebius` | create | mirror `image-aws` |

Existing utilities to reuse without modification:
- `src/python/deployer.py` — `Deployer` class is fully cloud-agnostic.
- `src/python/deploy_command.py` — `DeployCommand` base class.
- `src/python/utils.py` — `shell_command`, `colorize_*`, `get_my_public_ip`, `subnet_from_ip`.
- `src/ansible/inventory.template` — uses `{cloud}` variable cleanly.
- All ansible roles except `nvidia-driver` (one-line addition there).

## Risks

1. **Nebius Terraform provider is v0.6.8 (community tier, published 2026-05-28).** Pre-1.0, actively changing. Pin the exact version in `main.tf`; expect to chase breaking changes on upgrades.
2. **Permanent fork.** Upstream IA (NVIDIA) won't merge Nebius. Every time `groot_automator` bumps the IA commit pin, the `nebius` branch needs a rebase. Mitigation: keep Nebius changes confined to new files where possible; the only edit to a shared file is the single ansible `when:` block.
3. **NoMachine on `ubuntu24.04-driverless` is unverified.** The `remote-desktop` role's NoMachine .deb install should work, but Nebius's base image may differ from AWS's in ways that surface during the playbook. Budget bring-up debugging time.
4. **L40S quota on Nebius.** User confirmed L40S is available, but a fresh tenant may need a quota increase request before the first deploy lands.
5. **`tls_private_key` SSH model.** Unlike AWS's managed `aws_key_pair`, Nebius requires the public key in instance metadata. Confirm the IA `Deployer.export_ssh_key()` path (`src/python/deployer.py:416-429`) still works — it reads from Terraform output, which we control.

## Verification (end-to-end, on the fork)

1. **Build the IA container with Nebius CLI baked in.** Add `nebius` CLI install to `Dockerfile` next to the existing `aws` / `gcloud` / `az` installs.
2. **Pre-flight:** `./run ./deploy-nebius --help` lists Nebius instance types; `nebius iam whoami` works inside the container.
3. **Packer image bake:** `./run ./image-nebius` produces an image in the Nebius image family `isaacworkstation`. Should take 30–60 min for first bake.
4. **Provision from baked image:** `./run ./deploy-nebius <name> --isaaclab no --isaaclab-arena no` provisions a VM, lands at the post-deploy banner with public IP and NoMachine port written to `state/<name>/info.txt`. Expected wall time: ~5 min Terraform + Ansible skipped (from-image path).
5. **Connect:** `./run ./ssh <name>` opens a shell. `nvidia-smi` shows an L40S. NoMachine client on the Mac connects to the IP+port from `info.txt` and shows the Ubuntu desktop with Isaac Sim launchable.
6. **End-to-end Isaac Sim:** Launch Isaac Sim from the menu over NoMachine, confirm GPU rendering works.
7. **Lifecycle:** `./run ./stop <name>` halts the VM (`nebius compute instance get` returns `stopped`); `./run ./start <name>` brings it back; `./run ./destroy <name>` removes the VM, subnet, network, and image leaves no orphans (verify via `nebius compute instance list` and `nebius vpc network list`).
8. **AWS regression check:** `./run ./deploy-aws --region us-west-2 <other-name>` still works unchanged — no shared file edits broke the AWS path.
9. **GR00T integration** (depends on `groot_automator` Phase B.3 + B.4 landing): on the Nebius VM, clone `groot_automator`, run `docker compose -f docker-compose.aws.yml up -d groot-server`, then `~/IsaacSim/python.sh src/client/run_inference.py --server-host 127.0.0.1` produces an MP4 in `/workspace/outputs/`.

Each item is a manual gate; collect outputs/screenshots into `state/<name>/info.txt` per IA's existing convention.

## Sizing estimate

**2–4 working days for first cut**, weighted toward bring-up debugging (NVIDIA driver branch, NoMachine on `ubuntu24.04-driverless`, Packer build) rather than code volume. ~700–900 LOC of new code, all of it close-mirroring existing AWS files.
