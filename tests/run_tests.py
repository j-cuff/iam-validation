#!/usr/bin/env python3
"""Offline tests for validate-iam.sh and the policy renderers.

Each scenario builds a fake AWS environment whose IAM roles carry the policies
published in the Spectro Cloud docs (tests/fixtures/docs), runs validate-iam.sh
under /bin/bash against the mock aws and kubectl in tests/mock, and checks the
exit status and number of failed checks.

Coverage checks then confirm that validate-iam.sh simulated every action in
the documented policies, against a resource the documented statement covers.
After refreshing the fixtures with tests/sync_docs_fixtures.py, a coverage
failure names a documented permission the script does not check yet.

Usage: tests/run_tests.py [-v] [scenario-name-substring]
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
DOCS = HERE / "fixtures" / "docs"
REGRESSION = HERE / "fixtures" / "regression"
MOCK_BIN = HERE / "mock"
BASH = "/bin/bash" if os.path.exists("/bin/bash") else shutil.which("bash")

A = "111122223333"   # management (local) account
T = "444455556666"   # target account
REGION = "us-east-1"
CLUSTER = "mgmt-eks"
EXTERNAL_ID = "tenant-external-id-example"

PALETTE = "SpectroCloudPaletteRole"
HUBBLE = "SpectroCloudHubbleRole"
IDENTITY = "SpectroCloudIdentityRole"
IDENTITY_LOCAL = "SpectroCloudIdentityLocalRole"
HUBBLE_LOCAL_DOCS = "spectro-hubble-identity"   # name the docs' Hubble target trust policy expects
HUBBLE_LOCAL_TABLE = "SpectroCloudHubbleLocalRole"  # name the docs' role table suggests
PALETTE_TARGET = "SpectroCloudPaletteTargetRole"
HUBBLE_TARGET = "SpectroCloudHubbleTargetRole"
CAPA_ROLES = [
    "control-plane.cluster-api-provider-aws.sigs.k8s.io",
    "controllers.cluster-api-provider-aws.sigs.k8s.io",
    "eks-controlplane.cluster-api-provider-aws.sigs.k8s.io",
    "nodes.cluster-api-provider-aws.sigs.k8s.io",
]
PROFILE_POLICIES = {
    "minimum-dynamic": ["eks-dynamic-permissions"],
    "minimum-static": ["eks-static-permissions"],
    "core": ["core-controller-policy", "core-control-plane-policy", "core-nodes-policy",
             "core-deployment-policy", "core-controllers-eks-policy"],
}
POD_IDENTITY_SUPPLEMENT = {
    "core": "palette-pod-identity-core",
    "minimum-dynamic": "palette-pod-identity-minimum",
    "minimum-static": "palette-pod-identity-minimum",
}
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def placeholders(partition, region, hubble_local=HUBBLE_LOCAL_DOCS):
    return {
        "<partition>": partition,
        "<aws-account-id>": A,
        "<role-name-for-palette-iam-role>": PALETTE,
        "<target-aws-account-id>": T,
        "<role-name-for-palette-iam-target-role>": PALETTE_TARGET,
        "<aws-management-cluster-account-id>": A,
        "<role-name-for-identity-service-iam-local-role>": IDENTITY_LOCAL,
        "<aws-management-cluster-region>": region,
        "<management-cluster-name>": CLUSTER,
        "<hubble-service-iam-target-role>": HUBBLE_TARGET,
        "<hubble-service-iam-local-role>": hubble_local,
    }


def fixture(name, subs=None, directory=DOCS):
    text = (directory / f"{name}.json").read_text()
    for key, value in (subs or {}).items():
        text = text.replace(key, value)
    left = re.findall(r"<[a-z0-9-]+>", text)
    if left:
        raise SystemExit(f"fixture {name} has unfilled placeholders: {sorted(set(left))}")
    return json.loads(text)


def arn(account, name, partition="aws"):
    return f"arn:{partition}:iam::{account}:role/{name}"


def pod_env():
    return ["AWS_REGION", "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"]


class Scenario:
    """A fake AWS environment plus the validate-iam.conf used against it."""

    def __init__(self, name, profile="minimum-dynamic", placement=None, auth="pod-identity",
                 partition="aws", region=REGION, palette_policies=None):
        self.name = name
        self.partition = partition
        self.region = region
        self.subs = placeholders(partition, region)
        self.trust = fixture("pod-identity-trust")
        placement = placement or ("static" if profile == "minimum-static" else "dynamic")
        self.state = {
            "partition": partition,
            "profiles": {"mock": {"account": A, "arn": f"arn:{partition}:iam::{A}:user/validator", "region": region}},
            "principals": {},
            "assume": {},
            "oidc_providers": [],
            "cluster": {
                "name": CLUSTER, "status": "ACTIVE", "version": "1.31",
                "issuer": f"https://oidc.eks.{region}.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE",
                "addons": {"eks-pod-identity-agent": "ACTIVE"},
                "associations": [
                    {"NS": "hubble-system", "SA": "spectro-hubble", "Role": arn(A, HUBBLE, partition)},
                    {"NS": "palette-identity", "SA": "palette-identity", "Role": arn(A, IDENTITY, partition)},
                ],
            },
            "k8s": {
                "managementClusterName": CLUSTER,
                "pods": {
                    "hubble-system": {"name": "spectro-hubble-7d9c", "env": pod_env()},
                    "palette-identity": {"name": "palette-identity-5f6b", "env": pod_env()},
                },
            },
        }
        self.conf = {
            "AWS_PROFILE": "mock", "PARTITION": partition, "AUTH_MODE": auth, "CLUSTER_NAME": CLUSTER,
            "ACCOUNT_ID": "", "DEPLOYER_ROLE_NAME": PALETTE, "HUBBLE_ROLE_NAME": HUBBLE,
            "IDENTITY_ROLE_NAME": IDENTITY, "PERMISSION_PROFILE": profile, "PLACEMENT_MODE": placement,
            "STS_EXTERNAL_ID": "", "STS_SESSION_TAGS": "false", "TARGET_ACCOUNT_ID": "",
            "TARGET_DEPLOYER_ROLE_NAME": "", "TARGET_HUBBLE_ROLE_NAME": "", "TARGET_AWS_PROFILE": "",
        }
        self.env = {}
        self.policies = palette_policies or [fixture(n) for n in PROFILE_POLICIES[profile]]
        palette_policies = list(self.policies)
        if auth == "pod-identity":
            palette_policies.append(fixture(POD_IDENTITY_SUPPLEMENT[profile]))
        if auth == "secret":
            self.state["principals"][f"arn:{partition}:iam::{A}:user/validator"] = {"policies": palette_policies}
        else:
            self.role(A, PALETTE, self.trust, palette_policies)
        if auth == "sts":
            self.state["assume"][arn(A, PALETTE, partition)] = {"trusted_accounts": [A], "external_id": EXTERNAL_ID}
            self.conf["STS_EXTERNAL_ID"] = EXTERNAL_ID
        self.role(A, HUBBLE, self.trust, [fixture("hubble-permissions")])
        self.role(A, IDENTITY, self.trust, [fixture("identity-permissions", self.subs)])
        for capa in CAPA_ROLES:
            self.role(A, capa, {"Version": "2012-10-17", "Statement": []}, [])

    def role(self, account, name, trust, policies):
        self.state["principals"][arn(account, name, self.partition)] = {"trust": trust, "policies": policies}

    def drop_role(self, account, name):
        self.state["principals"].pop(arn(account, name, self.partition), None)

    def make_cross_account(self, profile="minimum-dynamic", target_profile=True, hubble_local=HUBBLE_LOCAL_DOCS):
        """Rebuild roles to match the docs' Pod Identity cross-account model."""
        self.subs = placeholders(self.partition, self.region, hubble_local)
        for name in (PALETTE, HUBBLE, IDENTITY):
            self.drop_role(A, name)
        for capa in CAPA_ROLES:
            self.drop_role(A, capa)
            self.role(T, capa, {"Version": "2012-10-17", "Statement": []}, [])
        self.role(A, IDENTITY_LOCAL, self.trust, [fixture("identity-local-cross-permissions", self.subs)])
        self.role(A, hubble_local, self.trust, [fixture("hubble-local-cross-permissions", self.subs)])
        self.role(T, PALETTE_TARGET, fixture("palette-target-trust", self.subs),
                  [fixture(n) for n in PROFILE_POLICIES[profile]] + [fixture(POD_IDENTITY_SUPPLEMENT[profile])])
        self.role(T, HUBBLE_TARGET, fixture("hubble-target-trust", self.subs), [fixture("hubble-target-permissions")])
        self.state["cluster"]["associations"] = [
            {"NS": "hubble-system", "SA": "spectro-hubble", "Role": arn(A, hubble_local, self.partition)},
            {"NS": "palette-identity", "SA": "palette-identity", "Role": arn(A, IDENTITY_LOCAL, self.partition)},
        ]
        self.state["profiles"]["target"] = {"account": T, "arn": f"arn:{self.partition}:iam::{T}:user/validator", "region": self.region}
        self.conf.update({
            "HUBBLE_ROLE_NAME": hubble_local, "IDENTITY_ROLE_NAME": IDENTITY_LOCAL, "TARGET_ACCOUNT_ID": T,
            "TARGET_DEPLOYER_ROLE_NAME": PALETTE_TARGET, "TARGET_HUBBLE_ROLE_NAME": HUBBLE_TARGET,
            "TARGET_AWS_PROFILE": "target" if target_profile else "",
        })
        return self


