import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "migrate-to-dedicated-etcd.sh"
DEDICATED = {"bench-cp-01": "control-plane", "bench-cp-02": "control-plane",
             "bench-etcd-01": "etcd", "bench-etcd-02": "etcd", "bench-etcd-03": "etcd"}

# Simulates OpenTofu state and plans, the server VMs, Kubernetes nodes and etcd
# members. Every disruptive action checks that etcd keeps quorum, that two API
# servers stay up and that no VM is deleted while it is still a node or member.
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import shlex
import sys

directory = Path(os.environ["MOCK_DIRECTORY"])
sim_file = directory / "sim.json"
sim = json.loads(sim_file.read_text())
settings = sim["settings"]
command = Path(sys.argv[0]).name
args = sys.argv[1:]
TYPES = ("harvester_virtualmachine", "harvester_cloudinit_secret")
DEDICATED = {"bench-cp-01": "control-plane", "bench-cp-02": "control-plane",
             "bench-etcd-01": "etcd", "bench-etcd-02": "etcd", "bench-etcd-03": "etcd"}


VIP = "192.168.64.253"
LBS = {"bench-lb-01": "192.168.66.55", "bench-lb-02": "192.168.66.21"}


def save():
    sim_file.write_text(json.dumps(sim, indent=1))


def fail(message):
    print(message, file=sys.stderr)
    save()
    sys.exit(1)


def log(message):
    sim["log"].append(message)


def check_invariants(context):
    hosts = sim["hosts"]
    up = [m for m in sim["members"] if hosts.get(m["node"], {}).get("rke2")]
    if len(up) * 2 <= len(sim["members"]):
        sim["violations"].append(f"{context}: etcd lost quorum")
    apis = [n for n, h in hosts.items() if h["rke2"] and h["role"] != "etcd"]
    if len(apis) < 2:
        sim["violations"].append(f"{context}: only {apis} serve the API")


def address(type_, name, bootstrap):
    return f"{type_}.bench_bootstrap" if name == bootstrap else f'{type_}.bench["{name}"]'


def server_resources():
    return [r for r in sim["resources"] if r["type"] in TYPES and r["name"] in ("bench", "bench_bootstrap")]


def vm_name(resource):
    return resource["values"]["name"].removesuffix("-cloudinit")


def state_json():
    resources = []
    for r in sim["resources"]:
        item = {"address": r["address"], "mode": "managed", "type": r["type"],
                "name": r["name"], "values": r["values"]}
        if "index" in r:
            item["index"] = r["index"]
        resources.append(item)
    return {"values": {"root_module": {"resources": resources}}}


def haproxy_config():
    return "".join(f"server {n} {sim['hosts'][n]['ip']}:6443 check\n"
                   for n in sorted(sim["applied_roles"]) if sim["applied_roles"][n] != "etcd")


def new_host(name, role, server):
    sim["next_ip"] += 1
    sim["hosts"][name] = {"ip": f"192.168.64.{sim['next_ip']}", "role": role,
                          "rke2": True, "server": server}
    sim["nodes"][name] = {"etcd": role != "control-plane", "cp": role != "etcd"}
    if role != "control-plane":
        sim["next_member"] += 1
        sim["members"].append({"id": f"{sim['next_member']:x}", "node": name,
                               "name": f"{name}-{sim['next_member'] % 0xffff:04x}"})


