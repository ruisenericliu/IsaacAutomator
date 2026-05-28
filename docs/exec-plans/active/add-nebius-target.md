# Plan: Fork IsaacAutomator to add Nebius as a deploy target

## Context

This fork of `isaac-sim/IsaacAutomator` is pinned at upstream `685bc29` (the NoMachine install fix). Today the consumer project (`groot_automator`) drives only the AWS path. We want **Nebius** as an alternative cloud target — primarily for cheaper L40S/H100 GPU hours — while keeping the AWS path working so we can A/B compare and fall back.

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
- `isaac-workstation/` — `nebius_compute_v1_instance` with public IP, 256 GB boot disk (`disk.size_gibibytes = 256`), allow rules scoped to `var.ingress_cidrs`. ~50 LOC. The baked custom image is picked up via a `data "nebius_compute_v1_image"` lookup keyed on `family = "isaac-automator-isaacworkstation"` (mirror GCP's naming at `src/terraform/gcp/ovkit/main.tf:13-17`); when no image is baked yet, fall back to `base_image.family = var.image_family`. Use a `count = var.from_image ? 1 : 0` guard on the data source so deployments in a fresh tenant don't fail before the first Packer bake.
- **Static public IP — mirror GCP's pattern.** Upstream's `src/terraform/gcp/ovkit/security.tf:8-11` reserves a `google_compute_address` and wires it into the instance's `access_config.nat_ip` (`ovkit/main.tf:56-61`) so the address survives stop/start. Do the same on Nebius: reserve the provider's static-IP primitive in `vpc/` (or `isaac-workstation/`) and bind it to the instance's network interface. If Nebius v0.6.8 does not expose a static-IP resource, that is a blocker — surface it before §B/§C, because upstream now asserts IP preservation as a cross-cloud invariant (commit `26253f4`, "public IP is preserved across stop/start cycles on all clouds").
- **NoMachine port rules.** GCP's firewall opens **both UDP and TCP 4000** (`security.tf:40-55`) — NoMachine NX uses UDP for video when available, TCP as fallback. Open both on Nebius for performance; the TCP-only fallback (`ARCHITECTURE.md`'s invariant) still applies if UDP is blocked downstream. Also open `var.ssh_port`.

The trickiest piece is **mapping AWS-style single instance-type strings to Nebius's platform+preset pair**. Cleanest model: accept a Nebius-native `--instance-type <platform>/<preset>` string in `deploy-nebius` (e.g. `gpu-l40s-a/1gpu-32vcpu-128gb`), split it in the Python wrapper, and pass `platform` + `preset` as separate Terraform vars. Default = `gpu-l40s-a/1gpu-32vcpu-128gb` (closest to AWS `g6e.2xlarge`).

### B. New Python wrapper `src/python/nebius.py`

Mirror `src/python/aws.py` (~290 LOC, post-merge). Nebius uses **service-account JSON** for IAM (no SSO equivalent of `aws login`), so credential validation is simpler than AWS:

- `nebius_validate_credentials()` — look for service account JSON at `state/.nebius/credentials.json` (mirror of AWS's `state/.aws/`). The `state/` directory is bind-mounted into the `isaac_automator` container by `./run` (see `run` script), so a file dropped there from the host is visible to the container without any extra wiring. If missing, prompt the user to drop it there. Validate by calling `nebius iam whoami` via `shell_command` from `src/python/utils.py`.
- **Optional env-var override (mirror AWS's new behavior).** Upstream commit `60e4695` taught `src/python/aws.py` to prefer `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` from the host env (forwarded by `./run`) over the on-disk SSO state. Do the analogous thing for Nebius: if a `NEBIUS_SERVICE_ACCOUNT_JSON` (or equivalent) env var is set on the host, forward it via `./run` and consume it in `nebius_validate_credentials()` ahead of the on-disk file. Keep the file path as the default to preserve the "drop a file in `state/.nebius/`" UX.
- `nebius_stop_instance(instance_id)` — `nebius compute instance stop <id>`.
- `nebius_start_instance(instance_id)` — `nebius compute instance start <id>`.
- `nebius_get_instance_status(instance_id)` — `nebius compute instance get <id> --format json | jq -r .status` returning `running` / `stopping` / `stopped` / `pending` (matches AWS return contract).

Use `shell_command`, `colorize_info`, `colorize_error` from `src/python/utils.py` — same imports as `src/python/aws.py:24-31`.

### C. New CLI script `deploy-nebius`

Copy `deploy-aws` (~230 LOC). Changes:

- Replace `AWS_OVKIT_INSTANCE_TYPES` allowlist (`deploy-aws:44-77`) with `NEBIUS_OVKIT_INSTANCE_TYPES` listing Nebius `platform/preset` combos. Initial list: `gpu-l40s-a/1gpu-{8,16,32,40}vcpu-*`, `gpu-l40s-d/1gpu-{16,32,48}vcpu-*`, `gpu-h100-sxm/1gpu-16vcpu-200gb`, `gpu-h200-sxm/1gpu-16vcpu-200gb`.
- Default instance type: `gpu-l40s-a/1gpu-32vcpu-128gb`.
- Swap `from src.python.aws import aws_validate_credentials` → `from src.python.nebius import nebius_validate_credentials`.
- Add `--parent-id` (Nebius's tenant/project identifier; required, no default). Keep `--region` as an optional flag mapped onto the Nebius region segment of `parent_id` only if Nebius exposes L40S in more than one region at the time of bring-up; otherwise omit `--region` and document that region is implicit in `parent_id`. Confirm during §A.
- Wire Terraform dir to `src/terraform/nebius`.

### D. Ansible adjustments

Single-token edit in `src/ansible/roles/nvidia-driver/tasks/main.yml:28`. The existing line is:

```yaml
- import_tasks: nvidia-driver.generic.yml
  when: driver_installed.stdout == "0" and (cloud == "aws" or cloud == "alicloud")
```

Add `or cloud == "nebius"` inside the parenthesised cloud check so Nebius reuses the same generic apt-based install AWS uses. No new `import_tasks` block, no new file. Verify the generic playbook actually works on Nebius's `ubuntu24.04-driverless` image during bring-up — this is the highest-risk Ansible step.

Do **not** touch the new "NVIDIA driver/library version mismatch" block at lines 33–51 (added in upstream `a573529`). It runs cloud-agnostically after the import branches and benefits Nebius for free when `--from-image` rolls onto an image whose kernel module has drifted from the package.

`src/ansible/inventory.template` is already cloud-agnostic — no change.

`src/ansible/roles/remote-desktop/` (NoMachine) — no code change expected, but **NoMachine install on Nebius's `ubuntu24.04-driverless` image is the highest-risk unverified step**. Validate during bring-up.

### E. New Packer template `src/packer/nebius/`

Mirror `src/packer/gcp/isaac-workstation.pkr.hcl` — newer than the AWS template (added in upstream `fe1d0f5`, 2026) and uses the same `--from-image` family naming convention we adopted in §A. Use the `github.com/nebius/nebius` Packer plug-in:

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
| `src/ansible/roles/nvidia-driver/tasks/main.yml` | edit | add `or cloud == "nebius"` to the existing generic-install `when:` on line 28 — one token, no new block |
| `src/packer/nebius/isaac-workstation.pkr.hcl` | create | Nebius Packer plug-in |
| `image-nebius` | create | mirror `image-aws` |
| `Dockerfile` | edit | install Nebius CLI (`nebius`) alongside the existing `aws` / `gcloud` / `az` / `aliyun` installs so the `isaac_automator` container can drive Nebius APIs |

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
5. **`tls_private_key` SSH model.** Unlike AWS's managed `aws_key_pair`, Nebius requires the public key in instance metadata. Confirm the IA `Deployer.export_ssh_key()` path (`src/python/deployer.py:416-429`) still works — it reads from Terraform output, which we control. **Verify this read-only before §B/§C land**: open `deployer.py:416-429`, confirm it only consumes the `ssh_key` Terraform output and doesn't reach into AWS-specific primitives. Cheap to check up front; expensive to discover after Packer + Terraform are wired.
6. **Static public IP is a cross-cloud invariant.** Upstream commit `26253f4` documents IP preservation across stop/start as an "all clouds" property; `c54374c` shows GCP's implementation (a reserved `google_compute_address` wired into `access_config.nat_ip`). Nebius must hold this invariant or we regress against upstream. The risk is that Nebius v0.6.8's provider may not expose a separate static-IP resource — discover this during §A and surface immediately if so, since the fallback (rewriting `state/<name>/info.txt` on every `./start`) breaks the upstream contract and would need a separate carve-out in `Deployer`.

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

**Code volume: 2–4 working days for first cut**, ~700–900 LOC of new code, all of it close-mirroring existing AWS files.

**Bring-up debugging: budget separately.** The pre-1.0 provider (§Risks 1), the unverified NoMachine install on `ubuntu24.04-driverless` (§Risks 3), the static-IP question (§Risks 6), and Packer rebuild cycles at 30–60 min each (§E) will dominate calendar time. Plan for several debug-and-rebake cycles before §Verification step 6 passes end-to-end; do not promise the consumer project a date based on the code-volume number alone.