def write_conf(path, conf):
    lines = [f'{key}="{value}"' for key, value in conf.items()]
    path.write_text("\n".join(lines) + "\n")


def run_script(script, scenario, tmp, args=()):
    state_file, conf_file, log_file = tmp / "state.json", tmp / "validate-iam.conf", tmp / "calls.log"
    state_file.write_text(json.dumps(scenario.state))
    write_conf(conf_file, scenario.conf)
    log_file.write_text("")
    path = [str(MOCK_BIN)]
    for tool in ("jq", "python3"):
        found = shutil.which(tool)
        if found:
            path.append(str(pathlib.Path(found).parent))
    path += ["/usr/bin", "/bin"]
    env = {
        "PATH": os.pathsep.join(path), "HOME": str(tmp), "TMPDIR": str(tmp),
        "MOCK_STATE": str(state_file), "MOCK_LOG": str(log_file), "CONFIG_FILE": str(conf_file),
    }
    env.update(scenario.env)
    proc = subprocess.run([BASH, str(REPO / script), *args], env=env, capture_output=True, text=True, timeout=300)
    output = ANSI.sub("", proc.stdout + proc.stderr)
    calls = [json.loads(line) for line in log_file.read_text().splitlines() if line.strip()]
    return proc.returncode, output, calls