def plan(args):
    variables = dict(a[len("-var="):].split("=", 1) for a in args if a.startswith("-var="))
    replace = [a[len("-replace="):] for a in args if a.startswith("-replace=")]
    targets = [a[len("-target="):] for a in args if a.startswith("-target=")]
    out = next(a[len("-out="):] for a in args if a.startswith("-out="))
    if "-concise" not in args or variables.get("rke2_control_plane") != "dedicated-etcd":
        fail(f"Unexpected plan arguments: {args}")
    if "rke2_server_roles" in variables:
        roles = dict(re.findall(r'"([^"]+)"="([^"]+)"', variables["rke2_server_roles"]))
    else:
        roles = DEDICATED
    bootstrap = "bench-cp-01" if roles.get("bench-cp-01") == "all" else "bench-etcd-01"
    current = {r["address"]: r for r in server_resources()}
    desired = {address(t, n, bootstrap): (t, n) for n in roles for t in TYPES}
    changes = []
    for addr, r in current.items():
        if addr not in desired or desired[addr][1] != vm_name(r):
            changes.append({"address": addr, "actions": ["delete"], "type": r["type"],
                            "name": r["name"], "before": vm_name(r)})
    for addr, (type_, name) in desired.items():
        resource = "bench_bootstrap" if name == bootstrap else "bench"
        if addr not in current:
            changes.append({"address": addr, "actions": ["create"], "type": type_,
                            "name": resource, "after": name})
        elif addr in replace:
            changes.append({"address": addr, "actions": ["delete", "create"], "type": type_,
                            "name": resource, "before": name, "after": name})
        elif type_ == TYPES[1] and current[addr]["values"]["role"] != roles[name]:
            changes.append({"address": addr, "actions": ["update"], "type": type_,
                            "name": resource, "before": name, "after": name})
    if int(variables["rke2_worker_count"]) != sim["worker_count"]:
        fail("Plan with a different worker count")
    # The provider reports a cloudinitdisk disk block missing from the configuration on every VM.
    for addr, name in ((f'{TYPES[0]}.bench_worker["bench-wk-{i:02d}"]', f"bench-wk-{i:02d}")
                       for i in range(1, sim["worker_count"] + 1)):
        changes.append({"address": addr, "actions": ["update"], "type": TYPES[0],
                        "name": "bench_worker", "before": name, "after": name})
    for addr, name in ((f'{TYPES[0]}.bench_lb["bench-lb-01"]', "bench-lb-01"),
                       (f"{TYPES[0]}.bench_dual_network", "bench-net-01")):
        changes.append({"address": addr, "actions": ["update"], "type": TYPES[0],
                        "name": addr.split(".")[1].split("[")[0], "before": name, "after": name})
    if targets:
        changes = [c for c in changes if c["address"].split("[")[0] in targets]
    if settings.get("worker_drift"):
        changes.append({"address": 'harvester_virtualmachine.bench_worker["bench-wk-01"]',
                        "actions": ["update"], "type": TYPES[0], "name": "bench_worker",
                        "before": "bench-wk-01", "after": "bench-wk-01"})
    Path(out).write_text(json.dumps({"roles": roles, "bootstrap": bootstrap, "changes": changes}))
    sim["plans"] += 1


def show_plan(path):
    saved = json.loads(Path(path).read_text())
    print(json.dumps({"resource_changes": [{
        "address": c["address"], "mode": "managed", "type": c["type"], "name": c["name"],
        "change": {"actions": c["actions"],
                   "before": {"name": c["before"]} if "before" in c else None,
                   "after": {"name": c["after"]} if "after" in c else None},
    } for c in saved["changes"]] + [{
        "address": 'harvester_virtualmachine.bench_worker["bench-wk-02"]', "mode": "managed",
        "type": TYPES[0], "name": "bench_worker",
        "change": {"actions": ["no-op"], "before": {"name": "bench-wk-02"}, "after": {"name": "bench-wk-02"}},
    }]}))


