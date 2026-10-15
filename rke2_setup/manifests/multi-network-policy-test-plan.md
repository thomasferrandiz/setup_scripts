# MultiNetworkPolicy Test Plan

## Purpose

Validate that `MultiNetworkPolicy` resources enforce Kubernetes `NetworkPolicy`
semantics on the NetworkAttachmentDefinition selected by
`k8s.v1.cni.cncf.io/policy-for`, without affecting a pod's primary network or
other secondary networks.

This plan is based on [scheme-multi-netpol.yaml](./scheme-multi-netpol.yaml).
The CRD is namespaced (`k8s.cni.cncf.io/v1beta1`), requires
`spec.podSelector`, and supports Kubernetes NetworkPolicy-style `ingress`,
`egress`, `policyTypes`, `podSelector`, `namespaceSelector`, `ipBlock`, ports,
protocols, and port ranges. The policy attachment itself is identified by the
`k8s.v1.cni.cncf.io/policy-for` annotation, as shown in
[policy-multi-netpol.yaml](./policy-multi-netpol.yaml).

## Scope

### In scope

- CRD installation, discovery, and schema admission.
- Policy enforcement on an attached `macvlan` or `ipvlan` Multus network.
- Ingress and egress default-deny behavior and allow rules.
- Pod, namespace, CIDR, port, protocol, named-port, and port-range matching.
- Union behavior for multiple policies selecting the same pod.
- Isolation between the policy attachment, the primary network, and another
  secondary attachment.
- Policy reconciliation after policy, pod, label, namespace-label, and
  attachment changes.
- IPv4 and IPv6 where the attachment is dual-stack.

### Out of scope

- Primary CNI `NetworkPolicy` behavior.
- Throughput, latency, or nftables performance benchmarking.
- Underlying CNI correctness unrelated to policy enforcement.

## Test environment

| Item | Requirement |
| --- | --- |
| Kubernetes | RKE2 cluster with nodes that can run privileged DaemonSets. |
| Multus | Installed and functional. |
| Policy controller | [deploy-multi-netpol.yaml](./deploy-multi-netpol.yaml) applied and its DaemonSet ready on every node hosting test pods. Its configured plugins include the selected attachment type (`macvlan` or `ipvlan`). |
| CRD | [scheme-multi-netpol.yaml](./scheme-multi-netpol.yaml) applied. |
| Attachments | `test-net-a` and `test-net-b` NetworkAttachmentDefinitions. `test-net-a` is the policy target and has a predictable IPv4 subnet; add IPv6 when dual-stack testing. |
| Workloads | Long-running client and server pods with `curl`, `nc`, `dig`, and an HTTP/TCP/UDP listener. The server must expose numeric ports `8080`, `8081`, and a named `http` port. |
| Namespaces | `mnp-test-a` and `mnp-test-b`, labeled `mnp-test=true` and `mnp-test=false`, respectively. |
| Evidence | Save applied manifests, pod interface/IP inventory, command output, controller logs, and relevant node nftables rules for every failed case. |

Use dedicated test namespaces and remove them during cleanup; never run
default-deny cases against shared workloads.

## Common setup and evidence collection

1. Install the CRD and controller:

   ```sh
   kubectl apply -f rke2_setup/manifests/scheme-multi-netpol.yaml
   kubectl apply -f rke2_setup/manifests/deploy-multi-netpol.yaml
   kubectl rollout status -n kube-system daemonset/multi-networkpolicy-nftables
   ```

2. Confirm API discovery and controller readiness:

   ```sh
   kubectl api-resources --api-group=k8s.cni.cncf.io
   kubectl get crd multi-networkpolicies.k8s.cni.cncf.io
   kubectl get pods -n kube-system -l name=multi-networkpolicy-nftables -o wide
   ```

3. Create the two namespaces, both NetworkAttachmentDefinitions, and client
   and server pods. Attach `test-net-a` to all test pods. Attach `test-net-b`
   to at least one client/server pair for network-isolation tests.

4. Record each pod's primary and secondary IP addresses and its interface names:

   ```sh
   kubectl get pods -A -o wide
   kubectl exec -n mnp-test-a <pod> -- ip -brief address
   kubectl exec -n mnp-test-a <pod> -- ip route
   ```

5. Baseline every planned flow before applying a policy. Run the test command
   with an explicit destination IP on `test-net-a`; do not rely on Kubernetes
   Services or DNS routing through the primary network. A successful TCP check,
   for example, is:

   ```sh
   kubectl exec -n mnp-test-a <client> -- \
     curl --connect-timeout 3 --max-time 5 -fsS http://<server-net-a-ip>:8080/
   ```

   A negative test passes only when the connection is denied or times out
   within the command's fixed timeout. Capture the exit code and stderr.

6. After each policy change, wait for the controller to reconcile, then repeat
   the flow at least three times. Capture:

   ```sh
   kubectl get multi-networkpolicies -A -o yaml
   kubectl logs -n kube-system -l name=multi-networkpolicy-nftables --since=5m
   ```

## Test cases

