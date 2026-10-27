import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1]


def parse_yaml(text):
    result = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e",
         "puts JSON.generate(YAML.safe_load(STDIN.read))"],
        input=text, text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)


class LoadBalancerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in (
                "haproxy.cfg", "keepalived.conf",
                "load-balancer-cloud-config.yml", "server-cloud-config.yml",
            ):
                shutil.copy(MODULE / name, directory / name)
            (directory / "main.tf").write_text('''
locals {
  haproxy = templatefile("${path.module}/haproxy.cfg", {
    servers = {
      bench-cp-01 = "192.168.64.10"
      bench-cp-02 = "192.168.64.11"
      bench-cp-03 = "192.168.64.12"
    }
  })
  keepalived = { for priority in [150, 100] : tostring(priority) =>
    templatefile("${path.module}/keepalived.conf", {
      priority = priority, rke2_api_vip = "192.168.64.253"
    })
  }
  lb = { for name, priority in { bench-lb-01 = 150, bench-lb-02 = 100 } : name =>
    templatefile("${path.module}/load-balancer-cloud-config.yml", {
      node_name = name, bench_public_key = "ssh-ed25519 test-bench"
      harvester_public_key = "ssh-ed25519 test-harvester"
      haproxy_config = local.haproxy
      keepalived_config = local.keepalived[tostring(priority)]
    })
  }
  servers = { for name, address in {
    bench-cp-01 = "", bench-cp-02 = "192.168.64.10"
  } : name => templatefile("${path.module}/server-cloud-config.yml", {
    node_name = name, server_address = address, rke2_token = "test-token"
    bench_public_key = "ssh-ed25519 test-bench"
    harvester_public_key = "ssh-ed25519 test-harvester"
    rke2_server_script = "#!/bin/bash\\necho test\\n"
    rke2_cluster_cidr = "10.44.0.0/14", rke2_api_vip = "192.168.64.253"
  }) }
}
''')
            result = subprocess.run(
                ["tofu", "console", "-no-color"], cwd=directory,
                input="jsonencode({haproxy=local.haproxy, keepalived=local.keepalived, lb=local.lb, servers=local.servers})\n",
                text=True, capture_output=True, check=True,
            )
            cls.rendered = json.loads(json.loads(result.stdout))

    def test_haproxy_balances_both_ports_to_all_servers(self):
        config = self.rendered["haproxy"]
        for backend, port in (("rke2-supervisor", 9345), ("kubernetes-api", 6443)):
            self.assertIn(f"bind *:{port}", config)
            self.assertIn(f"default_backend {backend}", config)
            section = config.split(f"\nbackend {backend}\n")[1].split("\nbackend ")[0]
            self.assertIn("balance leastconn", section)
            self.assertIn("option tcp-check", section)
            for index, ip in enumerate(range(10, 13), start=1):
                self.assertIn(f"server bench-cp-0{index} 192.168.64.{ip}:{port} check", section)
        self.assertIn("timeout client 1h", config)
        self.assertIn("timeout server 1h", config)
        self.assertIn("maxconn 100000", config)
        self.assertIn(
            "stats socket /var/lib/haproxy/stats user haproxy group haproxy mode 0640 level operator",
            config,
        )
        self.assertNotIn("/run/haproxy.sock", config)

    def test_keepalived_uses_shared_vip_and_distinct_priorities(self):
        for priority, config in self.rendered["keepalived"].items():
            self.assertIn(f"priority {priority}", config)
            self.assertIn("state BACKUP", config)
            self.assertIn("192.168.64.253/19 dev eth0", config)
            self.assertIn("virtual_router_id 51", config)
            self.assertIn("track_script {\n        chk_haproxy", config)
            self.assertIn("init_fail", config)
            self.assertNotIn("unicast_peer", config)

    def test_lb_cloud_init_installs_and_validates_services(self):
        for name, text in self.rendered["lb"].items():
            config = parse_yaml(text)
            self.assertEqual(config["hostname"], name)
            self.assertTrue({"haproxy", "keepalived", "iptables", "qemu-guest-agent"}
                            <= set(config["packages"]))
            user = config["users"][0]
            self.assertTrue(user["lock_passwd"])
            self.assertEqual(len(user["ssh_authorized_keys"]), 2)
            files = {item["path"]: item for item in config["write_files"]}
            self.assertEqual(files["/etc/haproxy/haproxy.cfg"]["content"].strip(),
                             self.rendered["haproxy"].strip())
            priority = "150" if name == "bench-lb-01" else "100"
            self.assertEqual(files["/etc/keepalived/keepalived.conf"]["content"].strip(),
                             self.rendered["keepalived"][priority].strip())
            check = files["/usr/local/sbin/check-haproxy"]
            self.assertEqual(check["permissions"], "0755")
            self.assertIn("systemctl is-active --quiet haproxy.service", check["content"])
            startup = config["runcmd"][-1]
            self.assertEqual(startup[:2], ["bash", "-ec"])
            self.assertLess(startup[2].index("haproxy -c"),
                            startup[2].index("systemctl restart haproxy.service"))
            self.assertLess(startup[2].index("keepalived --config-test"),
                            startup[2].index("systemctl restart keepalived.service"))
            self.assertIn("LimitNOFILE=262144",
                          files["/etc/systemd/system/haproxy.service.d/limits.conf"]["content"])

    def test_server_cloud_init_preserves_bootstrap_and_cluster_settings(self):
        for name, text in self.rendered["servers"].items():
            config = parse_yaml(text)
            self.assertEqual(config["hostname"], name)
            self.assertIn("iptables", config["packages"])
            files = {item["path"]: item for item in config["write_files"]}
            self.assertFalse(any("kube-vip" in path for path in files))
            rke2 = parse_yaml(files["/etc/rancher/rke2/config.yaml"]["content"])
            self.assertEqual(rke2["tls-san"], ["192.168.64.253"])
            self.assertEqual(rke2["cluster-cidr"], "10.44.0.0/14")
            self.assertEqual(rke2["node-taint"], ["CriticalAddonsOnly=true:NoExecute"])
            self.assertTrue(rke2["etcd-expose-metrics"])
            self.assertEqual(rke2["kube-controller-manager-arg"], [
                "bind-address=0.0.0.0",
                "authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics",
                "kube-api-qps=100",
                "kube-api-burst=200",
                "concurrent-deployment-syncs=20",
                "concurrent-replicaset-syncs=20",
            ])
            if name == "bench-cp-01":
                self.assertNotIn("server", rke2)
            else:
                self.assertEqual(rke2["server"], "https://192.168.64.10:9345")


if __name__ == "__main__":
    unittest.main()
