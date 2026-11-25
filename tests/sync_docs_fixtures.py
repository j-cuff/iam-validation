#!/usr/bin/env python3
"""Refresh policies/spectro-docs from the Spectro Cloud documentation source.

These files are the IAM policies and CloudFormation template published in the
Spectro Cloud docs (github.com/spectrocloud/librarium). setup-iam.sh applies
them, and tests/run_tests.py checks that a role with exactly these policies
passes validate-iam.sh and that the validator simulates every documented
action. Re-run this after Spectro Cloud updates the docs, then run the tests:
coverage failures show which checks validate-iam.sh is missing.

Usage:
  tests/sync_docs_fixtures.py                     # fetch from GitHub (master)
  tests/sync_docs_fixtures.py --from-dir LIBRARIUM  # use a local clone
"""
import argparse
import datetime
import json
import pathlib
import re
import sys
import textwrap
import urllib.request

RAW = "https://raw.githubusercontent.com/spectrocloud/librarium/master/"
HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / "policies" / "spectro-docs"

# Single-policy partials: fixture name -> partial path.
PERMISSION_PARTIALS = {
    "eks-dynamic-permissions": "_partials/permissions/_aws-eks-dynamic-permissions.mdx",
    "eks-static-permissions": "_partials/permissions/_aws-eks-static-permissions.mdx",
    "core-controller-policy": "_partials/permissions/_aws-controller-policy.mdx",
    "core-control-plane-policy": "_partials/permissions/_aws-control-plane-policy.mdx",
    "core-nodes-policy": "_partials/permissions/_aws-nodes-policy.mdx",
    "core-deployment-policy": "_partials/permissions/_aws-deployment-policy.mdx",
    "core-controllers-eks-policy": "_partials/permissions/_aws-eks-controller-policy.mdx",
    "cloudformation-stack-permissions": "_partials/permissions/_aws-cloudformation-stack-permissions.mdx",
}

# The EKS Pod Identity prerequisites partial holds 16 JSON blocks. Map block
# index -> fixture name; blocks that repeat another block map to None and are
# compared against the block named in DUPLICATES.
POD_IDENTITY_PARTIAL = "_partials/clusters/aws/eks-pod-identity/_eks-pod-identity-prerequisites.mdx"
POD_IDENTITY_BLOCKS = {
    0: "pod-identity-trust",
    1: "palette-pod-identity-core",
    2: "palette-pod-identity-minimum",
    4: "hubble-permissions",
    6: "identity-permissions",
    8: "identity-local-cross-permissions",
    9: "palette-target-trust",
    12: "hubble-target-trust",
    13: "hubble-target-permissions",
    15: "hubble-local-cross-permissions",
}
DUPLICATES = {3: 0, 5: 0, 7: 0, 10: 1, 11: 2, 14: 0}
EXPECTED_BLOCKS = 16

CFN_TEMPLATE_PARTIAL = "_partials/permissions/_aws-palette-cloud-formation-input-template.mdx"
CFN_TEMPLATE_FILE = "palette-cloudformation-input-template.yaml"


def read(source, rel):
    if source.startswith("http"):
        with urllib.request.urlopen(source + rel, timeout=30) as resp:
            return resp.read().decode()
    return (pathlib.Path(source) / rel).read_text()


def json_blocks(text):
    return [m.group(1) for m in re.finditer(r"```json[^\n]*\n(.*?)```", text, re.S)]


def last_update(text):
    m = re.search(r"\*\*Last Update\*\*:\s*(.+)", text)
    return m.group(1).strip() if m else "not stated"


def actions(policy):
    out = set()
    for st in policy.get("Statement", []):
        a = st.get("Action", [])
        out.update([a] if isinstance(a, str) else a)
    return out