def glob(pattern, value, ignore_case=False):
    regex = "^" + re.escape(pattern).replace(r"\*", ".*").replace(r"\?", ".") + "$"
    return re.match(regex, value, re.I if ignore_case else 0) is not None


def simulated(calls, principal):
    pairs = set()
    for call in calls:
        args = call["args"]
        if args[:2] != ["iam", "simulate-principal-policy"]:
            continue
        if args[args.index("--policy-source-arn") + 1] != principal:
            continue

        def values(flag):
            i = args.index(flag) + 1
            out = []
            while i < len(args) and not args[i].startswith("--"):
                out.append(args[i])
                i += 1
            return out
        for action in values("--action-names"):
            for resource in values("--resource-arns"):
                pairs.add((action, resource))
    return pairs


def uncovered(calls, principal, policy):
    """Documented (statement, action) pairs the script never simulated."""
    pairs = simulated(calls, principal)
    missing = []
    for st in policy["Statement"]:
        if st.get("Effect") != "Allow":
            continue
        acts = st["Action"] if isinstance(st["Action"], list) else [st["Action"]]
        res = st.get("Resource", "*")
        res = res if isinstance(res, list) else [res]
        for action in acts:
            if not any(glob(action, a, True) and any(glob(r, resource) for r in res) for a, resource in pairs):
                missing.append(f"{st.get('Sid', '<no Sid>')}: {action}")
    return missing


