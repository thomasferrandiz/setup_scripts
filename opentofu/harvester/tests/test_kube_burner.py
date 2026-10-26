import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


WORKLOAD = Path(__file__).resolve().parents[1] / "kube-burner"
MOCK = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import sys
import time

root = Path(os.environ["MOCK_DIRECTORY"])
if Path(sys.argv[0]).name == "kube-burner":
    (root / "started").write_text(json.dumps({
        "iterations": os.environ["ITERATIONS"],
        "hold": os.environ["HOLD_DURATION"],
        "qps": os.environ["QPS"],
        "burst": os.environ["BURST"],
        "read": os.environ["READ_ITERATIONS"],
        "patch": os.environ["PATCH_ITERATIONS"],
        "args": sys.argv[1:],
    }))
    def stop(signum, frame):
        (root / "stopped").touch()
        sys.exit(143)
    signal.signal(signal.SIGTERM, stop)
    if os.environ.get("LOG_ERROR") == "yes":
        print('time="2026-10-22 12:00:00" level=error msg="Error patching object"', flush=True)
    time.sleep(5 if os.environ.get("FAIL_DURING_RUN") == "yes" else 0.3)
    sys.exit(int(os.environ.get("BURNER_STATUS", "0")))
args = sys.argv[1:]
if args == ["config", "current-context"]:
    print("test-rke2")
elif "top" in args:
    print("NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%")
    print("bench-wk-01 100m 10% 512Mi 25%")
elif "component=etcd" in args:
    if os.environ.get("NO_ETCD") != "yes":
        print("etcd-bench-cp-01\netcd-bench-cp-02")
elif any(a.endswith(":2381/proxy/metrics") for a in args):
    if os.environ.get("FAIL_ETCD") == "yes":
        print("Error from server (ServiceUnavailable): connection refused", file=sys.stderr)
        sys.exit(1)
    leader = 1 if "etcd-bench-cp-01:" in " ".join(args) else 0
    print(f'''# TYPE etcd_server_has_leader gauge
etcd_server_has_leader 1
etcd_server_is_leader {leader}
etcd_server_proposals_committed_total 1234
etcd_mvcc_db_total_size_in_bytes 2.097152e+08
etcd_disk_wal_fsync_duration_seconds_bucket{{le="0.008"}} 90
etcd_disk_wal_fsync_duration_seconds_bucket{{le="+Inf"}} 100
etcd_disk_wal_fsync_duration_seconds_sum 0.5
etcd_disk_wal_fsync_duration_seconds_count 100
etcd_network_peer_round_trip_time_seconds_sum{{To="a"}} 0.25
etcd_network_peer_round_trip_time_seconds_sum{{To="b"}} 0.5
grpc_server_handled_total{{grpc_code="OK",grpc_method="Range"}} 5
process_resident_memory_bytes 5.24288e+08''')
elif "/metrics" in args:
    if not any(arg in ("--server=https://192.168.64.10:6443",
                       "--server=https://192.168.64.11:6443") for arg in args):
        sys.exit("API metrics must bypass the load balancer")
    if os.environ.get("FAIL_APISERVER_METRICS") == "yes":
        print("forbidden", file=sys.stderr)
        sys.exit(1)
    print('''# HELP apiserver_request_total Counter
# TYPE apiserver_request_total counter
apiserver_request_total{code="200",component="apiserver",resource="pods",verb="LIST"} 1500000
apiserver_request_total{code="200",component="apiserver",resource="secrets",verb="LIST"} 2
apiserver_request_total{code="201",component="apiserver",resource="pods",verb="POST"} 3
apiserver_request_total{code="429",component="apiserver",resource="pods",verb="POST"} 4
apiserver_request_duration_seconds_sum{component="apiserver",resource="pods",verb="LIST"} 1.5
apiserver_request_duration_seconds_sum{component="apiserver",resource="secrets",verb="LIST"} 0.25
apiserver_request_duration_seconds_count{component="apiserver",resource="pods",verb="LIST"} 10
apiserver_request_duration_seconds_bucket{component="apiserver",resource="pods",verb="LIST",le="1"} 10
apiserver_current_inflight_requests{request_kind="mutating"} 7
apiserver_flowcontrol_rejected_requests_total{flow_schema="global-default",priority_level="global-default",reason="queue-full"} 2
process_resident_memory_bytes 1.073741824e+09
etcd_request_duration_seconds_count{operation="get",type="pods"} 99
etcd_request_duration_seconds_count{operation="get",type="secrets"} 1
etcd_request_duration_seconds_sum{operation="get",type="pods"} 0.75
apiserver_storage_size_bytes{storage_cluster_id="x"} 1.048576e+08
apiserver_storage_objects{resource="pods"} 2000
apiserver_storage_objects{resource="secrets"} 3''')
elif "--raw" in args:
    if os.environ.get("FAIL_METRICS") == "yes":
        print("Metrics API unavailable", file=sys.stderr)
        sys.exit(1)
    if os.environ.get("FAIL_DURING_RUN") == "yes" and (root / "started").exists():
        time.sleep(0.1)
        print("Metrics API failed during run", file=sys.stderr)
        sys.exit(1)
    items = [] if os.environ.get("EMPTY_METRICS") else [{
        "metadata": {"name": "bench-wk-01"},
        "timestamp": "2026-10-21T12:00:00Z",
        "window": "30s",
        "usage": {"cpu": "100000000n", "memory": "512Mi"},
    }]
    print(json.dumps({"items": items}, indent=2))
