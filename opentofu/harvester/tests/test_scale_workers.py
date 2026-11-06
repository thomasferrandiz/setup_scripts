import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scale-workers.sh"
MOCK = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

directory = Path(os.environ["MOCK_DIRECTORY"])
settings = json.loads((directory / "settings.json").read_text())
count_file = directory / "count"
count = int(count_file.read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]
if command == "tofu":
    if args == ["show", "-json"]:
        names = settings.get("names", [f"bench-wk-{i:02d}" for i in range(1, count + 1)])
        servers = [
            {"type": "harvester_virtualmachine", "name": resource, "values": {"name": name}}
            for resource, name in settings.get("servers", [])
        ]
        outputs = {}
        if "roles" in settings:
            outputs["rke2_servers"] = {"value": {"roles": settings["roles"]}}
        print(json.dumps({"values": {"outputs": outputs, "root_module": {"resources": servers + [
            {"type": "harvester_virtualmachine", "name": "bench_worker", "index": name}
            for name in names
        ]}}}))
    elif args[:1] == ["apply"]:
        variables = dict(arg[len("-var="):].split("=", 1) for arg in args if arg.startswith("-var="))
        count = int(variables["rke2_worker_count"])
        with (directory / "applies").open("a") as log:
            log.write(f"{count}\n")
        with (directory / "topologies").open("a") as log:
            log.write(variables["rke2_control_plane"] + "\n")
        if count == settings.get("fail_apply"):
            print("Mock apply failure", file=sys.stderr)
            sys.exit(1)
        count_file.write_text(str(count))
    elif args == ["output", "-json", "virtual_machines"]:
        print(json.dumps({
            "bench-cp-01": {"ip_address": "192.168.64.10"},
            "bench-net-01": {"ip_address": settings.get("jump_ip", "192.168.1.20")},
        }))
    else:
        sys.exit(f"Unexpected tofu arguments: {args}")
elif command == "ssh":
    if args[:4] != ["-i", os.environ["EXPECTED_KEY"], "-o", "IdentitiesOnly=yes"]:
        sys.exit(f"Unexpected SSH identity arguments: {args[:4]}")
    if args[args.index("--") + 1] != "opensuse@" + settings.get("jump_ip", "192.168.1.20"):
        sys.exit("Unexpected jump-host SSH destination")
    if "opensuse@192.168.64.10 sudo" not in args[-1]:
        sys.exit("Unexpected bootstrap SSH destination")
    with (directory / "queries").open("a") as log:
        log.write(f"{count}\n")
    if settings.get("ssh_failure"):
        print("Mock SSH failure", file=sys.stderr)
        sys.exit(1)
    topology = (directory / "topologies").read_text().split()[-1]
    if topology == "dedicated-etcd":
        names = ["bench-etcd-01", "bench-etcd-02", "bench-etcd-03", "bench-cp-01", "bench-cp-02", "bench-cp-03"]
    else:
        names = ["bench-cp-01", "bench-cp-02", "bench-cp-03"]
    names += [f"bench-wk-{i:02d}" for i in range(1, count + 1)]
    print(json.dumps({"items": [
        {"metadata": {"name": name}, "status": {"conditions": [
            {"type": "Ready", "status": "False" if name == settings.get("not_ready") else "True"}
        ]}}
        for name in names if name != settings.get("missing")
    ]}))
elif command == "sleep":
    # Interrupt a blocked readiness gate rather than waiting 30 minutes in tests.
    print("Mock interrupted readiness wait", file=sys.stderr)
    sys.exit(1)
else:
    sys.exit(f"Unexpected command: {command}")
