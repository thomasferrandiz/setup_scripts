import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "kube-burner" / "rebalance.sh"
MOCK = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["MOCK_DIRECTORY"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls").open("a") as calls:
    calls.write(json.dumps([name] + args) + "\n")
if name == "ssh":
    target = next(arg for arg in args if "@" in arg)
    sys.exit(1 if target.endswith("@" + os.environ.get("FAIL_SSH", "none")) else 0)
if args[:3] == ["--request-timeout=30s", "get", "nodes"]:
    print((root / "nodes.json").read_text())
elif args[0].startswith("--server="):
    print("# HELP go_goroutines\ngo_goroutines{x=\"y\"} 1\ngo_goroutines " +
          {"10.0.0.1": "60000", "10.0.0.2": "3000", "10.0.0.3": "45000"}[args[0].split("//")[1].split(":")[0]])
elif args[0] == "wait" and os.environ.get("FAIL_WAIT") == "yes":
    sys.exit(1)
"""


def node(name, address, control_plane=False, ready=True):
    labels = {"node-role.kubernetes.io/control-plane": "true"} if control_plane else {}
    addresses = [{"type": "InternalIP", "address": address}] if address else []
    return {
        "metadata": {"name": name, "labels": labels},
        "status": {
            "addresses": addresses + [{"type": "InternalIP", "address": "fd00::1"}],
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
        },
    }


NODES = [
    node("bench-cp-01", "10.0.0.1", control_plane=True),
    node("bench-cp-02", "10.0.0.2", control_plane=True),
    node("bench-cp-03", "10.0.0.3", control_plane=True),
    node("bench-wk-01", "10.0.1.1"),
    node("bench-wk-02", "10.0.1.2"),
    node("bench-wk-03", "10.0.1.3"),
    node("bench-wk-04", "10.0.1.4", ready=False),
    node("bench-wk-05", None),
    node("bench-wk-06", "10.0.1.6"),
    node("bench-wk-07", "10.0.1.7"),
]


class RebalanceTests(unittest.TestCase):
    def run_script(self, **settings):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "nodes.json").write_text(json.dumps({"items": NODES}))
            for command in ("kubectl", "ssh"):
                (directory / command).write_text(MOCK)
                (directory / command).chmod(0o755)
            env = {
                "PATH": os.pathsep.join([
                    str(directory), os.path.dirname(shutil.which("jq")),
                    os.path.dirname(sys.executable), "/usr/bin", "/bin"]),
                "MOCK_DIRECTORY": temporary,
                **settings,
            }
            result = subprocess.run(["bash", str(SCRIPT)], env=env,
                                    capture_output=True, text=True)
            calls_file = directory / "calls"
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()] \
                if calls_file.exists() else []
            return result, calls

    def test_restarts_cilium_then_agents_in_batches(self):
        result, calls = self.run_script(BATCH_SIZE="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bench-cp-01 60000", result.stdout)
        self.assertIn("bench-cp-02 3000", result.stdout)
        self.assertIn("Skipping bench-wk-04", result.stderr)
        self.assertIn("Skipping bench-wk-05", result.stderr)
        kubectl = [call[1:] for call in calls if call[0] == "kubectl"]
        restart = kubectl.index(["-n", "kube-system", "rollout", "restart", "daemonset/cilium"])
        self.assertEqual(kubectl[restart + 1],
                         ["-n", "kube-system", "rollout", "status", "daemonset/cilium", "--timeout=60m"])
        targets = [call[-6] for call in calls if call[0] == "ssh"]
        self.assertEqual(sorted(targets), [
            "opensuse@10.0.1.1", "opensuse@10.0.1.2", "opensuse@10.0.1.3",
            "opensuse@10.0.1.6", "opensuse@10.0.1.7"])
        for call in calls:
            if call[0] == "ssh":
                self.assertEqual(call[-5:], ["sudo", "-n", "systemctl", "restart", "rke2-agent"])
                self.assertIn("-n", call[1:3])
        waits = [call[3:] for call in kubectl if call[0] == "wait"]
        self.assertEqual(waits, [
            ["node/bench-wk-01", "node/bench-wk-02"],
            ["node/bench-wk-03", "node/bench-wk-06"],
            ["node/bench-wk-07"],
        ])
        self.assertTrue(all(call[1:3] == ["--for=condition=Ready", "--timeout=300s"]
                            for call in kubectl if call[0] == "wait"))
        self.assertIn("5/5 workers restarted", result.stdout)
        self.assertGreater(result.stdout.index("After:"), result.stdout.index("5/5"))

    def test_ssh_failure_stops_before_next_batch(self):
        result, calls = self.run_script(BATCH_SIZE="2", FAIL_SSH="10.0.1.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed to restart rke2-agent on bench-wk-02", result.stderr)
        self.assertEqual(len([call for call in calls if call[0] == "ssh"]), 2)
        self.assertFalse(any(call[:2] == ["kubectl", "wait"] for call in calls))

    def test_not_ready_batch_stops(self):
        result, calls = self.run_script(BATCH_SIZE="2", FAIL_WAIT="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len([call for call in calls if call[0] == "ssh"]), 2)

    def test_can_skip_cilium_or_agents(self):
        result, calls = self.run_script(CILIUM="no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("rollout" in call for call in calls))
        result, calls = self.run_script(AGENTS="no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] == "ssh" for call in calls))
        self.assertTrue(any("rollout" in call for call in calls))

    def test_rejects_invalid_settings(self):
        for settings in ({"CILIUM": "maybe"}, {"AGENTS": "1"}, {"BATCH_SIZE": "0"},
                         {"BATCH_SIZE": "1001"}, {"READY_TIMEOUT": "5m"}):
            result, calls = self.run_script(**settings)
            self.assertNotEqual(result.returncode, 0, settings)
            self.assertEqual(calls, [], settings)


if __name__ == "__main__":
    unittest.main()