def write(name, policy, changes):
    path = OUT / f"{name}.json"
    old = json.loads(path.read_text()) if path.exists() else None
    path.write_text(json.dumps(policy, indent=2) + "\n")
    if old != policy:
        added = sorted(actions(policy) - actions(old or {}))
        removed = sorted(actions(old or {}) - actions(policy))
        changes.append((name, added, removed, old is None))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from-dir", help="local librarium checkout instead of GitHub")
    args = ap.parse_args()
    source = args.from_dir or RAW
    OUT.mkdir(parents=True, exist_ok=True)
    changes, stamps = [], []

    for name, rel in PERMISSION_PARTIALS.items():
        text = read(source, rel)
        blocks = json_blocks(text)
        if len(blocks) != 1:
            sys.exit(f"ERROR: expected one JSON block in {rel}, found {len(blocks)}")
        write(name, json.loads(blocks[0]), changes)
        stamps.append((name, rel, last_update(text)))

    text = read(source, POD_IDENTITY_PARTIAL)
    blocks = json_blocks(text)
    if len(blocks) != EXPECTED_BLOCKS:
        sys.exit(f"ERROR: {POD_IDENTITY_PARTIAL} now has {len(blocks)} JSON blocks, not {EXPECTED_BLOCKS}. "
                 "The page changed: update POD_IDENTITY_BLOCKS in this script and review validate-iam.sh.")
    parsed = []
    for raw in blocks:
        obj = json.loads(raw)
        if "Statement" not in obj:  # the docs show a bare statement for the Hubble local role
            obj = {"Version": "2012-10-17", "Statement": [obj]}
        parsed.append(obj)
    for dup, original in DUPLICATES.items():
        if parsed[dup] != parsed[original]:
            print(f"WARNING: Pod Identity block {dup} no longer matches block {original}; review the docs page.")
    for idx, name in POD_IDENTITY_BLOCKS.items():
        write(name, parsed[idx], changes)
        stamps.append((name, f"{POD_IDENTITY_PARTIAL} (JSON block {idx})", "not stated"))

    text = read(source, CFN_TEMPLATE_PARTIAL)
    yaml_blocks = [m.group(1) for m in re.finditer(r"```ya?ml[^\n]*\n(.*?)```", text, re.S)]
    if len(yaml_blocks) != 1:
        sys.exit(f"ERROR: expected one YAML block in {CFN_TEMPLATE_PARTIAL}, found {len(yaml_blocks)}")
    template = textwrap.dedent(yaml_blocks[0]).rstrip() + "\n"
    path = OUT / CFN_TEMPLATE_FILE
    if not path.exists() or path.read_text() != template:
        changes.append((CFN_TEMPLATE_FILE, [], [], not path.exists()))
    path.write_text(template)
    stamps.append((CFN_TEMPLATE_FILE.rsplit(".", 1)[0], CFN_TEMPLATE_PARTIAL, last_update(text)))

    today = datetime.date.today().isoformat()
    lines = [
        "# Spectro Cloud docs policies",
        "",
        f"Extracted on {today} by `tests/sync_docs_fixtures.py` from",
        "[spectrocloud/librarium](https://github.com/spectrocloud/librarium) (`master`).",
        "Placeholders such as `<partition>` are kept as published; setup-iam.sh and the tests fill them in.",
        "setup-iam.sh also rewrites hardcoded `arn:aws:` ARNs for other partitions.",
        "",
        "| Fixture | Source | Docs \"Last Update\" |",
        "| --- | --- | --- |",
    ] + [f"| `{n}{'.yaml' if n == CFN_TEMPLATE_FILE.rsplit('.', 1)[0] else '.json'}` | `{r}` | {u} |" for n, r, u in stamps]
    (OUT / "SOURCE.md").write_text("\n".join(lines) + "\n")

    if not changes:
        print("Fixtures already match the docs.")
    for name, added, removed, new in changes:
        print(f"{'NEW' if new else 'CHANGED'}: {name if '.' in name else name + '.json'}")
        for a in added if not new else []:
            print(f"    + {a}")
        for a in removed:
            print(f"    - {a}")
    print("Next: run tests/run_tests.py and update validate-iam.sh for any coverage failures.")


if __name__ == "__main__":
    main()
