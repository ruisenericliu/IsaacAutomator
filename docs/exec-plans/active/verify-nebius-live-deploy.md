# Plan: Verify the Nebius deploy target end-to-end against a live project

## Context

The Nebius implementation landed on branch `nebius` on 2026-05-28 — see [`completed/add-nebius-target.md`](../completed/add-nebius-target.md) for what shipped and the §"What changed vs. the original plan" subsection for the schema-correction trail. All static gates pass (`terraform fmt -check`, `terraform validate`, `packer fmt -check`, `packer validate`, `ast.parse`). No live `terraform apply` / `packer build` has run yet, so a class of failures the provider/plugin can't surface statically is still open:

- Provider-side semantic checks (security-rule priority interaction, `static = true` IP-survives-stop/start behavior, `network_interfaces[].ip_address = {}` private-IP auto-allocation, cloud-init injection timing vs. Ansible's first SSH attempt).
- Packer plugin runtime behavior (bootstrap-VPC create/teardown lifecycle, `image.version` numeric constraint when stripping the leading `v`, image-name uniqueness when re-running with the same `VERSION`).
- Ansible-on-Nebius (the `generic` nvidia-driver branch's CUDA keyring URL hardcodes `ubuntu2204`; Nebius's base image is `ubuntu24.04-driverless`. NoMachine `.deb` install on 24.04 is the single highest-risk unverified step).
- CLI status-JSON path (`nebius compute instance get --format json` shape isn't in the public ref; `nebius_get_instance_status()` tries `.status.state`, `.status.phase`, `.state`, `.status` in order — needs pinning).

**Intended outcome:** `./run ./deploy-nebius <name>`, `./run ./image-nebius`, `./run ./start|stop|destroy <name>` all work end-to-end against a real Nebius project, with Isaac Sim launchable over NoMachine, AWS regression intact, and any code adjustments the live runs surface folded back into the fork.

**Decisions still open (need user input before kicking off live runs):**
- Nebius project ID (`NB_PARENT_ID`) and service-account credentials.
- L40S quota — fresh tenants need a quota-increase ticket; needs to be filed before §G3.
- Whether to bake an image first (`./image-nebius`) or test the bare-OS path first (`./deploy-nebius --not-from-image`). Recommend bare-OS first — it exercises the whole Ansible pipeline, which is where the unverified pieces sit. Image baking adds 30–60 min of Packer time per cycle.

## Approach

Run the gates in dependency order: cheapest-to-fix things first, then the items that need long-running cloud actions. Each gate either passes (record the resolved JSON path / IP / runtime / etc. inline in this doc) or surfaces an issue (open a fix task, land the fix on `nebius`, re-run the gate). Treat this plan as a working log — append findings under each gate as they happen.

The "bare-OS deploy" path (§G3) is the load-bearing gate because it forces every cloud-init / security-rule / cloud-agnostic-Ansible assumption to run for real. If §G3 passes, the from-image path (§G6) becomes much cheaper to verify since the Packer run reuses most of the same Ansible.

### Pre-flight (before any live API call)

- **§G0a.** User drops `state/.nebius/profile.env` (containing `NB_SA_ID=…`, `NB_AUTHKEY_PUBLIC_ID=…`, `NB_PARENT_ID=…`) and `state/.nebius/private.pem` (chmod 600) on the host. Both files are bind-mounted into the container via `./run`. Validate by running `./run ./deploy-nebius --help` — should not crash on credential discovery. (No live API call yet — `nebius_validate_credentials` is gated to run inside `if os.path.exists("/.dockerenv")`.)
- **§G0b.** Rebuild the container: `./build`. The cached `isaac_automator:latest` is pre-Dockerfile-edit and lacks the Nebius CLI + `packer init` for `src/packer/nebius/`. After rebuild, `./run nebius version` inside the container should print a CLI version.
- **§G0c.** Confirm credentials authenticate: inside the container, `nebius iam tenant list --format json` returns at least one tenant entry. This is what `nebius_validate_credentials` probes.

### Live gates

- **§G1. Bootstrap VPC apply.** `./run` shell, then `terraform -chdir=src/terraform/nebius-packer-bootstrap init && terraform -chdir=… apply -var=parent_id=$NB_PARENT_ID`. Should land a network + subnet + SSH-allow security group. Record `subnet_id` and confirm no orphan resources. Tear down with `destroy` and re-apply to confirm idempotency. (Same Terraform shape `image-nebius` invokes internally, so this also pre-validates the wrapper.)
- **§G2. Top-level Terraform apply (bare-OS path).** Inside the container, set `NB_PARENT_ID`, run `./deploy-nebius gate2 --not-from-image --isaaclab no --isaaclab-arena no --isaacsim no --upload=no`. Watch `terraform apply` only — abort the Ansible phase (`Ctrl-C` once SSH starts) if you want to keep the gate tight. Verifications:
  - All 6 Nebius resources create cleanly (1 network, 1 subnet, 1 security group, 4 security rules — SSH/NoMachine-TCP/NoMachine-UDP/VNC/noVNC; 1 instance).
  - `terraform output isaac_workstation_ip` returns an IP address (not `"NA"`).
  - The IP is reachable on port 22 from the container (`nc -zv $IP 22`).
  - `nebius compute instance get --id <vm-id> --format json` returns a JSON envelope — capture the full output, pin `.status.<path>` for the next gate.
- **§G2a. Pin `nebius_get_instance_status` JSON path.** Using the JSON envelope from §G2, edit `src/python/nebius.py:_get_status_from_envelope()` (the fallback list) to put the actually-correct path first. Test by stopping the VM via `nebius compute instance stop --id <vm-id>` and watching `nebius_get_instance_status()` return the expected state string. The current code tries `.status.state` → `.status.phase` → `.state` → `.status` in order; remove the speculative ones once the real path is known.
- **§G3. Bare-OS Ansible run end-to-end.** `./run ./deploy-nebius gate3 --not-from-image --isaaclab no --isaaclab-arena no --upload=no` (no abort). Watch for:
  - **NVIDIA driver install on `ubuntu24.04-driverless`.** The generic branch in `nvidia-driver.generic.yml:20` fetches `cuda-keyring_1.1-1_all.deb` from the `ubuntu2204/x86_64` repo. If apt complains about repo mismatch on 24.04, switch the URL to `ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb` (the keyring file itself is repo-architecture-independent, but the repo it configures must match the host OS). Land the fix as a `when: cloud == "nebius"` override or just bump the upstream URL if 24.04 is now standard across providers.
  - **NoMachine `.deb` install.** Highest-risk step from the original plan (§Risks 3). If `apt install ./nomachine_9.5.7_2_amd64.deb` fails, capture the error and either patch the role or fall back to the mirror URL.
  - **`cloud_init_user_data` timing.** Ansible's first SSH attempt should succeed because the upstream `__autorun`-tagged `wait_for_connection` task gates everything else. If it doesn't, that's a cloud-init-took-too-long signal — extend the timeout or add an explicit delay before the role.
- **§G4. NoMachine GUI from the host.** From the Mac, connect with NoMachine client to `<IP>:4000` using the system-user credentials in `state/gate3/info.txt`. Ubuntu desktop should appear; launch Isaac Sim from the menu and confirm GPU rendering works (test scene runs at non-zero FPS, no software-rasterizer fallback).
- **§G5. Lifecycle.** From the container, run `./stop gate3` → confirm `nebius compute instance get` returns the stopped equivalent → `./start gate3` → confirm public IP is unchanged (this is what `static = true` is supposed to guarantee) → `./destroy gate3` → confirm `nebius compute instance list --parent-id $NB_PARENT_ID` no longer shows the VM and `nebius vpc network list` shows no orphans for the deployment prefix.
- **§G6. Packer image bake.** `./run ./image-nebius v4.0.0-nebius-gate6 --parent-id $NB_PARENT_ID`. The wrapper provisions the bootstrap VPC, runs `packer build`, and tears the VPC down on `finally`. Verifications:
  - Build succeeds end-to-end (30–60 min, watch for the same Ansible-on-`ubuntu24.04-driverless` issues caught in §G3 — if they were fixed there, this should be clean).
  - Image is queryable: `nebius compute image list --parent-id $NB_PARENT_ID` shows family `isaacworkstation`.
  - Bootstrap VPC is gone (`nebius vpc network list` shows no `isaac-automator-packer-net`).
- **§G7. From-image deploy.** `./run ./deploy-nebius gate7 --from-image …`. Should skip the long Ansible pipeline and land at the post-deploy banner in <5 min. Verify Isaac Sim still works over NoMachine.
- **§G8. AWS regression.** `./run ./deploy-aws gate8-aws --region us-west-2 --not-from-image --isaaclab no --isaaclab-arena no --upload=no`. Should be identical to upstream — none of the Nebius edits touched AWS source files, but the Dockerfile and `run` script changes are shared. If AWS breaks, the shared-file edits are wrong.

## Critical files likely to need edits during gates

These are the files most likely to absorb fixes from the live runs. None *should* need editing if every assumption holds — list them so the next agent knows where to look first.

| Path | Why it might change |
|---|---|
| `src/python/nebius.py` (`_get_status_from_envelope`) | Real `--format json` envelope shape (§G2a) |
| `src/ansible/roles/nvidia-driver/tasks/nvidia-driver.generic.yml:20` | CUDA keyring URL if `ubuntu2404` repo is needed |
| `src/ansible/roles/remote-desktop/tasks/main.yml` | NoMachine `.deb` install on 24.04 |
| `src/terraform/nebius/isaac-workstation/main.tf` | If `static = true` doesn't persist the IP across stop/start, may need an explicit `nebius_vpc_v1_allocation` lookup wired through `public_ip_address.allocation_id` after all |
| `src/terraform/nebius/isaac-workstation/security.tf` | Security-rule priorities / ingress shape if the provider rejects the current form at apply |
| `src/packer/nebius/isaac-workstation.pkr.hcl` (`image.version`) | If the plugin rejects the stripped-`v` form, switch to a date-based `version` string |
| `image-nebius` | Bootstrap-VPC name collisions if a previous run was killed mid-flight (need a `destroy` recovery path) |

## Risks

1. **NoMachine on `ubuntu24.04-driverless`.** Still the highest-likelihood blocker. If the `.deb` install fails, the GUI path (§G4) is dead and there's no fallback in the role. Mitigation: have the .deb URL for 24.04 ready (NoMachine ships separate packages for 22.04 vs. 24.04 in their archive).
2. **L40S quota.** First deploy will fail at §G2 with a quota error if the project's L40S allocation is 0. Mitigation: file the quota ticket before kicking off, or test §G1/§G2 with a CPU-only preset first to validate plumbing.
3. **`static = true` semantics.** The provider docs describe it as "Allocation will be created/deleted during NetworkInterface.Create/NetworkInterface.Delete" — that implies the IP outlives stop/start but not destroy/recreate. If §G5 shows the IP changes on `./start`, switch to an explicit `nebius_vpc_v1_allocation` (with `pool_id` discovered via `data "nebius_vpc_v1_pool"` lookup-by-name, since the data source supports name-based queries per the v0.6.8 schema).
4. **Security-rule priority collisions.** Rules are spaced at priorities 100/110/200/210/300/310. If the provider treats lower priority as higher precedence (the comment in `security.tf` assumes it does), an unintended DENY at lower priority anywhere in the project's other security groups could shadow these rules. Sanity-check by trying SSH from a different source IP after §G3 lands.
5. **Packer image-name collisions on retry.** `image_name` is rendered as `isaac-automator-isaacworkstation-<VERSION>-<image-name>` (lowercased, dots→dashes). Re-running `./image-nebius` with the same `VERSION` and `--image-name` will fail unless `--existing=overwrite` is passed (or the previous image is deleted manually). Document this in §G6 if it bites.
6. **Bootstrap-VPC orphans if `./image-nebius` is killed mid-flight.** The wrapper's `finally` block calls `terraform destroy`, but if the user `kill -9`s the Python process, the destroy never runs. Mitigation: `image-nebius` should check for an existing `isaac-automator-packer-net` at startup and offer to destroy it before re-applying.
7. **Stale `isaac_automator:latest` image.** §G0b is easy to skip and would manifest as `nebius: command not found` mid-deploy. Make `./run` warn if the image is older than the Dockerfile's mtime, or just always rebuild in CI.

## Verification (gate completion criteria)

Each §G* item is a manual gate; record the result inline in this doc under a `### Outcome` subheading per gate as the runs happen. Don't move the plan to `completed/` until §G3, §G4, §G5, §G6, §G7, and §G8 have all passed at least once. §G2a's JSON-path discovery should be committed back into `src/python/nebius.py` and crossed off here.

When all gates pass:
- Move this plan to `docs/exec-plans/completed/`.
- Update `CLAUDE.md`'s status line to "Nebius deploy + image-bake working end-to-end as of YYYY-MM-DD" and drop the 🟡 markers.
- Cherry-pick the resolved `nebius` branch into a release tag (`v4.0.0-nebius.1` or similar) so `groot_automator`'s IA pin has a stable target.

## Sizing estimate

**Live runs: 1–3 working days, dominated by Packer (§G6) and Ansible debug cycles (§G3).** Each `./deploy-nebius` cycle is ~10–15 min Terraform + 30–45 min Ansible from bare OS. Each `./image-nebius` cycle is 30–60 min. Budget for 3–5 cycles before §G3 passes cleanly given the NVIDIA-driver / NoMachine unknowns.
