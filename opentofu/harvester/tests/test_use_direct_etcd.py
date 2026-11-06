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
from test_add_control_plane_server import two_control_plane_simulation  # noqa: E402


SCRIPT = Path(__file__).resolve().parents[1] / "use-direct-etcd.sh"
LIBRARY = SCRIPT.with_name("control-plane-lib.sh")
THREE = migration.DEDICATED
CONTROL_PLANE = ["bench-cp-01", "bench-cp-02", "bench-cp-03"]
LIVE_CONFIG = """write-kubeconfig-mode: "0644"
token: secret

server: https://192.168.64.30:9345

disable-etcd: true
kube-controller-manager-arg:
  - "bind-address=0.0.0.0"
# HAProxy balances TCP connections.
kube-apiserver-arg:
  - "goaway-chance=0.001"
"""


def dedicated_simulation(**settings):
    sim = two_control_plane_simulation(**settings)
    for type_ in ("harvester_virtualmachine", "harvester_cloudinit_secret"):
        values = {"name": "bench-cp-03"} if type_.endswith("machine") else {
            "name": "bench-cp-03-cloudinit", "role": "control-plane"}
        sim["resources"].append({"address": f'{type_}.bench["bench-cp-03"]', "type": type_,
                                 "name": "bench", "values": values})
    sim["hosts"]["bench-cp-03"] = {"ip": "192.168.64.35", "role": "control-plane", "rke2": True,
                                   "server": "192.168.64.30"}
    sim["nodes"]["bench-cp-03"] = {"etcd": False, "cp": True}
    sim["applied_roles"] = dict(THREE)
    sim["outputs"]["rke2_servers"]["roles"] = dict(THREE)
    for name in CONTROL_PLANE:
        sim["hosts"][name]["config"] = LIVE_CONFIG
    return sim


class UseDirectEtcdTest(unittest.TestCase):
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

    def run_script(self, **settings):
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
        }
        return subprocess.run(["bash", str(self.directory / SCRIPT.name)], env=environment,
                              capture_output=True, text=True, timeout=120)

    def expected_servers(self, sim):
        return ",".join(f"https://{sim['hosts'][n]['ip']}:2379"
                        for n in ("bench-etcd-01", "bench-etcd-02", "bench-etcd-03"))

    def assert_direct(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        sim = self.sim
        self.assertEqual(sim["violations"], [])
        servers = self.expected_servers(sim)
        for name in CONTROL_PLANE:
            self.assertEqual(sim["hosts"][name]["etcd_servers"], servers)
            self.assertEqual(sim["hosts"][name]["config"], LIVE_CONFIG.replace(
                'kube-apiserver-arg:\n', f'kube-apiserver-arg:\n  - "etcd-servers={servers}"\n'))
        for name in ("bench-etcd-01", "bench-etcd-02", "bench-etcd-03"):
            self.assertNotIn("config", sim["hosts"][name])
        self.assertIn("rebalance.sh", result.stdout)

    def test_restarts_control_plane_servers_one_at_a_time(self):
        self.write(dedicated_simulation())
        result = self.run_script()
        self.assert_direct(result)
        sim = self.sim
        self.assertEqual(sim["applies"], 1)
        self.assertEqual(sim["log"], [entry for name in CONTROL_PLANE
                                      for entry in (f"configure {name}", f"restart {name}")])

    def test_rerun_only_checks(self):
        self.write(dedicated_simulation())
        self.assert_direct(self.run_script())
        result = self.run_script()
        self.assert_direct(result)
        self.assertEqual(result.stdout.count("already uses the direct etcd servers"), 3)
        self.assertEqual(len(self.sim["log"]), 6)

    def test_replaces_stale_etcd_servers(self):
        sim = dedicated_simulation()
        stale = LIVE_CONFIG.replace('kube-apiserver-arg:\n',
                                    'kube-apiserver-arg:\n  - "etcd-servers=https://10.0.0.1:2379"\n')
        sim["hosts"]["bench-cp-02"]["config"] = stale
        sim["hosts"]["bench-cp-02"]["etcd_servers"] = "https://10.0.0.1:2379"
        self.write(sim)
        self.assert_direct(self.run_script())

    def test_restarts_server_whose_config_was_written(self):
        sim = dedicated_simulation()
        self.write(sim)
        self.assert_direct(self.run_script())
        sim = self.sim
        sim["hosts"]["bench-cp-01"]["etcd_servers"] = None
        sim["log"] = []
        self.write(sim)
        self.assert_direct(self.run_script())
        self.assertEqual(self.sim["log"], ["restart bench-cp-01"])

    def test_refuses_stacked_control_plane(self):
        sim = migration.stacked_simulation()
        sim["outputs"]["rke2_servers"] = {"bootstrap": "bench-cp-01",
                                          "roles": dict(sim["applied_roles"])}
        self.write(sim)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a dedicated-etcd control plane", result.stderr)
        self.assertEqual(self.sim["plans"], 0)

    def test_refuses_etcd_members_other_than_tofu_servers(self):
        sim = dedicated_simulation()
        sim["members"][2]["client_ip"] = "192.168.64.99"
        self.write(sim)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not match the etcd-only servers", result.stderr)
        self.assertIn("https://192.168.64.99:2379", result.stderr)
        self.assertEqual(self.sim["log"], [])

    def test_unhealthy_cluster_blocks_changes(self):
        sim = dedicated_simulation()
        sim["hosts"]["bench-etcd-02"]["rke2"] = False
        self.write(sim)
        result = self.run_script(max_sleeps=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bench-etcd-02 is not Ready", result.stderr)
        self.assertEqual(self.sim["plans"], 0)

    def test_plan_changing_workers_is_not_applied(self):
        self.write(dedicated_simulation())
        result = self.run_script(worker_drift=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to apply the direct etcd servers", result.stderr)
        self.assertEqual(self.sim["log"], [])


if __name__ == "__main__":
    unittest.main()