def apply(path):
    sim["applies"] += 1
    if sim["applies"] == settings.get("fail_apply"):
        fail("Mock apply failure")
    saved = json.loads(Path(path).read_text())
    roles, bootstrap = saved["roles"], saved["bootstrap"]
    resources = {r["address"]: r for r in sim["resources"]}
    for change in saved["changes"]:
        addr, actions = change["address"], change["actions"]
        if "delete" in actions:
            name = change["before"]
            del resources[addr]
            if change["type"] == TYPES[0]:
                if name in sim["nodes"] or any(m["node"] == name for m in sim["members"]):
                    sim["violations"].append(f"deleted VM {name} while it is in the cluster")
                del sim["hosts"][name]
                check_invariants(f"deleting {name}")
                log(f"delete {name}")
        if "create" in actions:
            name = change["after"]
            values = {"name": name if change["type"] == TYPES[0] else f"{name}-cloudinit"}
            if change["type"] == TYPES[1]:
                values["role"] = roles[name]
            resources[addr] = {"address": addr, "type": change["type"], "name": change["name"],
                               "values": values}
            if change["type"] == TYPES[0]:
                if name in sim["nodes"]:
                    sim["violations"].append(f"created {name} while its node exists")
                server = None if name == bootstrap else sim["hosts"][bootstrap]["ip"]
                if roles[name] == "control-plane" and sim["hosts"][bootstrap]["role"] == "control-plane":
                    sim["violations"].append(f"{name} joins a server without etcd")
                new_host(name, roles[name], server)
                log(f"create {name} {roles[name]}")
        if actions == ["update"] and change["type"] == TYPES[1]:
            resources[addr]["values"]["role"] = roles[change["after"]]
        elif actions == ["update"] and change["name"] != "bench" and change["name"] != "bench_bootstrap":
            sim["violations"].append(f"updated {addr}")
    sim["resources"] = list(resources.values())
    sim["applied_roles"] = roles
    sim["outputs"]["rke2_servers"] = {"bootstrap": bootstrap, "roles": roles}


def tofu():
    if args == ["show", "-json"]:
        print(json.dumps(state_json()))
    elif args[:2] == ["show", "-json"]:
        show_plan(args[2])
    elif args == ["output", "-json", "virtual_machines"]:
        vms = {n: {"ip_address": h["ip"]} for n, h in sim["hosts"].items()}
        vms.update({"bench-net-01": {"ip_address": "192.168.1.20"},
                    # As on Harvester: the active load balancer reports the VIP, and
                    # the other one no address, as they do not wait for a lease.
                    "bench-lb-01": {"ip_address": VIP},
                    "bench-lb-02": {"ip_address": ""}})
        print(json.dumps(vms))
    elif args == ["output", "-json", "rke2_servers"]:
        if "rke2_servers" not in sim["outputs"]:
            fail("Output not found")
        print(json.dumps(sim["outputs"]["rke2_servers"]))
    elif args == ["output", "-raw", "haproxy_config"]:
        sys.stdout.write(haproxy_config())
    elif args[:2] == ["state", "mv"]:
        source, destination = args[2:4]
        resource = next(r for r in sim["resources"] if r["address"] == source)
        resource["address"] = destination
        resource["name"] = destination.split(".")[1].split("[")[0]
        log(f"mv {source} {destination}")
    elif args[:1] == ["plan"]:
        plan(args[1:])
    elif args[:1] == ["apply"] and args[1:3] == ["-input=false", "-lock-timeout=60s"] and len(args) == 4:
        apply(args[3])
    else:
        fail(f"Unexpected tofu arguments: {args}")


