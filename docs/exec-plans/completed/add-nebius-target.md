# Plan: Fork IsaacAutomator to add Nebius as a deploy target

## Status: implementation landed 2026-05-28

Sections §A–§E are implemented on branch `nebius`. `terraform validate` (on both `src/terraform/nebius/` and `src/terraform/nebius-packer-bootstrap/`) and `packer validate` (on `src/packer/nebius/isaac-workstation.pkr.hcl`) pass. No live `apply` / `build` has run yet — the live gates moved into [`docs/exec-plans/active/verify-nebius-live-deploy.md`](../active/verify-nebius-live-deploy.md).

### What changed vs. the original plan (read these before re-reading §A–§E)

- **Dropped `nebius_vpc_v1_allocation` entirely.** The plan called for a VPC-layer allocation wired into the instance via `network_interfaces[].public_ip_address.allocation_id`. The provider rejects `ipv4_public = {}` — it requires `pool_id` or `subnet_id` (oneof). The instance's `public_ip_address` block accepts a bare `static = true` with no `allocation_id` and auto-allocates instead, so the workstation module skips the VPC allocation. `public_ip` is now read from `nebius_compute_v1_instance.instance.status.network_interfaces[0].public_ip_address.address`. Risk 6 stands resolved; the original solution shape (separate allocation) was wrong.
- **`network_interfaces[].ip_address` is required.** The plan only mentioned `public_ip_address`. The private-IP block is required even when auto-allocated; we pass `ip_address = {}`.
- **Child Terraform modules need their own `required_providers`.** Without an explicit `nebius = { source = "nebius/nebius" }` block in `vpc/main.tf` and `isaac-workstation/main.tf`, Terraform defaults the prefix `nebius_*` to `hashicorp/nebius` and `init` fails on the (nonexistent) registry entry.
- **Packer plugin field names are not the Terraform field names.** §E listed `subnet_id` / `platform` / `source_image_family` / `disk_size_gb` etc. as top-level builder fields. They are nested blocks: `service_account { … }`, `base_image { family = … }`, `disk { size_gibibytes, type = "network_ssd" }`, `network { subnet_id, associate_public_ip_address }`, `instance { platform, preset }`, `image { name, image_family, version, image_family_human_readable, cpu_architecture }`. Authoritative reference: [`nebius/packer-plugin-nebius` `docs/builders/builder.mdx`](https://github.com/nebius/packer-plugin-nebius/blob/main/docs/builders/builder.mdx).
- **Packer plugin does NOT auto-read `NB_*` env vars.** Unlike the Terraform provider's `service_account { account_id_env = "NB_SA_ID", … }` pattern, the Packer plugin's `service_account` block takes literal values. The template surfaces `nebius_sa_id` / `nebius_authkey_public_id` / `nebius_authkey_private_path` as Packer vars (each defaulting to the corresponding `env(...)` lookup) and wires them through.
- **`image.version` is required whenever `image.image_family` is set.** The template strips the leading `v` from `VERSION` (e.g. `v4.0.0` → `4.0.0`) since the plugin parses it.
- **NoMachine install gate stays at runtime.** Couldn't be validated statically. Documented in the new plan.

### Where everything landed

| Path | Notes |
|---|---|
| `Dockerfile` | Nebius CLI installer; `packer init` extended to `src/packer/nebius/` |
| `run` | Forwards `NB_SA_ID` / `NB_AUTHKEY_PUBLIC_ID` / `NB_AUTHKEY_PRIVATE_PATH` / `NB_PARENT_ID` / `NB_BUILDER_SUBNET_ID` |
| `src/python/config.py` | `nebius_default_from_image`, `nebius_default_isaac_workstation_instance_type`, `nebius_default_image_family` |
| `src/python/nebius.py` | env-or-file credential model, JSON status mapping to AWS-equivalent strings |
| `deploy-nebius` | `--parent-id` required, `--instance-type <platform>/<preset>` split |
| `image-nebius` | provisions bootstrap VPC via Terraform → runs Packer → tears down |
| `src/terraform/nebius/` | top-level + `common/`, `vpc/`, `isaac-workstation/` |
| `src/terraform/nebius-packer-bootstrap/` | one-shot VPC + subnet + SSH-allow SG for Packer |
| `src/packer/nebius/isaac-workstation.pkr.hcl` | `nebius-image` builder |
| `src/ansible/roles/nvidia-driver/tasks/main.yml` | `cloud == "nebius"` added to the generic branch |

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

### Research pass (2026-05-28) — facts verified against upstream sources

Read before §A — these are the load-bearing facts the rest of the plan now assumes. Each was confirmed against the upstream Nebius Terraform provider repo (`nebius/terraform-provider-nebius`), the Nebius docs (`docs.nebius.com`), or the Packer plug-in repo (`nebius/packer-plugin-nebius`). Citations inline.

**Terraform provider (`nebius/nebius` v0.6.8):**

- Provider source string: `nebius/nebius` (verified: `examples/provider/provider.tf` in the provider repo).
- Provider configuration takes a `service_account` block. Each field has an `*_env` variant that pulls from a named env var: `account_id_env = "NB_SA_ID"`, `public_key_id_env = "NB_AUTHKEY_PUBLIC_ID"`, `private_key_file_env = "NB_AUTHKEY_PRIVATE_PATH"`. We pass values via env, not a static JSON file.
- VPC resources: `nebius_vpc_v1_network`, `nebius_vpc_v1_subnet`. Subnet requires `parent_id` + `network_id`; IP pools (`ipv4_private_pools`, `ipv4_public_pools`) are optional and inherit from the network if omitted. **No availability-zone concept** — pools are purely logical.
- Static IP: `nebius_vpc_v1_allocation`. Has an `ipv4_public` block and a read-only `status.details.allocated_cidr`. **Constraint:** allocation and network interface must share the same subnet.
- Compute: `nebius_compute_v1_instance`. Required top-level: `parent_id`, `network_interfaces`, `resources`. Required nested: `resources.platform` (`preset` optional), `boot_disk.attach_mode` (`READ_WRITE`), `boot_disk.managed_disk.spec.type` (use `NETWORK_SSD`), one of `size_gibibytes`/`size_bytes`/etc., and either `source_image_id` or `source_image_family { image_family = "..." }`. `network_interfaces[]` requires `name` and `subnet_id`. Public IP is wired via `network_interfaces[].public_ip_address.allocation_id` (pointing at a `nebius_vpc_v1_allocation`) with `static = true`.
- **SSH-key injection is via `cloud_init_user_data`, NOT a `metadata.ssh-keys` field.** The `metadata` block on `nebius_compute_v1_instance` is READ-ONLY. The plan's earlier "write public key into instance metadata `ssh-keys` field" wording was wrong; we generate a cloud-init `users` document instead.
- No standalone `nebius_compute_v1_image` data source is exposed in the v0.6.8 docs. **Image-family resolution happens inside the instance resource** via `boot_disk.managed_disk.spec.source_image_family { image_family = "..." }`. There is no separate data-source lookup step — drop that pattern from §A.

**Packer plug-in (`github.com/nebius/nebius` v0.0.6, builder `nebius-image`):**

- `required_plugins` source string: `github.com/nebius/nebius`.
- Builder block: `source "nebius-image" "<name>" { ... }`.
- Required nested blocks: `service_account { public_key_id, account_id, private_key_file }`, `disk { size_gibibytes }`, `base_image { family = "ubuntu24.04-driverless" }`, `network { subnet_id, associate_public_ip_address = true }`, `instance { platform, preset }`, `image { name, version, image_family, cpu_architecture, image_family_human_readable }`, top-level `parent_id`, `communicator = "ssh"`, `ssh_username = "ubuntu"`. SSH key injection is handled by the plug-in automatically.
- **Packer needs a pre-existing `subnet_id`.** Either (a) maintain a long-lived "builder subnet" out-of-band, or (b) wrap Packer with a thin Terraform that provisions the VPC+subnet, runs Packer, then tears them down. Decide in §E; (a) is simpler for the first cut.

**Nebius CLI:**

- Install: `curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash` (verified at `docs.nebius.com/cli/quickstart`).
- Auth (non-interactive): `nebius profile create --endpoint api.nebius.cloud --service-account-id $NB_SA_ID --public-key-id $NB_AUTHKEY_PUBLIC_ID --private-key-file $NB_AUTHKEY_PRIVATE_PATH --parent-id $NB_PARENT_ID --profile default`. **Credentials are three discrete fields + a PEM private key file**, not a single JSON bundle.
- "Whoami"-equivalent probe: `nebius iam tenant list` (returns the caller's accessible tenants — fails cleanly on bad creds or no network).
- Lifecycle: `nebius compute instance stop <id>`, `nebius compute instance start <id>`, `nebius compute instance get <id> --format json`. All accept `--format json`; status field is inside the JSON envelope (exact JSON path TBD on first live run — probe with `jq` against a real instance and pin the path then).

**Upstream invariant check (Risk 5):**

- `src/python/deployer.py:416-429` (`export_ssh_key()`) reads only the `ssh_key` Terraform output via `terraform output -raw ssh_key` and chmods the result. Fully cloud-agnostic — no AWS-specific primitives. The `tls_private_key` + `cloud_init_user_data` approach satisfies the contract as long as the Terraform output `ssh_key` returns the private key PEM, identical to AWS.

### A. New Terraform module `src/terraform/nebius/`

Mirror `src/terraform/aws/`'s structure:

- `main.tf` — `required_providers` block with `source = "nebius/nebius"`, version pin `~> 0.6.8`. `provider "nebius"` block uses the `service_account { *_env = ... }` pattern referencing `NB_SA_ID` / `NB_AUTHKEY_PUBLIC_ID` / `NB_AUTHKEY_PRIVATE_PATH` (forwarded by `./run`; see §B). Modules: `common`, `vpc`, `isaac-workstation`.
- `variables.tf` — same input vars as AWS, plus Nebius-specific: `platform` (default `gpu-l40s-a`), `preset` (default `1gpu-32vcpu-128gb`), `parent_id` (Nebius project ID, required), `image_family` (default `ubuntu24.04-driverless`).
- `outputs.tf` — same names as AWS (`isaac_workstation_ip`, `cloud`, `ssh_key`, `isaac_workstation_vm_id`) so `Deployer.export_ssh_key()` (`src/python/deployer.py:416-429`, verified cloud-agnostic) works unchanged. `cloud = "nebius"`.
- `common/` — SSH keypair generation via `tls_private_key`. Output the private key PEM as `ssh_key` and the public key as `ssh_public_key` so the workstation module can splice it into `cloud_init_user_data`. (No managed-keypair primitive needed — Nebius has none.)
- `vpc/` — `nebius_vpc_v1_network` + `nebius_vpc_v1_subnet`. Single subnet, no AZ concept on Nebius. Leave pools to inherit from the network (`use_network_pools = true` semantics). Also defines the static-IP allocation as `nebius_vpc_v1_allocation` with `ipv4_public {}` so it lives at the VPC layer and survives instance recreation; export `public_ip_allocation_id` and `public_ip_address` (from `status.details.allocated_cidr`).
- `isaac-workstation/` — `nebius_compute_v1_instance`. Boot disk via `boot_disk.managed_disk.spec` with `type = "NETWORK_SSD"`, `size_gibibytes = 256`, and `source_image_family { image_family = var.from_image ? "isaacworkstation" : var.image_family }` (single field flip — no separate data source). Network interface points at the subnet and wires `public_ip_address.allocation_id = var.public_ip_allocation_id` with `static = true`. `cloud_init_user_data` renders a minimal cloud-init YAML injecting the `ubuntu` user with the generated public key. ~80 LOC.
- **Static public IP (Risk 6 resolved).** `nebius_vpc_v1_allocation` lives in `vpc/` so the address persists across instance stop/start AND across `terraform taint`/destroy-and-recreate of the workstation only. Mirrors GCP's `google_compute_address`-in-vpc pattern.
- **NoMachine port rules.** Opens UDP+TCP 4000 and `var.ssh_port`. Provider's security-group / allow-rule resource shape to confirm on first `terraform validate` — if v0.6.8 lacks a Nebius-managed security-group resource, fall back to OS-level `ufw` rules added by the existing `remote-desktop` Ansible role. Flag this on first apply.

The trickiest piece is **mapping AWS-style single instance-type strings to Nebius's platform+preset pair**. Cleanest model: accept a Nebius-native `--instance-type <platform>/<preset>` string in `deploy-nebius` (e.g. `gpu-l40s-a/1gpu-32vcpu-128gb`), split it in the Python wrapper, and pass `platform` + `preset` as separate Terraform vars. Default = `gpu-l40s-a/1gpu-32vcpu-128gb` (closest to AWS `g6e.2xlarge`).

### B. New Python wrapper `src/python/nebius.py`

Mirror `src/python/aws.py` (~290 LOC, post-merge). Nebius credentials are **three discrete fields plus a PEM private key file**, not a JSON bundle (verified — see Research pass). The on-disk drop layout in `state/.nebius/` is:

```
state/.nebius/
  private.pem          # PEM-encoded private key
  profile.env          # NB_SA_ID, NB_AUTHKEY_PUBLIC_ID, NB_PARENT_ID (shell-sourceable)
```

- `nebius_validate_credentials()` — read `state/.nebius/profile.env` and verify `state/.nebius/private.pem` exists and has `0600` perms. Export the three IDs + the PEM path into the env as `NB_SA_ID` / `NB_AUTHKEY_PUBLIC_ID` / `NB_AUTHKEY_PRIVATE_PATH` / `NB_PARENT_ID` so the Terraform provider and Packer plug-in can pick them up (both consume these env names natively — see Research pass). Probe auth by calling `nebius iam tenant list --format json` via `shell_command` and parsing for at least one tenant entry — fails cleanly on bad creds, network, or unreachable endpoint.
- **Env-var override (mirror AWS's `60e4695`).** If `NB_SA_ID`, `NB_AUTHKEY_PUBLIC_ID`, and `NB_AUTHKEY_PRIVATE_PATH` are all already set on the host env (forwarded by `./run`), skip the on-disk file read and use them directly. Keep the on-disk path as the default to preserve the "drop files in `state/.nebius/`" UX.
- `nebius_stop_instance(instance_id)` — `nebius compute instance stop <id>`.
- `nebius_start_instance(instance_id)` — `nebius compute instance start <id>`.
- `nebius_get_instance_status(instance_id)` — `nebius compute instance get <id> --format json` piped through `jq` extracting the status field. The exact JSON path is unconfirmed (Nebius CLI ref pages do not include sample output); on first live run, capture the JSON envelope, pin the path (likely `.status.state` or `.status.phase`), and check the resolved values against AWS's return contract (`running`/`stopping`/`stopped`/`pending`). Map Nebius states to AWS-equivalent strings inside this function so callers in `deployer.py` don't branch on cloud.

Use `shell_command`, `colorize_info`, `colorize_error` from `src/python/utils.py` — same imports as `src/python/aws.py:24-31`.

**Wire env-var forwarding in `./run`.** The existing `./run` script bind-mounts `state/` and forwards the AWS env vars per upstream `60e4695`. Add a sibling block forwarding `NB_SA_ID` / `NB_AUTHKEY_PUBLIC_ID` / `NB_AUTHKEY_PRIVATE_PATH` / `NB_PARENT_ID` so Terraform + Packer inside the container can see them. The PEM file is already visible via the bind mount.

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

Mirror `src/packer/gcp/isaac-workstation.pkr.hcl`. Use the `github.com/nebius/nebius` Packer plug-in (v0.0.6 latest; pin `>= 0.0.4` per the upstream example). Builder block name is `nebius-image` (verified).

- `required_plugins`: `nebius = { source = "github.com/nebius/nebius", version = ">= 0.0.4" }`.
- `source "nebius-image" "isaac-workstation"` block:
  - `parent_id = var.parent_id`
  - `service_account { public_key_id = var.public_key_id, account_id = var.account_id, private_key_file = var.private_key_file }`
  - `base_image { family = "ubuntu24.04-driverless" }`
  - `instance { platform = "gpu-l40s-a", preset = "1gpu-32vcpu-128gb" }`
  - `disk { size_gibibytes = 256 }`
  - `network { subnet_id = var.builder_subnet_id, associate_public_ip_address = true }`
  - `image { name = "isaacworkstation-${timestamp}", version = "0.0.1", image_family = "isaacworkstation", cpu_architecture = "amd64", image_family_human_readable = "Isaac Automator Workstation" }`
  - `communicator = "ssh"`, `ssh_username = "ubuntu"`.
- Provisioners: identical shell + ansible provisioners as the AWS/GCP templates — driver install, NoMachine install, Isaac Sim 5.0.0 install. SSH key injection is handled by the plug-in automatically.

**Packer needs a pre-existing `subnet_id` (verified).** Two options:

1. **Long-lived builder subnet (preferred for first cut).** Provision a separate `terraform/nebius-packer-bootstrap/` module that creates a single VPC + subnet dedicated to image baking. Run it once on first setup; document in `image-nebius`'s pre-flight that the subnet ID must exist and be passed in as a Packer var (likely via an env var set in `state/.nebius/profile.env`).
2. Wrap Packer in Terraform that brings up VPC+subnet, runs Packer via `local-exec`, then tears down. More surface area; defer.

Add a top-level `image-nebius` wrapper script analogous to `image-aws` to drive the Packer build from inside the IA container. The wrapper checks `NB_BUILDER_SUBNET_ID` is set and prints a one-liner instructing the user to run the bootstrap module if not.

### F. `groot_automator` repo follow-ups (out of scope for this plan, listed for tracking)

These belong in a separate follow-up plan in `groot_automator/docs/exec-plans/active/` once the IA fork lands:

- `AWS_SETUP.md` stays; add sibling `NEBIUS_SETUP.md` (account creation, service-account credential download, quota request for L40S, NoMachine install — same shape as AWS_SETUP.md's 10 sections).
- `CLAUDE.md` pin table: note the **forked** IsaacAutomator commit alongside upstream, and Nebius's `gpu-l40s-a / 1gpu-32vcpu-128gb` as the default Nebius preset.
- `ARCHITECTURE.md`: update the topology diagram to show "AWS workstation VM **or** Nebius workstation VM" — the GR00T container + ZMQ wire are unchanged.

## Critical files to create or modify (in the forked IA repo)

| Path | Action | Notes |
|---|---|---|
| `src/terraform/nebius/main.tf` | create | provider `nebius/nebius` `~> 0.6.8`, `service_account { *_env = ... }` block |
| `src/terraform/nebius/variables.tf` | create | add `platform`, `preset`, `parent_id`, `image_family` |
| `src/terraform/nebius/outputs.tf` | create | keep output names identical to AWS (`ssh_key`, `cloud`, `isaac_workstation_ip`, `isaac_workstation_vm_id`) |
| `src/terraform/nebius/common/*.tf` | create | SSH keypair via `tls_private_key`; outputs `ssh_key` + `ssh_public_key` |
| `src/terraform/nebius/vpc/*.tf` | create | `nebius_vpc_v1_network` + `nebius_vpc_v1_subnet` + `nebius_vpc_v1_allocation` (static IP) |
| `src/terraform/nebius/isaac-workstation/*.tf` | create | `nebius_compute_v1_instance` with `boot_disk.managed_disk.spec.source_image_family`, `cloud_init_user_data` for SSH-key injection, `network_interfaces[].public_ip_address.allocation_id` for static IP |
| `src/python/nebius.py` | create | mirror `src/python/aws.py`; reads `state/.nebius/profile.env` + `private.pem`, exports `NB_*` env vars |
| `deploy-nebius` | create | mirror `deploy-aws`, new instance-type allowlist; `--parent-id` required |
| `src/ansible/roles/nvidia-driver/tasks/main.yml` | edit | add `or cloud == "nebius"` to the existing generic-install `when:` on line 28 — one token, no new block |
| `src/packer/nebius/isaac-workstation.pkr.hcl` | create | `nebius-image` builder, plug-in `github.com/nebius/nebius >= 0.0.4` |
| `src/terraform/nebius-packer-bootstrap/*.tf` | create | one-shot VPC+subnet for Packer builds; outputs `subnet_id` |
| `image-nebius` | create | mirror `image-aws`; checks `NB_BUILDER_SUBNET_ID` is set |
| `run` | edit | forward `NB_SA_ID` / `NB_AUTHKEY_PUBLIC_ID` / `NB_AUTHKEY_PRIVATE_PATH` / `NB_PARENT_ID` / `NB_BUILDER_SUBNET_ID` from host env into the container |
| `Dockerfile` | edit | install Nebius CLI via `curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh \| bash` alongside the existing `aws` / `gcloud` / `az` / `aliyun` installs |

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
5. ✅ **Resolved (2026-05-28).** `src/python/deployer.py:416-429` (`export_ssh_key()`) only consumes the `ssh_key` Terraform output via `terraform output -raw ssh_key`. Cloud-agnostic. `tls_private_key` + cloud-init injection path is compatible.
6. ✅ **Resolved (2026-05-28).** Nebius exposes static IPs via `nebius_vpc_v1_allocation` and wires them through `network_interfaces[].public_ip_address.allocation_id` on the instance. Upstream invariant preserved.
7. **Cloud-init vs. metadata for SSH keys.** Plan originally said "instance metadata `ssh-keys` field"; the provider's `metadata` block is actually READ-ONLY. We use `cloud_init_user_data` (a `users` doc adding the `ubuntu` user with `ssh_authorized_keys`). Risk: cloud-init may not complete before Ansible's first SSH attempt. Mitigation: existing `wait_for_connection` task on the workstation role (already tagged `__autorun` per the recent fork commit `cb50b2e`) gives cloud-init time to land before SSH bring-up.
8. **CLI status JSON path is unconfirmed.** `nebius compute instance get --format json` schema is not documented in the public CLI ref. Pin the path on the first live `./run ./deploy-nebius` run before `./start`/`./stop` lifecycle is trustworthy.
9. **Packer needs a pre-existing subnet.** New first-time-setup step (run `terraform/nebius-packer-bootstrap/`) before `./run ./image-nebius` works. Document in `image-nebius` pre-flight.
10. **Security-group / firewall resource shape unverified on v0.6.8.** If the provider lacks a managed allow-rule resource, fall back to OS-level `ufw` rules in the existing `remote-desktop` Ansible role. Surface on first `terraform validate` during §A.

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