class Runner:
    def __init__(self, verbose, only):
        self.verbose, self.only = verbose, only
        self.results = []

    def case(self, title, scenario, rc=0, fails=0, args=(), contains=(), absent=(), coverage=(), script="validate-iam.sh"):
        if self.only and self.only not in title:
            return
        with tempfile.TemporaryDirectory() as tmp:
            code, output, calls = run_script(script, scenario, pathlib.Path(tmp), args)
        fail_count = output.count("[FAIL]")
        problems = []
        if code != rc:
            problems.append(f"exit status {code}, expected {rc}")
        if fails is not None and fail_count != fails:
            problems.append(f"{fail_count} FAIL lines, expected {fails}")
        for text in contains:
            if text not in output:
                problems.append(f"output lacks: {text!r}")
        for text in absent:
            if text in output:
                problems.append(f"output unexpectedly has: {text!r}")
        for principal, policy_name, policy in coverage:
            for item in uncovered(calls, principal, policy):
                problems.append(f"not checked by validate-iam.sh ({policy_name} on {principal.split('/')[-1]}): {item}")
        if "unbound variable" in output:
            problems.append("bash reported an unbound variable")
        self.report(title, problems, output)

    def report(self, title, problems, output=""):
        self.results.append((title, problems))
        print(f"{'PASS' if not problems else 'FAIL'}  {title}")
        for p in problems:
            print(f"        - {p}")
        if problems and self.verbose:
            print("\n".join("        | " + line for line in output.splitlines()))


