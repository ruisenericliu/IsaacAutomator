# region copyright
# Copyright 2023-2026 NVIDIA Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# endregion

"""
Utils for Nebius.

Credentials model: Nebius authenticates with three discrete IDs plus a
PEM-encoded private key file (no JSON bundle, no SSO):

  - service account ID    -> NB_SA_ID
  - authorized public key -> NB_AUTHKEY_PUBLIC_ID
  - private key PEM file  -> NB_AUTHKEY_PRIVATE_PATH
  - target project ID     -> NB_PARENT_ID

These env vars are consumed natively by the Nebius Terraform provider
(via `service_account { *_env = "NB_..." }`) and by the Nebius Packer
plug-in, so once they are set the whole toolchain picks them up.

Two ways to provide them:

  1. Host env vars forwarded by ./run (preferred for CI/automation).
  2. On-disk drop at state/.nebius/profile.env + state/.nebius/private.pem.
     profile.env is a shell-style "KEY=value" file holding NB_SA_ID,
     NB_AUTHKEY_PUBLIC_ID, and NB_PARENT_ID. NB_AUTHKEY_PRIVATE_PATH is
     resolved to the PEM file's absolute path.
"""

import json
import os
import sys
from pathlib import Path

import click

from src.python.config import c as config
from src.python.utils import (
    colorize_error,
    colorize_info,
    shell_command,
)

NEBIUS_STATE_DIR = f"{config['state_dir']}/.nebius"
NEBIUS_PROFILE_ENV_FILE = f"{NEBIUS_STATE_DIR}/profile.env"
NEBIUS_PRIVATE_KEY_FILE = f"{NEBIUS_STATE_DIR}/private.pem"

_REQUIRED_ENV_VARS = (
    "NB_SA_ID",
    "NB_AUTHKEY_PUBLIC_ID",
    "NB_AUTHKEY_PRIVATE_PATH",
    "NB_PARENT_ID",
)


def _nebius_env_credentials_set():
    """True when all four required NB_* env vars are present."""
    return all(os.environ.get(v) for v in _REQUIRED_ENV_VARS)


def _read_profile_env_file(path):
    """
    Parse a shell-style KEY=value file (comments and blank lines allowed).
    Returns dict.
    """
    if not os.path.exists(path):
        return {}
    out = {}
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip().strip('"').strip("'")
        out[k.strip()] = v
    return out


def nebius_load_credentials(verbose=False):
    """
    Resolve Nebius credentials. Precedence:
      1. NB_SA_ID + NB_AUTHKEY_PUBLIC_ID + NB_AUTHKEY_PRIVATE_PATH + NB_PARENT_ID in env.
      2. state/.nebius/profile.env + state/.nebius/private.pem.

    Returns dict with the four NB_* values. Missing/invalid configurations
    print a hint and exit(1).
    """

    if _nebius_env_credentials_set():
        if verbose:
            click.echo(
                colorize_info(
                    "* Loading Nebius credentials from NB_* env vars."
                )
            )
        return {v: os.environ[v] for v in _REQUIRED_ENV_VARS}

    if verbose:
        click.echo(
            colorize_info(f"* Loading Nebius credentials from {NEBIUS_STATE_DIR}/")
        )

    profile = _read_profile_env_file(NEBIUS_PROFILE_ENV_FILE)
    pem_exists = os.path.exists(NEBIUS_PRIVATE_KEY_FILE)

    missing = []
    if not profile.get("NB_SA_ID"):
        missing.append("NB_SA_ID")
    if not profile.get("NB_AUTHKEY_PUBLIC_ID"):
        missing.append("NB_AUTHKEY_PUBLIC_ID")
    if not profile.get("NB_PARENT_ID"):
        missing.append("NB_PARENT_ID")
    if not pem_exists:
        missing.append(f"private key file at {NEBIUS_PRIVATE_KEY_FILE}")

    if missing:
        click.echo(
            colorize_error(
                "* Nebius credentials are not set. Provide either:\n"
                "  (a) host env vars NB_SA_ID / NB_AUTHKEY_PUBLIC_ID /"
                " NB_AUTHKEY_PRIVATE_PATH / NB_PARENT_ID (forwarded by ./run), or\n"
                f"  (b) on-disk drop: write a {NEBIUS_PROFILE_ENV_FILE} file with the\n"
                "      three IDs as `KEY=value` lines and put the PEM private key at\n"
                f"      {NEBIUS_PRIVATE_KEY_FILE} (chmod 600).\n"
                f"* Missing: {', '.join(missing)}"
            )
        )
        sys.exit(1)

    return {
        "NB_SA_ID": profile["NB_SA_ID"],
        "NB_AUTHKEY_PUBLIC_ID": profile["NB_AUTHKEY_PUBLIC_ID"],
        "NB_AUTHKEY_PRIVATE_PATH": NEBIUS_PRIVATE_KEY_FILE,
        "NB_PARENT_ID": profile["NB_PARENT_ID"],
    }