| ID | Scenario and setup | Expected result |
| --- | --- | --- |
| MNP-001 | Apply the CRD and create a minimal policy containing only `spec.podSelector: {}`. Query it by plural name and `multi-policy` short name. | The CRD is `Established`; both resource names resolve; the object is persisted in its namespace. |
| MNP-002 | Attempt to create a policy without `spec.podSelector`. | API admission rejects the object because `podSelector` is required. |
| MNP-003 | Create malformed manifests: a non-array `ingress`, a non-string protocol, `ipBlock` without `cidr`, and a selector expression without `key` or `operator`. | API admission rejects each invalid structural schema case with a useful validation error. |
| MNP-004 | Create semantically invalid manifests: `endPort` lower than `port`, `endPort` with a named port, and an `ipBlock` combined with a pod or namespace selector. | The API server or controller rejects/errors each case; no unintended allow rule is installed. Record the owning component and error because these cross-field constraints are documented by the CRD but are not all expressible in its structural schema. |
| MNP-005 | With no `MultiNetworkPolicy`, verify TCP 8080/8081 and UDP traffic from a same-namespace client to the server through `test-net-a`. | All baseline flows succeed. This is the control for later deny tests. |
| MNP-006 | Apply an ingress-only policy targeting the server (`app=server`) with `policyTypes: [Ingress]` and no `ingress` rules. | All non-local ingress through `test-net-a` to selected server pods is denied. The primary network and unselected pods retain their baseline behavior. |
| MNP-007 | Starting from MNP-006, allow `from.podSelector.matchLabels.app=client` to TCP 8080. Test an allowed client, a differently labeled client, TCP 8081, and UDP 8080. | Only the labeled client reaches TCP 8080 over `test-net-a`; the other source, port, and protocol are denied. |
| MNP-008 | Replace the peer with `namespaceSelector: {matchLabels: {mnp-test: "true"}}` plus `podSelector: {matchLabels: {app: client}}`. Test matching and nonmatching namespace/pod combinations. | Traffic is allowed only when both namespace and pod selector match. |
| MNP-009 | Use separate `from` peers for a pod selector and an `ipBlock`; then add an `ipBlock.except` subnet containing one client. | Peers are ORed; clients in either permitted peer succeed; the excepted client is denied. |
| MNP-010 | Test ingress port matching with `port: http` (the server's named port), `port: 8080, endPort: 8081`, TCP, UDP, and SCTP when supported by the cluster. | Named port and inclusive numeric range match exactly. Protocol mismatches are denied. Mark SCTP as not applicable only when the kernel/CNI does not support it. |
| MNP-011 | Apply an egress-only policy targeting the client with `policyTypes: [Egress]` and no `egress` rules. | All selected client egress through `test-net-a` is denied, including server traffic and an external/CIDR target. Ingress remains at its baseline state. |
| MNP-012 | Starting from MNP-011, allow egress to the server with a pod selector on TCP 8080. Add cases for namespace+pod selector, `ipBlock`, a named port, and `endPort`. | Only destinations and ports matching an egress peer and port rule succeed; all other `test-net-a` egress remains denied. |
| MNP-013 | Omit `policyTypes` in policies containing: ingress only, egress only, both sections, and neither section. | Behavior follows CRD defaults: ingress applies in all four cases; egress also applies when `egress` is present; a no-rule egress deny requires explicit `Egress`. |
| MNP-014 | Apply two ingress policies selecting the server: one permits client A on 8080 and another permits client B on 8081. Repeat for two egress policies selecting the client. | Allowed traffic is the union of matching policy rules; no policy overrides or narrows another policy's allowed traffic. |
| MNP-015 | Start with a policy that selects `app=server`. Change a selected server label to unselected and back; change a selected client label; change the matching namespace label. | Access changes after reconciliation to reflect each current label state, with no stale allow/deny rule. |
| MNP-016 | Update an existing policy from deny-all to allow TCP 8080, then back to deny-all. Delete the policy. | Enforcement changes after each update; deleting the final selecting policy restores the no-policy baseline on `test-net-a`. |
| MNP-017 | Target `test-net-a` with `policy-for`, then test identical flows on the pod's primary network and `test-net-b`. Repeat with a policy that references an absent or misspelled attachment. | Only `test-net-a` is enforced. Primary and `test-net-b` flows are unchanged. A non-existent attachment does not affect any interface and produces diagnosable controller output. |
| MNP-018 | Schedule selected client and server on different nodes, then repeat MNP-007 and MNP-012. Restart one controller DaemonSet pod during enforcement and repeat. | Cross-node policy enforcement is identical to same-node behavior. The controller recovers and converges without opening denied traffic permanently. |
| MNP-019 | On a dual-stack attachment, repeat MNP-006 through MNP-012 using IPv4 and IPv6 addresses, CIDRs, and exceptions. | IPv4 and IPv6 each match only their configured permitted peers/ports. If single-stack, mark IPv6 not applicable with cluster evidence. |
| MNP-020 | Configure a non-comment custom rule in the controller ConfigMap for a unique test port, reconcile/restart as required, and test it before and after a matching `MultiNetworkPolicy`. | The custom rule is loaded as documented and its interaction with policy rules is deterministic. Restore the ConfigMap afterward. |

## Exit criteria

- MNP-001 through MNP-018 pass; MNP-019 passes on dual-stack environments or
  is explicitly marked not applicable with evidence.
- Every deny assertion proves that the same flow worked in its recorded
  baseline or a documented predecessor state.
- No selected policy changes traffic on the primary network or a non-target
  secondary attachment.
- Controller logs contain no unhandled reconciliation errors, and all
  controller DaemonSet pods are ready after lifecycle and recovery tests.
- All test resources are deleted and post-cleanup baseline connectivity is
  recorded.

## Cleanup

Delete all `MultiNetworkPolicy` resources first, wait for reconciliation, then
delete test pods, NetworkAttachmentDefinitions, and namespaces:

```sh
kubectl delete multi-networkpolicies.k8s.cni.cncf.io --all -n mnp-test-a
kubectl delete multi-networkpolicies.k8s.cni.cncf.io --all -n mnp-test-b
kubectl delete namespace mnp-test-a mnp-test-b
```

Do not delete the shared CRD or the controller deployment unless the test
environment was created exclusively for this plan.