def main():
    verbose = "-v" in sys.argv
    only = next((a for a in sys.argv[1:] if not a.startswith("-")), None)
    r = Runner(verbose, only)

    # ── Same-account Pod Identity with each documented permission profile ──
    for profile, placement in (("minimum-dynamic", "dynamic"), ("minimum-static", "static"),
                               ("core", "dynamic"), ("core", "static")):
        s = Scenario(f"pod-identity {profile}/{placement}", profile=profile, placement=placement)
        coverage = [
            (arn(A, HUBBLE), "hubble-permissions", fixture("hubble-permissions")),
            (arn(A, IDENTITY), "identity-permissions", fixture("identity-permissions", s.subs)),
            (arn(A, PALETTE), POD_IDENTITY_SUPPLEMENT[profile], fixture(POD_IDENTITY_SUPPLEMENT[profile])),
        ]
        if profile != "core":
            name = PROFILE_POLICIES[profile][0]
            coverage.append((arn(A, PALETTE), name, fixture(name)))
        r.case(f"docs {profile} policies ({placement} placement) pass in pod-identity mode, and every documented action is checked",
               s, coverage=coverage)

    # ── The November 3, 2026 docs update ──
    s = Scenario("old dynamic", palette_policies=[fixture("eks-dynamic-permissions-2026-02-21", directory=REGRESSION)])
    # 38 new checks; the Pod Identity supplement's iam:PassRole on "*" satisfies 2 of them.
    r.case("pre-Nov-3-2026 Minimum EKS Dynamic policy fails the 36 newly documented checks it lacks", s, rc=1, fails=36,
           contains=["IAMClusterRoles", "EKSOptimizedAMILookup", "ASGManagement"])
    s = Scenario("old dynamic secret", auth="secret",
                 palette_policies=[fixture("eks-dynamic-permissions-2026-02-21", directory=REGRESSION)])
    r.case("pre-Nov-3-2026 policy on a static-credential IAM user fails all 38 newly documented checks", s, rc=1, fails=38)

    static = fixture("eks-static-permissions")
    for st in static["Statement"]:
        if st.get("Sid") == "EC2Permissions":
            st["Action"] = [a for a in st["Action"] if a != "ec2:DescribeAddresses"]
    r.case("static placement now checks ec2:DescribeAddresses", Scenario("static", profile="minimum-static", palette_policies=[static]),
           rc=1, fails=1, contains=["ec2:DescribeAddresses  →  implicitDeny"])

    # ── Secret and STS modes ──
    s = Scenario("secret", auth="secret")
    r.case("secret mode with the docs minimum-dynamic policy on the IAM user", s,
           coverage=[(f"arn:aws:iam::{A}:user/validator", "eks-dynamic-permissions", fixture("eks-dynamic-permissions"))])
    s = Scenario("secret role", auth="secret")
    s.state["profiles"]["mock"]["arn"] = f"arn:aws:sts::{A}:assumed-role/Admin/session"
    r.case("secret mode rejects an assumed-role caller", s, rc=1, fails=1, contains=["Secret mode requires long-lived credentials"])

    r.case("sts mode passes with the tenant external ID", Scenario("sts", auth="sts"),
           contains=["sts:AssumeRole with external ID into"])
    s = Scenario("sts no id", auth="sts")
    s.conf["STS_EXTERNAL_ID"] = ""
    r.case("sts mode without STS_EXTERNAL_ID warns and fails the assume-role check", s, rc=1, fails=1,
           contains=["STS_EXTERNAL_ID is empty", "set STS_EXTERNAL_ID"])
    s = Scenario("sts tags", auth="sts")
    s.conf["STS_SESSION_TAGS"] = "true"
    r.case("sts mode with STS_SESSION_TAGS=true fails when the trust policy lacks sts:TagSession", s, rc=1, fails=1,
           contains=["sts:TagSession"])

    # ── GovCloud and region handling ──
    s = Scenario("gov", partition="aws-us-gov", region="us-gov-west-1")
    r.case("GovCloud with the docs policy verbatim fails the 4 OIDC checks (docs use arn:aws) and explains why", s,
           rc=1, fails=4, contains=["never matches in partition 'aws-us-gov'"])
    patched = fixture("eks-dynamic-permissions")
    for st in patched["Statement"]:
        if st.get("Sid") == "IAMOpenIDConnectProviderPermissions":
            st["Resource"] = ["arn:*:iam::*:oidc-provider/*"]
    s = Scenario("gov env region", partition="aws-us-gov", region="us-gov-west-1", palette_policies=[patched])
    s.state["profiles"]["mock"]["region"] = ""
    s.env["AWS_REGION"] = "us-gov-west-1"
    r.case("GovCloud with the OIDC statement fixed and the region only in AWS_REGION passes", s,
           contains=["Region      : us-gov-west-1", "AWS region 'us-gov-west-1' is a valid GovCloud region"])
    s = Scenario("oidc registered")
    s.state["oidc_providers"] = [f"arn:aws:iam::{A}:oidc-provider/oidc.eks.{REGION}.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"]
    r.case("OIDC provider ARN is built from the cluster issuer", s, contains=["OIDC provider registered in IAM"])

    # ── Cross-account Pod Identity (docs model) ──
    s = Scenario("cross").make_cross_account(target_profile=False)
    r.case("cross-account without TARGET_AWS_PROFILE checks local roles and warns about the target side", s,
           contains=["TARGET_AWS_PROFILE not set"],
           coverage=[(arn(A, IDENTITY_LOCAL), "identity-local-cross-permissions", fixture("identity-local-cross-permissions", s.subs)),
                     (arn(A, HUBBLE_LOCAL_DOCS), "hubble-local-cross-permissions", fixture("hubble-local-cross-permissions", s.subs))])
    s = Scenario("cross full").make_cross_account()
    r.case("cross-account with TARGET_AWS_PROFILE validates target roles, trusts, and external IDs", s,
           contains=["includes sts:ExternalId 'us-east-1/111122223333/mgmt-eks/palette-identity/palette-identity'",
                     "includes sts:ExternalId 'us-east-1/111122223333/mgmt-eks/hubble-system/spectro-hubble'"],
           coverage=[(arn(T, PALETTE_TARGET), "eks-dynamic-permissions", fixture("eks-dynamic-permissions")),
                     (arn(T, PALETTE_TARGET), "palette-pod-identity-minimum", fixture("palette-pod-identity-minimum")),
                     (arn(T, HUBBLE_TARGET), "hubble-target-permissions", fixture("hubble-target-permissions"))])
    s = Scenario("cross table name").make_cross_account(hubble_local=HUBBLE_LOCAL_TABLE)
    # Keep the docs' Hubble target trust verbatim: it names role/spectro-hubble-identity.
    s.role(T, HUBBLE_TARGET, fixture("hubble-target-trust", placeholders("aws", REGION)), [fixture("hubble-target-permissions")])
    r.case("cross-account flags a Hubble target trust that names a different local role (docs inconsistency)", s,
           rc=1, fails=2, contains=[f"does not allow '{arn(A, HUBBLE_LOCAL_TABLE)}' to sts:AssumeRole"])
    s = Scenario("cross no tag").make_cross_account()
    trust = s.state["principals"][arn(T, PALETTE_TARGET)]["trust"]
    trust["Statement"] = [st for st in trust["Statement"] if st.get("Action") != "sts:TagSession"]
    r.case("cross-account fails when the Palette target trust lacks sts:TagSession for the identity role", s, rc=1, fails=1)
    s = Scenario("cross bad id").make_cross_account()
    for st in s.state["principals"][arn(T, PALETTE_TARGET)]["trust"]["Statement"]:
        cond = st.get("Condition", {}).get("StringEquals", {})
        if "sts:ExternalId" in cond:
            cond["sts:ExternalId"] = "us-east-1/111122223333/other-cluster/palette-identity/palette-identity"
    r.case("cross-account fails on a wrong palette-identity external ID", s, rc=1, fails=1,
           contains=["has no sts:ExternalId 'us-east-1/111122223333/mgmt-eks/palette-identity/palette-identity'"])

    # ── CAPA roles and CloudFormation stack management ──
    s = Scenario("capa missing")
    for capa in CAPA_ROLES:
        s.drop_role(A, capa)
    r.case("missing CAPA roles without Option 1 stack permissions fail", s, rc=1, fails=1,
           contains=["CAPA role(s) missing and the Palette principal lacks"])
    s = Scenario("capa missing cfn", palette_policies=[fixture("eks-dynamic-permissions"), fixture("cloudformation-stack-permissions")])
    for capa in CAPA_ROLES:
        s.drop_role(A, capa)
    r.case("missing CAPA roles pass when Palette can manage the stack (Option 1), and every Option 1 action is checked", s,
           contains=["will create them"],
           coverage=[(arn(A, PALETTE), "cloudformation-stack-permissions", fixture("cloudformation-stack-permissions"))])

    # ── Robustness ──
    s = Scenario("old config")
    s.conf = {k: v for k, v in s.conf.items() if k in ("AWS_PROFILE", "PARTITION", "AUTH_MODE", "DEPLOYER_ROLE_NAME",
                                                       "HUBBLE_ROLE_NAME", "IDENTITY_ROLE_NAME", "PLACEMENT_MODE")}
    r.case("a config from before CLUSTER_NAME/TARGET_*/STS_* existed still runs", s, contains=["CLUSTER_NAME not set"])
    s = Scenario("k8s 2.0")
    s.state["cluster"]["version"] = "2.0"
    r.case("Kubernetes 2.0 passes the 1.24+ version check", s, contains=["Kubernetes version 2.0 >= 1.24"])
    s = Scenario("assoc")
    s.state["cluster"]["associations"][0]["Role"] = arn(A, "SomeOtherRole")
    r.case("an association bound to an unexpected role is reported", s, contains=["uses 'arn:aws:iam::111122223333:role/SomeOtherRole'"])
    s = Scenario("pod env")
    s.state["k8s"]["pods"]["hubble-system"]["env"] = ["AWS_REGION"]
    r.case("pods without Pod Identity env vars fail", s, rc=1, fails=2)
    s = Scenario("missing palette role")
    s.drop_role(A, PALETTE)
    r.case("a missing Palette role fails once instead of cascading", s, rc=1, fails=2,
           contains=["IAM role 'SpectroCloudPaletteRole' not found"])
    r.case("rejects two positional arguments", Scenario("args"), rc=2, fails=0, args=("sts", "secret"))

    # ── Renderers ──
    for script, expect in (("render-capa-policy.sh", f"arn:aws-us-gov:iam::{A}:role/*.cluster-api-provider-aws.sigs.k8s.io"),
                           ("render-identity-policy.sh", f"arn:aws-us-gov:iam::{A}:role/{PALETTE}")):
        title = f"{script} renders valid JSON for the configured partition and account"
        if only and only not in title:
            continue
        with tempfile.TemporaryDirectory() as tmp:
            code, output, _ = run_script(script, Scenario("render", partition="aws-us-gov", region="us-gov-west-1"), pathlib.Path(tmp))
        problems = []
        try:
            doc = json.loads(output)
            if expect not in json.dumps(doc) or "${" in json.dumps(doc):
                problems.append(f"expected resource {expect}")
        except ValueError:
            problems.append(f"not JSON (exit {code}): {output[:200]}")
        r.report(title, problems, output)

    failed = [t for t, p in r.results if p]
    print(f"\n{len(r.results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