"""

STACKED = [("bench_bootstrap", "bench-cp-01"), ("bench", "bench-cp-02"), ("bench", "bench-cp-03")]
DEDICATED = [("bench_bootstrap", "bench-etcd-01")] + [
    ("bench", name) for name in ("bench-etcd-02", "bench-etcd-03", "bench-cp-01", "bench-cp-02", "bench-cp-03")]
DEDICATED_ROLES = {"bench-etcd-01": "etcd", "bench-etcd-02": "etcd", "bench-etcd-03": "etcd",
                   "bench-cp-01": "control-plane", "bench-cp-02": "control-plane",
                   "bench-cp-03": "control-plane"}


class ScaleWorkersTest(unittest.TestCase):
    def run_scaling(self, existing, target=None, with_key=True, control_plane=None,
                    **settings):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            script = directory / "scale-workers.sh"
            shutil.copy(SCRIPT, script)
            key = directory / "jump_host.key"
            if with_key:
                key.write_text("dummy key\n")
                key.chmod(0o600)
            (directory / "count").write_text(str(existing))
            (directory / "settings.json").write_text(json.dumps(settings))
            for command in ("tofu", "ssh", "sleep"):
                executable = directory / command
                executable.write_text(MOCK)
                executable.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{directory}{os.pathsep}{os.environ['PATH']}",
                "MOCK_DIRECTORY": temporary,
                "EXPECTED_KEY": str(key),
            }
            environment.pop("CONTROL_PLANE", None)
            if control_plane is not None:
                environment["CONTROL_PLANE"] = control_plane
            args = ["bash", str(script)]
            if target is not None:
                args.append(str(target))
            result = subprocess.run(
                args, env=environment, capture_output=True, text=True, timeout=30
            )

            def counts(name):
                path = directory / name
                return [int(line) for line in path.read_text().splitlines()] if path.exists() else []

            topologies = directory / "topologies"
            self.topologies = topologies.read_text().split() if topologies.exists() else []
            return result, counts("applies"), counts("queries")

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_default_target_scales_existing_fifty_to_one_thousand(self):
        result, applies, queries = self.run_scaling(50)
        self.assert_success(result)
        self.assertEqual(applies, list(range(50, 1001, 50)))
        self.assertEqual(queries, applies)

    def test_fresh_cluster_bootstraps_before_first_batch(self):
        result, applies, queries = self.run_scaling(0, 100)
        self.assert_success(result)
        self.assertEqual(applies, [0, 50, 100])
        self.assertEqual(queries, applies)

    def test_partial_batch_resumes_without_deleting_workers(self):
        result, applies, queries = self.run_scaling(72, 125)
        self.assert_success(result)
        self.assertEqual(applies, [72, 100, 125])
        self.assertEqual(queries, applies)

    def test_completed_rollout_only_reconciles_and_checks(self):
        result, applies, queries = self.run_scaling(1000)
        self.assert_success(result)
        self.assertEqual(applies, [1000])
        self.assertEqual(queries, [1000])

    def test_refuses_scale_down(self):
        result, applies, _ = self.run_scaling(100, 50)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to scale down", result.stderr)
        self.assertEqual(applies, [])

    def test_gap_from_interrupted_batch_is_filled_before_next_batch(self):
        names = [f"bench-wk-{i:02d}" for i in range(1, 451) if i != 431]
        result, applies, queries = self.run_scaling(450, 500, names=names)
        self.assert_success(result)
        self.assertIn("1 worker(s) below bench-wk-450 are missing", result.stdout)
        self.assertEqual(applies, [450, 500])
        self.assertEqual(queries, applies)

    def test_refuses_unexpected_worker_names(self):
        for name in ("bench-wk-1", "bench-wk-007", "bench-wk-x", "other-01"):
            with self.subTest(name=name):
                result, applies, _ = self.run_scaling(2, names=["bench-wk-02", name])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected worker names", result.stderr)
                self.assertEqual(applies, [])

    def test_invalid_targets_do_not_apply(self):
        for target in (0, -1, 1001, "10000", "1.5", "050", "abc"):
            with self.subTest(target=target):
                result, applies, _ = self.run_scaling(50, target)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(applies, [])

    def test_failed_apply_does_not_query_or_start_next_batch(self):
        result, applies, queries = self.run_scaling(50, fail_apply=100)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(applies, [50, 100])
        self.assertEqual(queries, [50])

    def test_unready_worker_blocks_next_batch(self):
        result, applies, queries = self.run_scaling(50, not_ready="bench-wk-100")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(applies, [50, 100])
        self.assertEqual(queries, [50, 100])

    def test_missing_worker_blocks_next_batch(self):
        result, applies, _ = self.run_scaling(50, missing="bench-wk-100")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(applies, [50, 100])

    def test_unready_control_plane_blocks_scaling(self):
        result, applies, _ = self.run_scaling(50, not_ready="bench-cp-03")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(applies, [50])

    def test_ssh_failure_blocks_scaling(self):
        result, applies, _ = self.run_scaling(50, ssh_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not query node readiness", result.stderr)
        self.assertEqual(applies, [50])

    def test_missing_jump_host_key_blocks_scaling(self):
        result, applies, queries = self.run_scaling(50, with_key=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("jump_host.key", result.stderr)
        self.assertEqual(applies, [])
        self.assertEqual(queries, [])

    def test_discovers_jump_host_address_from_output(self):
        result, applies, queries = self.run_scaling(50, 100, jump_ip="192.168.1.42")
        self.assert_success(result)
        self.assertEqual(applies, [50, 100])
        self.assertEqual(queries, applies)

    def test_fresh_cluster_defaults_to_stacked_control_plane(self):
        result, applies, _ = self.run_scaling(0, 50)
        self.assert_success(result)
        self.assertIn("Control plane: stacked.", result.stdout)
        self.assertEqual(self.topologies, ["stacked"] * len(applies))

    def test_fresh_cluster_can_use_dedicated_etcd(self):
        result, applies, queries = self.run_scaling(0, 100, control_plane="dedicated-etcd")
        self.assert_success(result)
        self.assertEqual(applies, [0, 50, 100])
        self.assertEqual(queries, applies)
        self.assertEqual(self.topologies, ["dedicated-etcd"] * 3)

    def test_detects_deployed_dedicated_etcd_control_plane(self):
        for roles in (None, DEDICATED_ROLES):
            with self.subTest(roles=roles):
                settings = {} if roles is None else {"roles": roles}
                result, applies, _ = self.run_scaling(50, 100, servers=DEDICATED, **settings)
                self.assert_success(result)
                self.assertIn("Control plane: dedicated-etcd.", result.stdout)
                self.assertEqual(self.topologies, ["dedicated-etcd"] * len(applies))

    def test_refuses_dedicated_etcd_with_two_control_plane_servers(self):
        roles = {n: r for n, r in DEDICATED_ROLES.items() if n != "bench-cp-03"}
        result, applies, _ = self.run_scaling(50, 100, servers=DEDICATED[:-1], roles=roles)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("add-control-plane-server.sh", result.stderr)
        self.assertEqual(applies, [])

    def test_detects_deployed_stacked_control_plane(self):
        result, applies, _ = self.run_scaling(50, 100, servers=STACKED)
        self.assert_success(result)
        self.assertEqual(self.topologies, ["stacked"] * len(applies))

    def test_unready_etcd_node_blocks_scaling(self):
        result, applies, _ = self.run_scaling(50, servers=DEDICATED, not_ready="bench-etcd-02")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(applies, [50])

    def test_refuses_control_plane_that_differs_from_deployed_one(self):
        for servers, requested in ((STACKED, "dedicated-etcd"), (DEDICATED, "stacked")):
            with self.subTest(requested=requested):
                result, applies, _ = self.run_scaling(50, servers=servers, control_plane=requested)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not match the deployed", result.stderr)
                self.assertEqual(applies, [])

    def test_refuses_to_scale_during_control_plane_migration(self):
        midway = (STACKED + [("bench", "bench-etcd-01")], None)
        # Step 6 swapped the bootstrap server before replacing bench-cp-01.
        swapped = (DEDICATED, {**DEDICATED_ROLES, "bench-cp-01": "all"})
        for servers, roles in (midway, swapped):
            with self.subTest(servers=servers):
                settings = {} if roles is None else {"roles": roles}
                result, applies, _ = self.run_scaling(50, servers=servers, **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("migration may be in progress", result.stderr)
                self.assertEqual(applies, [])

    def test_invalid_control_plane_does_not_apply(self):
        result, applies, _ = self.run_scaling(50, control_plane="external")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CONTROL_PLANE must be", result.stderr)
        self.assertEqual(applies, [])

    def test_missing_or_invalid_jump_address_blocks_scaling(self):
        for jump_ip in (None, "", "not-an-ip"):
            with self.subTest(jump_ip=jump_ip):
                result, applies, queries = self.run_scaling(50, jump_ip=jump_ip)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No valid primary IP", result.stderr)
                self.assertEqual(applies, [50])
                self.assertEqual(queries, [])


if __name__ == "__main__":
    unittest.main()