def _export_credentials_to_env(creds):
    """Push the resolved NB_* values into os.environ for child processes."""
    for k, v in creds.items():
        os.environ[k] = v


def _nebius_probe_auth(verbose=False):
    """
    Probe authentication with `nebius iam tenant list`. Returns True on success.
    The CLI consumes the NB_* env vars (no profile setup needed).
    """
    res = shell_command(
        "nebius iam tenant list --format json",
        verbose=verbose,
        exit_on_error=False,
        capture_output=True,
    )
    if res.returncode != 0:
        if verbose:
            stderr = res.stderr.decode().strip() if res.stderr else "(no output)"
            click.echo(colorize_info(f"* Nebius auth probe failed: {stderr}"))
        return False
    return True


def nebius_validate_credentials(verbose=False):
    """
    Load credentials, push them into the env so Terraform/Packer/CLI can see
    them, and verify they actually work by calling `nebius iam tenant list`.
    Exits the process with a clear error if anything is missing or wrong.
    """
    click.echo(colorize_info("* Validating Nebius credentials..."))

    creds = nebius_load_credentials(verbose=verbose)
    _export_credentials_to_env(creds)

    # Sanity check the PEM file's permissions; a world-readable private key is
    # not fatal but is worth a warning.
    pem_path = creds["NB_AUTHKEY_PRIVATE_PATH"]
    try:
        mode = os.stat(pem_path).st_mode & 0o777
        if mode & 0o077:
            click.echo(
                colorize_info(
                    f"* Warning: {pem_path} has permissions {oct(mode)}."
                    " Consider `chmod 600`."
                )
            )
    except OSError:
        pass

    if not _nebius_probe_auth(verbose=verbose):
        click.echo(
            colorize_error(
                "* Nebius credentials failed authentication."
                " Re-check NB_SA_ID, NB_AUTHKEY_PUBLIC_ID, the PEM file, and"
                " NB_PARENT_ID."
            )
        )
        sys.exit(1)

    click.echo(colorize_info("* Nebius credentials are valid!"))


# ---- instance lifecycle ----------------------------------------------------
#
# Nebius CLI shapes verified at docs.nebius.com/cli/reference/compute/instance/.
# The status JSON path (`.status.state`) is inferred from the analogous
# vpc_v1_security_rule schema, where `status.state` uses values like
# CREATING/READY/DELETING. Pin the exact path on first live run; see plan
# Risk 8.

# Nebius lifecycle state -> AWS-equivalent state string (the upstream Deployer
# only reads "running" / "stopping" / "stopped" / "pending" from the cloud
# wrapper; everything else is a debug-friendly passthrough).
_NEBIUS_TO_AWS_STATE = {
    "RUNNING": "running",
    "STARTING": "pending",
    "PENDING": "pending",
    "STOPPING": "stopping",
    "STOPPED": "stopped",
    "DELETING": "stopping",
    "ERROR": "stopped",
}


def nebius_stop_instance(instance_id, verbose=False):
    shell_command(
        f"nebius compute instance stop --id '{instance_id}'",
        verbose=verbose,
        exit_on_error=True,
        capture_output=True,
    )


def nebius_start_instance(instance_id, verbose=False):
    shell_command(
        f"nebius compute instance start --id '{instance_id}'",
        verbose=verbose,
        exit_on_error=True,
        capture_output=True,
    )


def nebius_get_instance_status(instance_id, verbose=False):
    """
    Query instance lifecycle state and map it to the AWS-style strings the
    upstream Deployer expects.

    Returns: "stopping" | "stopped" | "pending" | "running" | <raw lowercase>
    """
    res = shell_command(
        f"nebius compute instance get --id '{instance_id}' --format json",
        verbose=verbose,
        exit_on_error=True,
        capture_output=True,
    )
    try:
        envelope = json.loads(res.stdout.decode())
    except (json.JSONDecodeError, UnicodeDecodeError):
        if verbose:
            click.echo(
                colorize_info(
                    "* Could not parse `nebius compute instance get` output as JSON."
                )
            )
        return "unknown"

    # Best-effort traversal. The CLI ref does not document the exact path;
    # try the most likely spots in order and fall through to "unknown" so we
    # at least produce a usable string on first live run.
    state = ""
    for path in (
        ("status", "state"),
        ("status", "phase"),
        ("state",),
        ("status",),
    ):
        node = envelope
        for k in path:
            if not isinstance(node, dict):
                node = None
                break
            node = node.get(k)
        if isinstance(node, str) and node:
            state = node
            break

    if not state:
        if verbose:
            click.echo(
                colorize_info(
                    "* Could not locate lifecycle state in CLI output; envelope was:"
                    f" {json.dumps(envelope)[:200]}..."
                )
            )
        return "unknown"

    return _NEBIUS_TO_AWS_STATE.get(state.upper(), state.lower())
