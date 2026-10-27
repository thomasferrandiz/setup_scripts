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
        "pre_create": os.environ["PRE_CREATE_NAMESPACES"],
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
    if os.environ.get("NO_CONTEXT") == "yes":
        print("error: current-context is not set", file=sys.stderr)
        sys.exit(1)
    print("test-rke2")
elif "top" in args:
    print("NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%")
    print("bench-wk-01 100m 10% 512Mi 25%")
elif "component=etcd" in args:
    if os.environ.get("NO_ETCD") != "yes":
        print("etcd-bench-cp-01\netcd-bench-cp-02")
elif "component=kube-controller-manager" in args:
    if os.environ.get("NO_KCM") != "yes":
        print("kube-controller-manager-bench-cp-01\nkube-controller-manager-bench-cp-02")
elif any(a.endswith(":10257/proxy/metrics") for a in args):
    path = next(a for a in args if a.endswith(":10257/proxy/metrics"))
    if os.environ.get("FAIL_KCM") == "yes" or "/pods/https:kube-controller-manager-" not in path:
        print("Error from server (ServiceUnavailable): connection refused", file=sys.stderr)
        sys.exit(1)
    leader = 1 if "-bench-cp-01:" in path else 0
    limiter = "" if os.environ.get("NO_RATE_LIMITER") == "yes" else '''
rest_client_rate_limiter_duration_seconds_bucket{host="127.0.0.1:6443",verb="PUT",le="0.005"} 10
rest_client_rate_limiter_duration_seconds_bucket{host="127.0.0.1:6443",verb="PUT",le="+Inf"} 30
rest_client_rate_limiter_duration_seconds_bucket{host="127.0.0.1:6443",verb="POST",le="+Inf"} 5
rest_client_rate_limiter_duration_seconds_sum{host="127.0.0.1:6443",verb="PUT"} 12.5
rest_client_rate_limiter_duration_seconds_sum{host="127.0.0.1:6443",verb="POST"} 0.5
rest_client_rate_limiter_duration_seconds_count{host="127.0.0.1:6443",verb="PUT"} 30
rest_client_rate_limiter_duration_seconds_count{host="127.0.0.1:6443",verb="POST"} 5'''
    print(f'''# TYPE rest_client_requests_total counter
rest_client_requests_total{{code="200",host="127.0.0.1:6443",method="PUT"}} 20
rest_client_requests_total{{code="200",host="10.43.0.1:443",method="PUT"}} 3
rest_client_requests_total{{code="409",host="127.0.0.1:6443",method="PUT"}} 7{limiter}
rest_client_request_duration_seconds_sum{{host="127.0.0.1:6443",verb="PUT"}} 0.25
rest_client_request_duration_seconds_count{{host="127.0.0.1:6443",verb="PUT"}} 30
workqueue_depth{{name="deployment"}} 42
workqueue_adds_total{{name="deployment"}} 2000
workqueue_adds_total{{name="replicaset"}} 4000
workqueue_work_duration_seconds_sum{{name="deployment"}} 1
leader_election_master_status{{name="kube-controller-manager"}} {leader}
apiserver_audit_event_total 9
process_cpu_seconds_total 12.5''')
elif "k8s-app=cilium" in args:
    if os.environ.get("NO_CILIUM") != "yes":
        for pod, node in (("cilium-cp", "bench-cp-01"), ("cilium-a", "bench-wk-1"),
                          ("cilium-b", "bench-wk-2"), ("cilium-c", "bench-wk-10"),
                          ("cilium-d", "bench-wk-100")):
            print(f"{pod}\t{node}")