elif "nodes" in args and "json" in args:
    print(json.dumps({"items": [] if os.environ.get("NO_CONTROL_PLANE") == "yes" else [
        {"metadata": {"name": f"bench-cp-0{i}", "labels": {
            "node-role.kubernetes.io/control-plane": "true",
        }}, "status": {"addresses": [
            {"type": "InternalIP", "address": f"192.168.64.{9+i}"},
        ]}}
        for i in (1, 2)
    ]}))
else:
    print('{"items": []}')
"""


@unittest.skipUnless(shutil.which("jq"), "jq is required")
class KubeBurnerTests(unittest.TestCase):
    def run_workload(self, **settings):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(WORKLOAD, root / "workload", ignore=shutil.ignore_patterns("results-*"))
            for name in ("kubectl", "kube-burner"):
                path = root / name
                path.write_text(MOCK)
                path.chmod(0o755)
            environment = {
                key: value for key, value in os.environ.items()
                if key not in {
                    "WORKLOAD", "ITERATIONS", "HOLD_DURATION", "QPS", "BURST",
                    "READ_ITERATIONS", "PATCH_ITERATIONS", "TIMEOUT", "ETCD_METRICS",
                }
            }
            environment.update({
                "PATH": f"{root}:{os.environ['PATH']}",
                "MOCK_DIRECTORY": str(root),
                "KUBECONFIG": "/test/rke2.yaml",
                "SAMPLE_INTERVAL": "1",
                **settings,
            })
            result = subprocess.run(
                ["bash", str(root / "workload/run.sh")],
                env=environment, capture_output=True, text=True, timeout=10,
            )
            started = root / "started"
            results = list((root / "workload").glob("results-*"))
            files = {
                p.name: p.read_text() for directory in results for p in directory.iterdir()
            }
            return result, json.loads(started.read_text()) if started.exists() else None, files, (root / "stopped").exists()

    def test_success_records_cpu_memory_and_default_settings(self):
        result, started, files, _ = self.run_workload()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(started["iterations"], "10")
        self.assertEqual(started["hold"], "10m")
        self.assertEqual((started["qps"], started["burst"]), ("10", "10"))
        self.assertEqual(started["args"][:3], ["init", "-c", "kubelet-density-heavy.yml"])
        self.assertIn("--timeout=2h", started["args"])
        self.assertIn("--skip-log-file", started["args"])
        self.assertIn("100m", files["node-usage.txt"])
        self.assertIn("512Mi", files["node-usage.txt"])
        for line in files["node-metrics.jsonl"].splitlines():
            self.assertEqual(json.loads(line)["items"][0]["usage"]["memory"], "512Mi")
        self.assertIn("after.txt", files)

    def test_api_intensive_defaults_and_apiserver_metrics(self):
        result, started, files, _ = self.run_workload(WORKLOAD="api-intensive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(started["args"][:3], ["init", "-c", "api-intensive.yml"])
        self.assertEqual(
            (started["iterations"], started["hold"], started["qps"], started["burst"],
             started["read"], started["patch"]),
            ("100", "1m", "50", "50", "5", "3"),
        )
        samples = {}
        for line in files["apiserver-metrics.tsv"].splitlines():
            _, series, value = line.split("\t")
            series = series.replace('member="bench-cp-01",', '').replace(
                '{member="bench-cp-01"}', '')
            samples[series] = float(value)
        self.assertEqual(samples['apiserver_request_total{verb="LIST",code="200"}'], 1500002)
        self.assertEqual(samples['apiserver_request_total{verb="POST",code="429"}'], 4)
        self.assertEqual(samples['apiserver_request_duration_seconds_sum{verb="LIST"}'], 1.75)
        self.assertEqual(samples['apiserver_request_duration_seconds_count{verb="LIST"}'], 10)
        self.assertEqual(samples['apiserver_current_inflight_requests{request_kind="mutating"}'], 7)
        self.assertEqual(samples["process_resident_memory_bytes"], 1073741824)
        self.assertEqual(samples['etcd_request_duration_seconds_count{operation="get"}'], 100)
        self.assertEqual(samples['etcd_request_duration_seconds_sum{operation="get"}'], 0.75)
        self.assertEqual(samples["apiserver_storage_objects"], 2003)
        self.assertEqual(samples["apiserver_storage_size_bytes"], 104857600)
        self.assertFalse(any("bucket" in s for s in samples))

    def test_samples_etcd_server_metrics_per_member(self):
        result, _, files, _ = self.run_workload()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("etcd-errors.log", files)
        samples = {}
        for line in files["etcd-metrics.tsv"].splitlines():
            _, series, value = line.split("\t")
            samples[series] = float(value)
        self.assertEqual(samples['etcd_server_is_leader{member="bench-cp-01"}'], 1)
        self.assertEqual(samples['etcd_server_is_leader{member="bench-cp-02"}'], 0)
        self.assertEqual(samples['etcd_mvcc_db_total_size_in_bytes{member="bench-cp-02"}'], 209715200)
        self.assertEqual(
            samples['etcd_disk_wal_fsync_duration_seconds_bucket{member="bench-cp-01",le="+Inf"}'], 100)
        self.assertEqual(samples['etcd_network_peer_round_trip_time_seconds_sum{member="bench-cp-01"}'], 0.75)
        self.assertFalse(any(s.startswith("grpc_") for s in samples))
        self.assertIn("etcd-metrics.tsv", result.stdout)

    def test_etcd_metrics_unavailable(self):
        for settings in ({"FAIL_ETCD": "yes"}, {"NO_ETCD": "yes"}):
            with self.subTest(settings=settings):
                result, started, files, _ = self.run_workload(**settings)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(started)
                self.assertNotIn("etcd-metrics.tsv", files)
                self.assertIn("etcd server metrics unavailable", result.stderr)
                result, started, _, _ = self.run_workload(ETCD_METRICS="required", **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(started)
                self.assertIn("etcd-expose-metrics", result.stderr)

    def test_etcd_metrics_off(self):
        result, _, files, _ = self.run_workload(ETCD_METRICS="off", FAIL_ETCD="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("etcd-metrics.tsv", files)
        self.assertNotIn("etcd", result.stderr)

    def test_api_intensive_accepts_explicit_settings(self):
        result, started, _, _ = self.run_workload(
            WORKLOAD="api-intensive", ITERATIONS="5000", QPS="200", BURST="400",
            READ_ITERATIONS="10", PATCH_ITERATIONS="1", TIMEOUT="4h",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (started["iterations"], started["qps"], started["burst"], started["read"], started["patch"]),
            ("5000", "200", "400", "10", "1"),
        )
        self.assertIn("--timeout=4h", started["args"])

    def test_apiserver_metrics_failure_prevents_start(self):
        result, started, _, _ = self.run_workload(WORKLOAD="api-intensive", FAIL_APISERVER_METRICS="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(started)
        self.assertIn("API server metrics unavailable", result.stderr)

    def test_apiserver_metrics_are_separated_by_member(self):
        result, _, files, _ = self.run_workload()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files["apiserver-targets.tsv"].splitlines(), [
            "bench-cp-01\thttps://192.168.64.10:6443",
            "bench-cp-02\thttps://192.168.64.11:6443",
        ])
        series = {line.split("\t")[1] for line in files["apiserver-metrics.tsv"].splitlines()}
        for member in ("bench-cp-01", "bench-cp-02"):
            self.assertIn(f'process_resident_memory_bytes{{member="{member}"}}', series)
            self.assertIn(
                f'apiserver_request_total{{member="{member}",verb="LIST",code="200"}}',
                series,
            )

    def test_missing_control_plane_prevents_start(self):
        result, started, _, _ = self.run_workload(NO_CONTROL_PLANE="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(started)
        self.assertIn("Cannot discover API server metrics targets", result.stderr)

    def test_logged_errors_fail_the_run(self):
        result, started, _, _ = self.run_workload(WORKLOAD="api-intensive", LOG_ERROR="yes")
        self.assertEqual(result.returncode, 3)
        self.assertIsNotNone(started)
        self.assertIn("logged 1 error(s)", result.stderr)

    def test_accepts_one_thousand_iterations(self):
        result, started, _, _ = self.run_workload(ITERATIONS="1000", HOLD_DURATION="20m")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(started["iterations"], "1000")
        self.assertEqual(started["hold"], "20m")

    def test_rejects_invalid_settings_before_start(self):
        for settings in (
            {"ITERATIONS": "1001"}, {"ITERATIONS": "0"}, {"ITERATIONS": "010"},
            {"ITERATIONS": "1.5"}, {"HOLD_DURATION": "0m"},
            {"SAMPLE_INTERVAL": "0"}, {"KUBECONFIG": ""},
            {"WORKLOAD": "other"}, {"WORKLOAD": "api-intensive", "ITERATIONS": "5001"},
            {"QPS": "0"}, {"QPS": "1001"}, {"BURST": "x"}, {"READ_ITERATIONS": "101"},
            {"PATCH_ITERATIONS": "0"}, {"TIMEOUT": "2"}, {"ETCD_METRICS": "yes"},
        ):
            with self.subTest(settings=settings):
                result, started, _, _ = self.run_workload(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(started)

    def test_metrics_failure_prevents_start(self):
        for settings in ({"FAIL_METRICS": "yes"}, {"EMPTY_METRICS": "yes"}):
            with self.subTest(settings=settings):
                result, started, _, _ = self.run_workload(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(started)
                self.assertIn("metrics unavailable or empty", result.stderr)

    def test_burner_failure_is_propagated(self):
        result, _, _, _ = self.run_workload(BURNER_STATUS="7")
        self.assertEqual(result.returncode, 7)
        self.assertIn("remaining namespaces may need cleanup", result.stderr)

    def test_monitoring_failure_stops_burner(self):
        result, started, _, stopped = self.run_workload(FAIL_DURING_RUN="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNotNone(started)
        self.assertTrue(stopped)
        self.assertIn("clean up remaining workload namespaces", result.stderr)


if __name__ == "__main__":
    unittest.main()
