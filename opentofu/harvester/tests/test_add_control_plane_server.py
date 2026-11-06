import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
# The migration test's simulation of OpenTofu, the server VMs, nodes and etcd.
import test_migrate_dedicated_etcd as migration  # noqa: E402


SCRIPT = Path(__file__).resolve().parents[1] / "add-control-plane-server.sh"
LIBRARY = SCRIPT.with_name("control-plane-lib.sh")
THREE = migration.DEDICATED
TWO = {name: role for name, role in THREE.items() if name != "bench-cp-03"}


def two_control_plane_simulation(workers=3, **settings):
    """A cluster migrated by the earlier migrate-to-dedicated-etcd.sh, with bench-cp-01..02."""
    servers = ["bench-etcd-01", "bench-etcd-02", "bench-etcd-03", "bench-cp-01", "bench-cp-02"]
    resources = []
    for name in servers:
        for type_ in ("harvester_virtualmachine", "harvester_cloudinit_secret"):
            address = (f"{type_}.bench_bootstrap" if name == "bench-etcd-01"
                       else f'{type_}.bench_etcd["{name}"]' if TWO[name] == "etcd"
                       else f'{type_}.bench["{name}"]')
            values = {"name": name if type_.endswith("machine") else f"{name}-cloudinit"}
            if not type_.endswith("machine"):
                values["role"] = TWO[name]
            resources.append({"address": address, "type": type_,
                              "name": address.split(".")[1].split("[")[0], "values": values})
    for index in range(1, workers + 1):
        name = f"bench-wk-{index:02d}"
        resources.append({"address": f'harvester_virtualmachine.bench_worker["{name}"]',
                          "type": "harvester_virtualmachine", "name": "bench_worker",
                          "index": name, "values": {"name": name}})
    hosts = {name: {"ip": f"192.168.64.{30 + i}", "role": TWO[name], "rke2": True,
                    "server": None if i == 0 else "192.168.64.30"}
             for i, name in enumerate(servers)}
    etcd_servers = [name for name in servers if TWO[name] == "etcd"]
    return {
        "settings": settings, "resources": resources,
        "outputs": {"rke2_servers": {"bootstrap": "bench-etcd-01", "roles": dict(TWO)}},
        "hosts": hosts,
        "nodes": {name: {"etcd": TWO[name] == "etcd", "cp": TWO[name] != "etcd"} for name in servers},
        "members": [{"id": f"{0x8e9e05c52164694d + i:x}", "node": name, "name": f"{name}-a1b{i}"}
                    for i, name in enumerate(etcd_servers)],
        "applied_roles": dict(TWO), "worker_count": workers,
        "next_ip": 40, "next_member": 0x1000, "haproxy": {}, "log": [], "violations": [],
        "plans": 0, "applies": 0, "sleeps": 0,
    }


class AddControlPlaneServerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        shutil.copy(SCRIPT, self.directory / SCRIPT.name)
        shutil.copy(LIBRARY, self.directory / LIBRARY.name)
        self.key = self.directory / "jump_host.key"
        self.key.write_text("dummy key\n")
        self.key.chmod(0o600)
        (self.directory / "local.yaml").write_text("apiVersion: v1\n")
        for command in ("tofu", "ssh", "sleep", "kubectl"):
            executable = self.directory / command
            executable.write_text(migration.MOCK)
            executable.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    @property
    def sim(self):
        return json.loads((self.directory / "sim.json").read_text())

    def write(self, sim):
        (self.directory / "sim.json").write_text(json.dumps(sim))

    def run_script(self, environment=None, **settings):
        sim = self.sim
        sim["settings"] = settings
        sim["sleeps"] = 0
        self.write(sim)
        environment = {
            **os.environ,
            "PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}",
            "MOCK_DIRECTORY": str(self.directory),
            "EXPECTED_KEY": str(self.key),
            "ASSUME_YES": "yes",
            **(environment or {}),
        }
        return subprocess.run(["bash", str(self.directory / SCRIPT.name)], env=environment,
                              capture_output=True, text=True, timeout=120)

    def assert_added(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        sim = self.sim
        self.assertEqual(sim["violations"], [])
        self.assertEqual(sim["applied_roles"], THREE)
        self.assertEqual(sim["outputs"]["rke2_servers"]["roles"], THREE)
        self.assertEqual({n: h["role"] for n, h in sim["hosts"].items()}, THREE)
        self.assertEqual(sorted(sim["nodes"]), sorted(THREE))
        self.assertEqual(sorted(m["node"] for m in sim["members"]),
                         ["bench-etcd-01", "bench-etcd-02", "bench-etcd-03"])
        self.assertEqual(sim["hosts"]["bench-cp-03"]["server"], sim["hosts"]["bench-etcd-01"]["ip"])
        expected = "".join(f"server {n} {sim['hosts'][n]['ip']}:6443 check\n"
                           for n in ("bench-cp-01", "bench-cp-02", "bench-cp-03"))
        self.assertEqual(sim["haproxy"], {"bench-lb-01": expected, "bench-lb-02": expected})
        workers = [r for r in sim["resources"] if r["name"] == "bench_worker"]
        self.assertEqual(len(workers), sim["worker_count"])
        self.assertIn("rebalance.sh", result.stdout)

    def test_adds_third_control_plane_server_only(self):
        self.write(two_control_plane_simulation())
        result = self.run_script()
        self.assert_added(result)
        sim = self.sim
        self.assertEqual(sim["applies"], 1)
        changes = [line for line in sim["log"] if not line.startswith("push")]
        self.assertEqual(changes, ["create bench-cp-03 control-plane"])

    def test_completed_addition_only_checks(self):
        self.write(two_control_plane_simulation())
        self.assert_added(self.run_script())
        result = self.run_script()
        self.assert_added(result)
        self.assertIn("already has three control-plane servers", result.stdout)
        self.assertEqual(self.sim["applies"], 1)

    def test_resumes_after_failed_apply(self):
        self.write(two_control_plane_simulation())
        result = self.run_script(fail_apply=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sim["outputs"]["rke2_servers"]["roles"], TWO)
        self.assert_added(self.run_script())

    def test_plan_changing_workers_is_not_applied(self):
        self.write(two_control_plane_simulation())
        result = self.run_script(worker_drift=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to apply the addition of bench-cp-03", result.stderr)
        self.assertIn('bench_worker["bench-wk-01"]: update', result.stderr)
        sim = self.sim
        self.assertEqual(sim["applies"], 0)
        self.assertEqual(sim["outputs"]["rke2_servers"]["roles"], TWO)

    def test_unhealthy_cluster_blocks_addition(self):
        sim = two_control_plane_simulation()
        sim["hosts"]["bench-etcd-02"]["rke2"] = False
        self.write(sim)
        result = self.run_script(max_sleeps=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bench-etcd-02 is not Ready", result.stderr)
        self.assertEqual(self.sim["plans"], 0)

    def test_stacked_cluster_points_to_migration(self):
        sim = migration.stacked_simulation()
        sim["outputs"]["rke2_servers"] = {"bootstrap": "bench-cp-01",
                                          "roles": dict(sim["applied_roles"])}
        self.write(sim)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("migrate-to-dedicated-etcd.sh", result.stderr)
        self.assertEqual(self.sim["plans"], 0)

    def test_interrupted_migration_is_refused(self):
        sim = two_control_plane_simulation()
        sim["outputs"]["rke2_servers"]["roles"] = {**THREE, "bench-cp-01": "all"}
        self.write(sim)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Finish an interrupted migration", result.stderr)
        self.assertEqual(self.sim["plans"], 0)

    def test_refuses_workers_with_gaps(self):
        sim = two_control_plane_simulation()
        sim["resources"] = [r for r in sim["resources"] if r.get("index") != "bench-wk-02"]
        self.write(sim)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("finish scaling with scale-workers.sh", result.stderr)
        self.assertEqual(self.sim["plans"], 0)


if __name__ == "__main__":
    unittest.main()