elif any(a.endswith(":9962/proxy/metrics") for a in args):
    if os.environ.get("FAIL_CILIUM") == "yes":
        print("Error from server (ServiceUnavailable): connection refused", file=sys.stderr)
        sys.exit(1)
    print('''# TYPE cilium_endpoint_state gauge
cilium_endpoint_state{endpoint_state="ready"} 3
cilium_endpoint_state{endpoint_state="waiting-for-identity"} 2
cilium_endpoint_regeneration_time_stats_seconds_sum{scope="total",status="success"} 1.5
cilium_endpoint_regeneration_time_stats_seconds_sum{scope="total",status="failure"} 0.5
cilium_endpoint_regeneration_time_stats_seconds_count{scope="total",status="success"} 4
cilium_api_limiter_wait_duration_seconds{api_call="endpoint-create",value="mean"} 2.5
cilium_api_limiter_processed_requests_total{api_call="endpoint-create",outcome="success",return_code="201"} 7
cilium_k8s_client_api_calls_total{endpoint="/api/v1",method="PATCH",return_code="200"} 10
cilium_k8s_client_api_calls_total{endpoint="/apis/cilium.io",method="PATCH",return_code="200"} 5
cilium_k8s_client_api_latency_time_seconds_sum{method="PATCH",path="/api/v1"} 0.75
cilium_bpf_map_ops_total{map_name="x",operation="update",outcome="success"} 99
process_cpu_seconds_total 3''')
elif any(a.startswith("/api/v1/nodes/") and a.endswith("/proxy/metrics") for a in args):
    if os.environ.get("FAIL_KUBELET") == "yes":
        print("Error from server (Forbidden): nodes/proxy", file=sys.stderr)
        sys.exit(1)
    print('''# TYPE kubelet_running_pods gauge
kubelet_running_pods 4
kubelet_run_podsandbox_duration_seconds_sum{runtime_handler=""} 30
kubelet_run_podsandbox_duration_seconds_sum{runtime_handler="runc"} 15
kubelet_run_podsandbox_duration_seconds_count{runtime_handler=""} 3
kubelet_run_podsandbox_duration_seconds_bucket{runtime_handler="",le="10"} 1
kubelet_run_podsandbox_duration_seconds_bucket{runtime_handler="",le="+Inf"} 3
kubelet_runtime_operations_duration_seconds_sum{operation_type="run_podsandbox"} 45
kubelet_runtime_operations_duration_seconds_sum{operation_type="pull_image"} 2
rest_client_requests_total{code="429",host="10.0.0.1:6443",method="PATCH"} 6
rest_client_requests_total{code="429",host="127.0.0.1:6443",method="PATCH"} 1
kubelet_http_requests_total{method="GET",path="metrics"} 8
storage_operation_duration_seconds_count{operation_name="volume_mount"} 5''')
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
    ] + [
        {"metadata": {"name": f"bench-wk-{i}", "labels": {}}, "status": {"addresses": []}}
        for i in (100, 10, 2, 1)
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
                    "PRE_CREATE_NAMESPACES", "KCM_METRICS", "KUBELET_METRICS",
                    "CILIUM_METRICS", "NODE_SAMPLE_COUNT",
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

    def test_samples_kcm_rate_limiter_and_workqueues_per_member(self):
        result, _, files, _ = self.run_workload(WORKLOAD="api-intensive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("kcm-errors.log", files)
        self.assertIn("kcm-metrics.tsv", result.stdout)
        samples = {}
        for line in files["kcm-metrics.tsv"].splitlines():
            _, series, value = line.split("\t")
            samples[series] = float(value)
        m = 'member="bench-cp-01"'
        self.assertEqual(samples[f'rest_client_rate_limiter_duration_seconds_sum{{{m},verb="PUT"}}'], 12.5)
        self.assertEqual(samples[f'rest_client_rate_limiter_duration_seconds_count{{{m},verb="PUT"}}'], 30)
        self.assertEqual(samples[f'rest_client_rate_limiter_duration_seconds_bucket{{{m},le="+Inf"}}'], 35)
        self.assertEqual(samples[f'rest_client_requests_total{{{m},method="PUT",code="200"}}'], 23)
        self.assertEqual(samples[f'rest_client_requests_total{{{m},method="PUT",code="409"}}'], 7)
        self.assertEqual(samples[f'rest_client_request_duration_seconds_sum{{{m},verb="PUT"}}'], 0.25)
        self.assertEqual(samples[f'workqueue_depth{{{m},name="deployment"}}'], 42)
        self.assertEqual(samples[f'workqueue_adds_total{{{m},name="replicaset"}}'], 4000)
        self.assertEqual(samples[f'leader_election_master_status{{{m}}}'], 1)
        self.assertEqual(samples['leader_election_master_status{member="bench-cp-02"}'], 0)
        self.assertEqual(samples[f'process_cpu_seconds_total{{{m}}}'], 12.5)
        self.assertFalse(any(s.startswith(("apiserver_", "workqueue_work_")) for s in samples))
        self.assertIn("KCM_METRICS=auto", files["parameters.env"])

    def test_kcm_metrics_unavailable(self):
        for settings in ({"FAIL_KCM": "yes"}, {"NO_KCM": "yes"}):
            with self.subTest(settings=settings):
                result, started, files, _ = self.run_workload(**settings)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(started)
                self.assertNotIn("kcm-metrics.tsv", files)
                self.assertIn("kube-controller-manager metrics unavailable", result.stderr)
                result, started, _, _ = self.run_workload(KCM_METRICS="required", **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(started)
                self.assertIn("authorization-always-allow-paths", result.stderr)

    def test_kcm_without_rate_limiter_metric_warns(self):
        result, started, files, _ = self.run_workload(NO_RATE_LIMITER="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(started)
        self.assertIn("kcm-metrics.tsv", files)
        self.assertIn("no rest_client_rate_limiter_duration_seconds", result.stderr)

    def test_kcm_metrics_off(self):
        result, _, files, _ = self.run_workload(KCM_METRICS="off", FAIL_KCM="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("kcm-metrics.tsv", files)
        self.assertNotIn("kube-controller-manager", result.stderr)

    @staticmethod
    def samples(text):
        samples = {}
        for line in text.splitlines():
            _, series, value = line.split("\t")
            samples[series] = float(value)
        return samples

    def test_samples_kubelet_and_cilium_on_sampled_workers(self):
        result, _, files, _ = self.run_workload(WORKLOAD="api-intensive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files["sampled-nodes.txt"].splitlines(),
                         ["bench-wk-1", "bench-wk-2", "bench-wk-10", "bench-wk-100"])
        self.assertNotIn("kubelet-errors.log", files)
        self.assertNotIn("cilium-errors.log", files)
        self.assertIn("kubelet-metrics.tsv", result.stdout)
        self.assertIn("cilium-metrics.tsv", result.stdout)
        parameters = files["parameters.env"]
        for setting in ("KUBELET_METRICS=auto", "CILIUM_METRICS=auto", "NODE_SAMPLE_COUNT=5"):
            self.assertIn(setting, parameters)

        kubelet = self.samples(files["kubelet-metrics.tsv"])
        m = 'member="bench-wk-10"'
        self.assertEqual(kubelet[f'kubelet_running_pods{{{m}}}'], 4)
        self.assertEqual(kubelet[f'kubelet_run_podsandbox_duration_seconds_sum{{{m}}}'], 45)
        self.assertEqual(kubelet[f'kubelet_run_podsandbox_duration_seconds_count{{{m}}}'], 3)
        self.assertEqual(kubelet[f'kubelet_run_podsandbox_duration_seconds_bucket{{{m},le="10"}}'], 1)
        self.assertEqual(kubelet[
            f'kubelet_runtime_operations_duration_seconds_sum{{{m},operation_type="run_podsandbox"}}'], 45)
        self.assertEqual(kubelet[f'rest_client_requests_total{{{m},method="PATCH",code="429"}}'], 7)
        self.assertFalse(any(s.startswith(("kubelet_http_", "storage_")) for s in kubelet))
        self.assertNotIn('kubelet_running_pods{member="bench-cp-01"}', kubelet)

        cilium = self.samples(files["cilium-metrics.tsv"])
        m = 'member="bench-wk-100"'
        self.assertEqual(cilium[f'cilium_endpoint_state{{{m},endpoint_state="waiting-for-identity"}}'], 2)
        self.assertEqual(cilium[
            f'cilium_endpoint_regeneration_time_stats_seconds_sum{{{m},scope="total"}}'], 2)
        self.assertEqual(cilium[
            f'cilium_api_limiter_wait_duration_seconds{{{m},api_call="endpoint-create",value="mean"}}'], 2.5)
        self.assertEqual(cilium[
            f'cilium_api_limiter_processed_requests_total{{{m},api_call="endpoint-create",outcome="success"}}'], 7)
        self.assertEqual(cilium[f'cilium_k8s_client_api_calls_total{{{m},method="PATCH",return_code="200"}}'], 15)
        self.assertEqual(cilium[f'cilium_k8s_client_api_latency_time_seconds_sum{{{m},method="PATCH"}}'], 0.75)
        self.assertEqual(cilium[f'process_cpu_seconds_total{{{m}}}'], 3)
        self.assertFalse(any(s.startswith("cilium_bpf_") for s in cilium))
        self.assertFalse(any('member="bench-cp-01"' in s for s in cilium))

    def test_node_sample_count_spreads_workers_in_natural_order(self):
        result, _, files, _ = self.run_workload(NODE_SAMPLE_COUNT="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files["sampled-nodes.txt"].splitlines(), ["bench-wk-1", "bench-wk-10"])
        for name in ("kubelet-metrics.tsv", "cilium-metrics.tsv"):
            members = {line.split("\t")[1].split('member="')[1].split('"')[0]
                       for line in files[name].splitlines()}
            self.assertEqual(members, {"bench-wk-1", "bench-wk-10"}, name)

    def test_node_metrics_unavailable(self):
        for settings, mode, file, hint in (
            ({"FAIL_KUBELET": "yes"}, "KUBELET_METRICS", "kubelet-metrics.tsv", "nodes/proxy"),
            ({"FAIL_CILIUM": "yes"}, "CILIUM_METRICS", "cilium-metrics.tsv", "prometheus.enabled"),
            ({"NO_CILIUM": "yes"}, "CILIUM_METRICS", "cilium-metrics.tsv", "prometheus.enabled"),
        ):
            with self.subTest(settings=settings):
                result, started, files, _ = self.run_workload(**settings)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNotNone(started)
                self.assertNotIn(file, files)
                self.assertIn("metrics unavailable", result.stderr)
                result, started, _, _ = self.run_workload(**{mode: "required"}, **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(started)
                self.assertIn(hint, result.stderr)

    def test_node_metrics_off(self):
        result, _, files, _ = self.run_workload(
            KUBELET_METRICS="off", CILIUM_METRICS="off", FAIL_KUBELET="yes", FAIL_CILIUM="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("sampled-nodes.txt", "kubelet-metrics.tsv", "cilium-metrics.tsv"):
            self.assertNotIn(name, files)
        self.assertNotIn("kubelet", result.stderr)
        self.assertNotIn("cilium", result.stderr)

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

    def test_records_effective_parameters(self):
        result, _, files, _ = self.run_workload(
            WORKLOAD="api-intensive", ITERATIONS="2000", QPS="200", TIMEOUT="4h",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        parameters = dict(
            line.split("=", 1) for line in files["parameters.env"].splitlines()
        )
        self.assertEqual(parameters["WORKLOAD"], "api-intensive")
        self.assertEqual(parameters["ITERATIONS"], "2000")
        self.assertEqual((parameters["QPS"], parameters["BURST"]), ("200", "200"))
        self.assertEqual(parameters["HOLD_DURATION"], "1m")
        self.assertEqual(
            (parameters["READ_ITERATIONS"], parameters["PATCH_ITERATIONS"]), ("5", "3"))
        self.assertEqual(parameters["PRE_CREATE_NAMESPACES"], "true")
        self.assertEqual(parameters["TIMEOUT"], "4h")
        self.assertEqual(parameters["SAMPLE_INTERVAL"], "1")
        self.assertEqual(parameters["ETCD_METRICS"], "auto")
        self.assertRegex(parameters["STARTED"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertIn("CONTEXT", parameters)

    def test_pre_create_namespaces_can_be_disabled(self):
        result, started, files, _ = self.run_workload(
            WORKLOAD="api-intensive", PRE_CREATE_NAMESPACES="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(started["pre_create"], "false")
        self.assertIn("PRE_CREATE_NAMESPACES=false", files["parameters.env"])

    def test_missing_current_context_does_not_stop_the_run(self):
        result, started, files, _ = self.run_workload(NO_CONTEXT="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(started)
        self.assertIn("CONTEXT=(not set)", files["parameters.env"])

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
            {"PRE_CREATE_NAMESPACES": "yes"}, {"KCM_METRICS": "yes"},
            {"KUBELET_METRICS": "yes"}, {"CILIUM_METRICS": "yes"},
            {"NODE_SAMPLE_COUNT": "0"}, {"NODE_SAMPLE_COUNT": "101"},
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