def kubectl(host, argv):
    if not (sim["hosts"][host]["rke2"] and sim["hosts"][host]["role"] != "etcd"):
        fail(f"No API server on {host}")
    argv = [a for a in argv if not a.startswith("--request-timeout=")]
    if argv == ["get", "--raw=/readyz"]:
        print("ok")
    elif argv == ["get", "nodes", "-o", "json"]:
        items = []
        for name, node in sim["nodes"].items():
            labels = {}
            if node["etcd"]:
                labels["node-role.kubernetes.io/etcd"] = "true"
            if node["cp"]:
                labels["node-role.kubernetes.io/control-plane"] = "true"
            ready = sim["hosts"].get(name, {}).get("rke2", False)
            items.append({"metadata": {"name": name, "labels": labels}, "status": {
                "conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}})
        for index in range(1, sim["worker_count"] + 1):
            items.append({"metadata": {"name": f"bench-wk-{index:02d}", "labels": {}},
                          "status": {"conditions": [{"type": "Ready", "status": "True"}]}})
        print(json.dumps({"items": items}))
    elif argv == ["-n", "kube-system", "get", "pods", "-l", "component=etcd", "-o", "json"]:
        print(json.dumps({"items": [
            {"metadata": {"name": f"etcd-{m['node']}"}, "status": {"phase": "Running"}}
            for m in sim["members"] if sim["hosts"].get(m["node"], {}).get("rke2")]}))
    elif argv[:3] == ["-n", "kube-system", "exec"] and argv[4:6] == ["--", "etcdctl"]:
        node = argv[3].removeprefix("etcd-")
        if not sim["hosts"].get(node, {}).get("rke2"):
            fail(f"etcd pod {argv[3]} is not running")
        etcdctl([a for a in argv[6:] if not a.startswith("--")])
    elif argv[:1] == ["drain"] and argv[1] in sim["nodes"]:
        log(f"drain {argv[1]}")
    elif argv[:2] == ["delete", "node"] and argv[2] in sim["nodes"]:
        name = argv[2]
        del sim["nodes"][name]
        if settings.get("finalizer", True):
            sim["members"] = [m for m in sim["members"] if m["node"] != name]
        check_invariants(f"deleting node {name}")
        log(f"delete node {name}")
    else:
        fail(f"Unexpected kubectl arguments: {argv}")


def etcdctl(argv):
    if argv == ["member", "list", "-w", "simple"]:
        for m in sim["members"]:
            print(f"{m['id']}, started, {m['name']}, https://x:2380, https://x:2379, false")
    elif argv == ["endpoint", "health"]:
        if not all(sim["hosts"].get(m["node"], {}).get("rke2") for m in sim["members"]):
            fail("unhealthy")
    elif argv[:2] == ["member", "remove"]:
        removed = [m for m in sim["members"] if m["id"] == argv[2]]
        if not removed:
            fail("member not found")
        sim["members"].remove(removed[0])
        check_invariants(f"removing member {removed[0]['name']}")
        log(f"member remove {removed[0]['node']}")
    else:
        fail(f"Unexpected etcdctl arguments: {argv}")


def ssh():
    if args[:4] != ["-i", os.environ["EXPECTED_KEY"], "-o", "IdentitiesOnly=yes"]:
        fail(f"Unexpected SSH identity arguments: {args[:4]}")
    if args[args.index("--") + 1] != "opensuse@192.168.1.20":
        fail("Unexpected jump-host SSH destination")
    outer = shlex.split(args[-1])
    ip = next(a for a in outer if a.startswith("opensuse@")).removeprefix("opensuse@")
    argv = shlex.split(outer[-1])
    if ip in LBS.values() or ip == VIP:
        lb = next((n for n, a in LBS.items() if a == ip), "bench-lb-01")
        if settings.get("lb_unreachable"):
            fail(f"ssh: connect to host {ip}: Connection timed out")
        if argv == ["hostname"]:
            print(lb)
        elif argv[:3] == ["sudo", "-n", "sh"] and "haproxy -c" in argv[-1]:
            sim["haproxy"][lb] = sys.stdin.read()
            log(f"push {lb}")
        else:
            fail(f"Unexpected load balancer command: {argv}")
        return
    host = next((n for n, h in sim["hosts"].items() if h["ip"] == ip), None)
    if host is None:
        fail(f"ssh: connect to host {ip}: No route to host")
    if argv[:3] == ["sudo", "-n", "/var/lib/rancher/rke2/bin/kubectl"]:
        kubectl(host, argv[4:])
    elif argv[:3] == ["sudo", "-n", "sh"] and "systemctl disable --now rke2-server.service" in argv[-1]:
        sim["hosts"][host]["rke2"] = False
        check_invariants(f"stopping {host}")
        log(f"stop {host}")
    elif argv == ["sudo", "-n", "sed", "-i", "/^server:/d", "/etc/rancher/rke2/config.yaml"]:
        sim["hosts"][host]["server"] = None
    elif argv[:4] == ["sudo", "-n", "sed", "-i"] and argv[4:5] == ["-E"]:
        match = re.fullmatch(r"s#\^server: \.\*#server: https://([0-9.]+):9345#", argv[5])
        if not match:
            fail(f"Unexpected sed expression: {argv}")
        if sim["hosts"][host]["server"] is not None:
            sim["hosts"][host]["server"] = match.group(1)
    else:
        fail(f"Unexpected remote command on {host}: {argv}")


if command == "tofu":
    tofu()
elif command == "kubectl":
    if args[:6] != ["--kubeconfig", "local.yaml", "--request-timeout=20s", "-n", "default", "get"] \
            or args[6] != "vmi" or args[8:] != ["-o", "json"] or args[7] not in LBS:
        fail(f"Unexpected Harvester kubectl arguments: {args}")
    addresses = [LBS[args[7]]] + ([VIP] if args[7] == "bench-lb-01" else []) + ["fe80::1"]
    # The guest agent of bench-lb-02 stops reporting its address at times.
    if args[7] == "bench-lb-02" and sim["applies"] >= settings.get("lb02_unreported_from_apply", 99):
        addresses = None
    print(json.dumps({"status": {"interfaces": [
        {"name": "default", "ipAddress": addresses and addresses[0], "ipAddresses": addresses}]}}))
elif command == "ssh":
    ssh()
elif command == "sleep":
    sim["sleeps"] += 1
    if sim["sleeps"] > settings.get("max_sleeps", 100):
        fail("Mock interrupted a wait that does not end")
else:
    fail(f"Unexpected command: {command}")
save()
'''


def stacked_simulation(workers=3, **settings):
    servers = ["bench-cp-01", "bench-cp-02", "bench-cp-03"]
    resources = []
    for name in servers:
        for type_ in ("harvester_virtualmachine", "harvester_cloudinit_secret"):
            address = (f"{type_}.bench_bootstrap" if name == "bench-cp-01"
                       else f'{type_}.bench["{name}"]')
            values = {"name": name if type_.endswith("machine") else f"{name}-cloudinit"}
            if not type_.endswith("machine"):
                values["role"] = "all"
            resources.append({"address": address, "type": type_,
                              "name": address.split(".")[1].split("[")[0], "values": values})
    for index in range(1, workers + 1):
        name = f"bench-wk-{index:02d}"
        resources.append({"address": f'harvester_virtualmachine.bench_worker["{name}"]',
                          "type": "harvester_virtualmachine", "name": "bench_worker",
                          "index": name, "values": {"name": name}})
    hosts = {name: {"ip": f"192.168.64.{10 + i}", "role": "all", "rke2": True,
                    "server": None if i == 0 else "192.168.64.10"}
             for i, name in enumerate(servers)}
    return {
        "settings": settings, "resources": resources, "outputs": {}, "hosts": hosts,
        "nodes": {name: {"etcd": True, "cp": True} for name in servers},
        "members": [{"id": f"{0x8e9e05c52164694d + i:x}", "node": name, "name": f"{name}-a1b{i}"}
                    for i, name in enumerate(servers)],
        "applied_roles": {name: "all" for name in servers}, "worker_count": workers,
        "next_ip": 20, "next_member": 0x1000, "haproxy": {}, "log": [], "violations": [],
        "plans": 0, "applies": 0, "sleeps": 0,
    }


class MigrateToDedicatedEtcdTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        shutil.copy(SCRIPT, self.directory / SCRIPT.name)
        self.key = self.directory / "jump_host.key"
        self.key.write_text("dummy key\n")
        self.key.chmod(0o600)
        (self.directory / "local.yaml").write_text("apiVersion: v1\n")
        for command in ("tofu", "ssh", "sleep", "kubectl"):
            executable = self.directory / command
            executable.write_text(MOCK)
            executable.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    @property
    def sim(self):
        return json.loads((self.directory / "sim.json").read_text())

    def write(self, sim):
        (self.directory / "sim.json").write_text(json.dumps(sim))

    def run_migration(self, environment=None, **settings):
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

    def assert_migrated(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        sim = self.sim
        self.assertEqual(sim["violations"], [])
        self.assertEqual(sim["applied_roles"], DEDICATED)
        self.assertEqual({n: h["role"] for n, h in sim["hosts"].items()}, DEDICATED)
        self.assertEqual(sorted(sim["nodes"]), sorted(DEDICATED))
        self.assertEqual(sorted(m["node"] for m in sim["members"]),
                         ["bench-etcd-01", "bench-etcd-02", "bench-etcd-03"])
        bootstrap = {r["values"]["name"] for r in sim["resources"] if r["name"] == "bench_bootstrap"}
        self.assertEqual(bootstrap, {"bench-etcd-01", "bench-etcd-01-cloudinit"})
        bootstrap_ip = sim["hosts"]["bench-etcd-01"]["ip"]
        self.assertIsNone(sim["hosts"]["bench-etcd-01"]["server"])
        for name in ("bench-etcd-02", "bench-etcd-03", "bench-cp-01", "bench-cp-02"):
            self.assertEqual(sim["hosts"][name]["server"], bootstrap_ip, name)
        expected = "".join(f"server {n} {sim['hosts'][n]['ip']}:6443 check\n"
                           for n in ("bench-cp-01", "bench-cp-02"))
        self.assertEqual(sim["haproxy"], {"bench-lb-01": expected, "bench-lb-02": expected})
        workers = [r for r in sim["resources"] if r["name"] == "bench_worker"]
        self.assertEqual(len(workers), sim["worker_count"])
        self.assertIn("Migration complete", result.stdout)

    def test_migrates_stacked_cluster_one_server_at_a_time(self):
        self.write(stacked_simulation())
        result = self.run_migration()
        self.assert_migrated(result)
        sim = self.sim
        self.assertEqual(sim["applies"], 7)
        changes = [line for line in sim["log"]
                   if not line.startswith("drain") and not line.startswith("push")]
        self.assertEqual(changes, [
            "create bench-etcd-01 etcd",
            "create bench-etcd-02 etcd",
            "create bench-etcd-03 etcd",
            "stop bench-cp-03", "delete node bench-cp-03",
            "delete bench-cp-03", "create bench-cp-03 control-plane",
            "stop bench-cp-02", "delete node bench-cp-02",
            "delete bench-cp-02", "create bench-cp-02 control-plane",
            "stop bench-cp-01", "delete node bench-cp-01",
            'mv harvester_virtualmachine.bench_bootstrap harvester_virtualmachine.bench["bench-cp-01"]',
            'mv harvester_cloudinit_secret.bench_bootstrap harvester_cloudinit_secret.bench["bench-cp-01"]',
            'mv harvester_virtualmachine.bench["bench-etcd-01"] harvester_virtualmachine.bench_bootstrap',
            'mv harvester_cloudinit_secret.bench["bench-etcd-01"] harvester_cloudinit_secret.bench_bootstrap',
            "delete bench-cp-01", "create bench-cp-01 control-plane",
            "stop bench-cp-03", "delete node bench-cp-03",
            "delete bench-cp-03",
        ])

    def test_resumes_after_failed_apply_once_server_was_removed(self):
        self.write(stacked_simulation())
        # The sixth apply is step 6, after bench-cp-01 left the cluster and the bootstrap swap.
        result = self.run_migration(fail_apply=6)
        self.assertNotEqual(result.returncode, 0)
        sim = self.sim
        self.assertNotIn("bench-cp-01", sim["nodes"])
        self.assertEqual(sim["outputs"]["rke2_servers"]["roles"]["bench-cp-01"], "all")
        result = self.run_migration()
        self.assert_migrated(result)
        self.assertEqual(self.sim["log"].count("stop bench-cp-01"), 1)

    def test_resume_updates_haproxy_skipped_by_failed_run(self):
        self.write(stacked_simulation())
        result = self.run_migration(lb_unreachable=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not reach bench-lb-01", result.stderr)
        self.assertEqual(self.sim["applies"], 1)
        result = self.run_migration()
        self.assert_migrated(result)
        log = self.sim["log"]
        self.assertLess(log.index("push bench-lb-02"), log.index("create bench-etcd-02 etcd"))

    def test_remembers_load_balancer_address_harvester_stops_reporting(self):
        self.write(stacked_simulation())
        result = self.run_migration(lb02_unreported_from_apply=3)
        self.assert_migrated(result)
        self.assertIn("bench-lb-02 192.168.66.21", (self.directory / ".lb-addresses").read_text())

    def test_load_balancer_address_can_be_given(self):
        self.write(stacked_simulation())
        (self.directory / "local.yaml").unlink()
        result = self.run_migration({"LB_ADDRESSES": "bench-lb-02=192.168.66.21"})
        self.assert_migrated(result)

    def test_load_balancer_without_harvester_address_is_not_skipped(self):
        self.write(stacked_simulation())
        (self.directory / "local.yaml").unlink()
        result = self.run_migration()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not reach bench-lb-02 (tried: no address reported)",
                      result.stderr)
        self.assertIn("LB_ADDRESSES=bench-lb-02=<address>", result.stderr)
        self.assertEqual(self.sim["haproxy"], {"bench-lb-01": "".join(
            f"server bench-cp-0{i} 192.168.64.{9 + i}:6443 check\n" for i in (1, 2, 3))})

    def test_falls_back_to_removing_etcd_member_directly(self):
        self.write(stacked_simulation())
        result = self.run_migration(finalizer=False)
        self.assert_migrated(result)
        removed = [line for line in self.sim["log"] if line.startswith("member remove")]
        self.assertEqual(removed, ["member remove bench-cp-03", "member remove bench-cp-02",
                                   "member remove bench-cp-01"])

    def test_completed_migration_only_checks(self):
        self.write(stacked_simulation())
        self.assert_migrated(self.run_migration())
        result = self.run_migration()
        self.assert_migrated(result)
        self.assertIn("already uses dedicated etcd nodes", result.stdout)
        self.assertEqual(self.sim["applies"], 7)

    def test_plan_changing_workers_is_not_applied(self):
        self.write(stacked_simulation())
        result = self.run_migration(worker_drift=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to apply step 1", result.stderr)
        self.assertIn('bench_worker["bench-wk-01"]: update', result.stderr)
        sim = self.sim
        self.assertEqual(sim["applies"], 0)
        self.assertNotIn("rke2_servers", sim["outputs"])

    def test_unhealthy_cluster_blocks_migration(self):
        sim = stacked_simulation()
        sim["hosts"]["bench-cp-02"]["rke2"] = False
        self.write(sim)
        result = self.run_migration(max_sleeps=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bench-cp-02 is not Ready", result.stderr)
        self.assertEqual(self.sim["plans"], 0)

    def test_refuses_workers_with_gaps(self):
        sim = stacked_simulation()
        sim["resources"] = [r for r in sim["resources"] if r.get("index") != "bench-wk-02"]
        self.write(sim)
        result = self.run_migration()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("finish scaling with scale-workers.sh", result.stderr)
        self.assertEqual(self.sim["plans"], 0)


if __name__ == "__main__":
    unittest.main()
