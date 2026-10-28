import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "kube-burner" / "defrag-etcd.sh"
MOCK = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["MOCK_DIRECTORY"])
args = sys.argv[1:]
with (root / "calls").open("a") as calls:
    calls.write(json.dumps(args) + "\n")
members = {"etcd-bench-cp-01": "17582389542335462401",
           "etcd-bench-cp-02": "17582389542335462402",
           "etcd-bench-cp-03": "17582389542335462403"}
if "get" in args and "pods" in args:
    print("coredns-1\n" + "\n".join(members) + "\nkube-apiserver-bench-cp-01")
elif "exec" in args:
    pod = args[args.index("exec") + 1]
    if "fields" in args:
        print('"ClusterID" : 1\n"MemberID" : %s\n"Leader" : %s\n"DBSize" : 735051776'
              % (members[pod], members[os.environ.get("LEADER", "etcd-bench-cp-02")]))
    elif "defrag" in args:
        if pod == os.environ.get("FAIL_DEFRAG"):
            sys.exit(1)
        print("Finished defragmenting etcd member[https://127.0.0.1:2379]")
    else:
        print("+---table---+")
"""


class DefragEtcdTests(unittest.TestCase):
    def run_script(self, **settings):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "kubectl").write_text(MOCK)
            (directory / "kubectl").chmod(0o755)
            env = {
                "PATH": os.pathsep.join([str(directory), os.path.dirname(sys.executable),
                                         "/usr/bin", "/bin"]),
                "MOCK_DIRECTORY": temporary,
                **settings,
            }
            result = subprocess.run(["bash", str(SCRIPT)], env=env,
                                    capture_output=True, text=True)
            calls_file = directory / "calls"
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()] \
                if calls_file.exists() else []
            return result, calls

    @staticmethod
    def defragmented(calls):
        return [call[call.index("exec") + 1] for call in calls if "defrag" in call]

    def test_defragments_every_member_leader_last(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.defragmented(calls),
                         ["etcd-bench-cp-01", "etcd-bench-cp-03", "etcd-bench-cp-02"])
        self.assertIn("etcd-bench-cp-02 (leader)", result.stdout)
        for call in calls:
            if "defrag" in call:
                self.assertIn("--command-timeout=120s", call)
                self.assertNotIn("sh", call)
                self.assertIn("--cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt", call)
        tables = [index for index, call in enumerate(calls) if "table" in call]
        defrags = [index for index, call in enumerate(calls) if "defrag" in call]
        self.assertEqual(len(tables), 2)
        self.assertLess(tables[0], defrags[0])
        self.assertGreater(tables[1], defrags[-1])

    def test_leader_detection_and_timeout(self):
        result, calls = self.run_script(LEADER="etcd-bench-cp-01", DEFRAG_TIMEOUT="5m")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.defragmented(calls),
                         ["etcd-bench-cp-02", "etcd-bench-cp-03", "etcd-bench-cp-01"])
        self.assertTrue(all("--command-timeout=5m" in call for call in calls if "defrag" in call))

    def test_failure_stops_before_next_member(self):
        result, calls = self.run_script(FAIL_DEFRAG="etcd-bench-cp-01")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed on etcd-bench-cp-01", result.stderr)
        self.assertEqual(self.defragmented(calls), ["etcd-bench-cp-01"])

    def test_rejects_invalid_timeout(self):
        for timeout in ("0s", "120", "2h", "abc"):
            result, calls = self.run_script(DEFRAG_TIMEOUT=timeout)
            self.assertNotEqual(result.returncode, 0, timeout)
            self.assertEqual(calls, [], timeout)


if __name__ == "__main__":
    unittest.main()
