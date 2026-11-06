# OCI POC: install Kubernetes on three DataWalk VMs and Podman on one Hyperscience GPU VM

Revision: 1.0 — 2026-11-06. Documentation prepared; runtime deployment **UNVERIFIED**.

This operator guide fixes the POC footprint at **three DataWalk RHEL VMs total**, sharing one Kubernetes cluster for Dev/Test, and **one separate Hyperscience RHEL GPU VM**. It is a self-managed kubeadm build, not managed OKE. A managed OKE build has different worker-image and control-plane requirements. This guide supersedes earlier four-VM DataWalk installation assumptions for this specific POC. Existing Word documents and research contain alternative designs.

The Kubernetes control plane must run somewhere. Here it runs on DW01, inside the three-VM count. The normal build has DW01 as control plane and DW02/DW03 as workers. Step 16 optionally permits application pods on DW01 to provide three schedulable nodes without buying a fourth VM. This requires DataWalk/platform approval and resource headroom. It provides **one control plane, not control-plane high availability**. Dev/Test namespaces share host, cluster, and failure boundaries.

## 1. Inventory and execution conventions

| Host | Proposed private IP | Role | Planning capacity |
|---|---|---|---|
| dw01 | 10.0.18.34 | Control plane; optionally application worker | E6 Flex, 8 OCPU / 128 GB |
| dw02 | 10.0.18.35 | Worker | E6 Flex, 8 OCPU / 128 GB |
| dw03 | 10.0.18.36 | Worker | E6 Flex, 8 OCPU / 128 GB |
| hs01 | 10.0.18.82 | RHEL + Podman + NVIDIA GPU application | VM.GPU.A10.2 |

Sizes are planning examples, not vendor minima. Private IPs are proposed allocations: reconcile them against actual VNICs and IPAM before execution. Do not copy these IPs onto a Linux NIC as static OS configuration; reserve/select them in OCI and retain image-supported DHCP configuration.

| Address domain | Allocation |
|---|---|
| Non-production | 10.0.18.0/24 |
| DataWalk node subnet, if creating new subnet boundaries | 10.0.18.32/27 |
| Hyperscience subnet, if creating new subnet boundaries | 10.0.18.80/28 |
| Production reserve; not provisioned by this guide | 10.0.17.0/24 |
| Pod overlay example, subject to enterprise overlap check | 10.244.0.0/16 |
| Service CIDR example, subject to enterprise overlap check | 10.96.0.0/16 |

If 10.0.18.0/24 is already one OCI subnet, it cannot simultaneously contain new overlapping OCI subnets. Use the existing subnet plus separate NSGs, or obtain a network-team plan to create non-overlapping subnet boundaries. A VCN can contain these smaller subnets only when its existing layout permits it. This guide does not recreate a VCN.

Commands labeled **all DW nodes** run individually on dw01, dw02, dw03. Commands labeled **DW01** run only there. **HS01** means only the GPU VM. Commands use sudo from an authorized operator account. Never paste the whole document as one script: stop at each acceptance check and substitute approved values.

## 2. Freeze the supported versions before installing

Record this matrix with DataWalk, Hyperscience and the platform SME:

| Component | Required decision |
|---|---|
| RHEL | 8.10 baseline; entitlement, kernel, errata and EUS strategy |
| Kubernetes | Exact supported minor and patch; still supported at execution date |
| kubeadm API | v1beta4 examples below require Kubernetes 1.31+; use matching docs if vendor selects older release |
| containerd / runc / CNI binaries | Exact supported versions compatible with RHEL kernel, SELinux and Kubernetes |
| Flannel | Pinned release and checksum, IPv4 VXLAN backend, selected-interface/MTU review |
| DataWalk | Release, chart, image digests, three-node role support, storage requirements, license |
| Hyperscience | Release and TVE versus standard package; supported Podman and GPU integration mode |
| NVIDIA | Driver branch, toolkit packages and test image digest compatible with HS release |

Do not install whatever `latest` resolves to. RHEL 8's kernel and Podman stream may limit newer Kubernetes/CNI/CDI combinations. A newer Kubernetes documentation page does not establish RHEL 8.10 or DataWalk certification. Exact approved package NEVRAs and image digests are site inputs, deliberately not invented here.

## 3. OCI and access prerequisites — network/platform operator

1. Confirm four existing/provisioned VMs, console recovery access, OS images compatible with the shapes, private VNICs, capacity and boot/data volumes.
2. Use the actual government region and realm endpoints. Do not substitute commercial-region OCIDs or registry hostnames.
3. Confirm on-premises → FastConnect → DRG → inspection path → subnet and symmetric return routing. Test SSH from the approved jump host to all four IPs.
4. Confirm enterprise DNS, NTP, package mirror, certificate chain, image registry and Object Storage access. Service Gateway access does **not** provide internet access to pkgs.k8s.io, NVIDIA, Flannel or vendor downloads.
5. Review the existing [VM foundation](../terraform/oci-vm-foundation/README.md). Its default NSG allows SSH and selected service access, not Kubernetes node-to-node traffic. Do not run separate copies of its VCN-creating stack with the same 10.0.18.0/24 range for DW and HS.
6. Arrange approved RPM and image mirrors or an offline transfer before bootstrap. Keep registries/staging on existing services; a new Harbor/jump/storage VM would increase the four-VM footprint.

### Required network flows

Apply both OCI NSG/security-list rules and equivalent host rules; maintain SCCA inspection controls. Restrict node rules to the three node /32 addresses or their dedicated subnet, not every RFC1918 address.

| Source | Destination | Protocol/port | Purpose |
|---|---|---|---|
| Approved jump/admin | Four VMs | TCP 22 | SSH |
| DW nodes + approved admins | DW01 | TCP 6443 | Kubernetes API |
| DW01 | All DW nodes | TCP 10250 | kubelet logs/exec/control |
| DW nodes | DW nodes | UDP 8472 | Flannel VXLAN; never internet-exposed |
| Same node / localhost | Local control-plane endpoints | TCP 2379–2380, 10257, 10259 | etcd/controller/scheduler; no remote rule needed for this single-control-plane design |
| DW nodes | Approved DNS | UDP/TCP 53 | Host and pod DNS forwarding |
| Four VMs | Approved NTP | UDP 123 | Time synchronization |
| Four VMs | Mirrors/registries/proxy | Approved TCP 443 or site proxy port | Packages/images/HS artifacts |
| DW nodes | Approved storage | Backend-specific, e.g. TCP 2049 for NFSv4 | Persistent storage if selected |
| Approved clients/LB | Selected DW ingress nodes | Explicit chosen NodePort only | Only if using NodePort-backed ingress |
| Approved clients | HS01 | TCP 443; additional vendor ports only when confirmed | Private HS UI/API |

Kube-proxy health port 10256 is needed only from an authorized health checker if that integration uses it. Do not open the whole 30000–32767 NodePort range by default. Node-to-node ICMP for diagnostics and ICMP fragmentation-needed/path-MTU handling must follow the network standard. CNI overlay traffic and forwarded pod traffic must also be permitted by host filtering, not only INPUT ports. See step 6.

## 4. Stage packages, images and configuration — before changing nodes

On a connected, approved staging host obtain and verify:

- RHEL BaseOS/AppStream dependencies, container-selinux, conntrack-tools, socat, iproute-tc, chrony, tar and policycoreutils tools.
- containerd, runc, compatible CNI plugin binaries, kubelet/kubeadm/kubectl and cri-tools, with their dependency closure.
- The approved Flannel manifest and all images it references, including init containers.
- kubeadm control-plane, etcd, CoreDNS, kube-proxy and sandbox/pause images for the chosen patch.
- A pinned diagnostic image containing sh, nslookup, wget and sleep; a pinned HTTP test image.
- DataWalk chart, all images, migration package and storage instructions; Hyperscience release bundle/model files; NVIDIA driver/toolkit RPMs and CUDA diagnostic image.

Transfer through the approved jump host/Object Storage workflow. On the destination:

```bash
cd /srv/poc-artifacts
sha256sum -c SHA256SUMS
rpm -K rpms/*.rpm
```

Expected: hashes match the trusted manifest and RPM signatures validate using independently trusted keys. A manifest copied with files detects corruption, but does not authenticate an untrusted download. Store artifacts and reports in access-controlled storage; never commit vendor bundles, keys, authfiles or tokens to GitHub.

Use either an approved signed internal RPM repository (preferred) or `sudo dnf --disablerepo='*' install ./rpms/*.rpm` after checking the exact set and dependencies. Do not install unrelated DW and HS packages together. The package examples below assume mirrors already configured. Pin exact NEVRAs in the change record.

## 5. Prepare the RHEL operating system — all DW nodes

Check each node:

```bash
cat /etc/redhat-release
uname -r
lscpu
free -h
lsblk -f
df -hT
ip -br addr
ip route
sudo cat /sys/class/dmi/id/product_uuid
sudo subscription-manager identity
sudo dnf repolist
```

Expect RHEL 8.10, unique MAC/UUID/hostname, adequate disk and working entitled mirrors. Satellite/RHUI-managed systems may use a different entitlement check; do not re-register them blindly.

Set a unique hostname, changing the value on each machine:

```bash
sudo hostnamectl set-hostname dw01
```

Add these entries once on all DW nodes, unless enterprise DNS already supplies them:

```text
10.0.18.34 dw01
10.0.18.35 dw02
10.0.18.36 dw03
```

Use `sudoedit /etc/hosts` and verify `getent hosts dw01 dw02 dw03`. `/etc/hosts` entries on a node do not automatically become pod DNS entries.

```bash
sudo dnf install -y chrony conntrack-tools socat iproute-tc container-selinux
sudo systemctl enable --now chronyd
chronyc tracking
chronyc sources -v
sudo swapoff -a
swapon --show
```

Use `sudoedit /etc/fstab` to disable only actual swap entries; disable any active systemd swap/zram configuration as applicable. Retain a backup. Do not delete unrelated mounts. Reboot during preparation, then verify swap stays disabled and NTP is synchronized.

```bash
cat <<'CFG' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
CFG
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<'CFG' | sudo tee /etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
CFG
sudo sysctl --system
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
```

## 6. Resolve SELinux and host packet filtering — all DW nodes

Keep firewalld and SELinux in their approved configuration. Inspect:

```bash
getenforce
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all-zones
sudo nft list ruleset
```

The upstream kubeadm generic RPM procedure uses permissive SELinux. A hardened enforcing deployment requires a compatible runtime/CNI policy set. Have the platform SME choose and document the supported policy configuration before proceeding. If the approved POC explicitly permits permissive mode:

```bash
sudo setenforce 0
sudoedit /etc/selinux/config
```

Set `SELINUX=permissive` persistently only under that approved exception; restore enforcing with tested policies before operational acceptance. Do not use `--ignore-preflight-errors=all` to hide failures.

For each active host firewall zone, add source-scoped rich rules for the flow table. Example on DW01, after substituting the actual active zone:

```bash
ZONE=public
sudo firewall-cmd --permanent --zone="$ZONE" \
  --add-rich-rule='rule family="ipv4" source address="10.0.18.35/32" port port="6443" protocol="tcp" accept'
```

Repeat for DW03 and approved admin sources. On all three nodes allow 10250 from DW01 and UDP 8472 from the other node IPs. Reload only after reviewing the complete ruleset and ensuring SSH remains allowed. The network SME must also configure forwarding between the selected CNI bridge/VXLAN and host interface, pod-source egress and return traffic using the installed firewalld version's supported policy mechanism. Do not apply broad `trusted` zones or a blanket forwarding ACCEPT to bypass that review. Verify cross-node pod connectivity at step 18; a successful TCP/6443 check alone is insufficient.

## 7. Install containerd and CRI tools — all DW nodes

Install the exact approved RPMs from the internal mirror. `containerd` package names differ by distributor (for example containerd versus containerd.io); select the mirrored package instead of enabling an unrelated public repository. Also install cri-tools and the CNI binary package appropriate to that runtime.

```bash
containerd --version
runc --version
sudo install -d -m 0755 /etc/containerd
```

On a **fresh** node generate the matching version's default config. On an existing node back up and merge instead of overwriting:

```bash
sudo sh -c 'containerd config default > /etc/containerd/config.toml'
sudoedit /etc/containerd/config.toml
```

Set `SystemdCgroup = true` for the selected runc runtime. Check the runtime's actual schema:

| containerd | Typical config location |
|---|---|
| 1.x / config version 2 | `plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options` |
| 2.x / config version 3 | `plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options` |

Ensure CRI is enabled (`cri` must not be disabled). Set the sandbox/pause image to the approved mirrored reference using the installed version's schema (`sandbox_image` in 1.x; pinned sandbox image configuration in 2.x). Ensure this matches kubeadm's expected pause version. Configure registry CA trust and authenticated mirror access using that containerd version's registry configuration, not Podman authfiles.

For offline environments either preserve upstream image names through a correctly configured mirror, or rewrite/pin every reference consistently and pre-import archives with `sudo ctr -n k8s.io images import IMAGE.tar`. Merely importing an image under a different tag does not satisfy the requested reference.

```bash
sudo systemctl enable --now containerd
sudo systemctl restart containerd
cat <<'CFG' | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
CFG
sudo crictl info
sudo crictl images
```

Expected: CRI RuntimeReady true. NetworkReady may be false until CNI is installed. If CRI is unavailable, fix the config/package versions before kubeadm.

## 8. Install pinned Kubernetes packages — all DW nodes

Preferred: use the approved internal mirror for the frozen minor/patch. For an explicitly authorized internet-connected build only, upstream uses a per-minor repository. Example template, **replace the minor with the supported selection first**:

```bash
K8S_MINOR='v1.REPLACE'
# Do not execute until this variable has an approved value.
cat <<CFG | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
CFG
```

Review trusted signing keys and the package version list. Install identical exact kubeadm/kubelet/kubectl patches on all three nodes; sample NEVRAs below are placeholders:

```bash
sudo dnf --showduplicates list kubeadm --disableexcludes=kubernetes
sudo dnf install -y kubeadm-APPROVED_NEVRA kubelet-APPROVED_NEVRA \
  kubectl-APPROVED_NEVRA --disableexcludes=kubernetes
sudo systemctl enable kubelet
kubeadm version -o short
kubelet --version
kubectl version --client
```

Use the existing mirror/version-lock policy to prevent unattended Kubernetes upgrades. Kubelet may restart/fail before kubeadm writes its config; that is expected at this stage.

## 9. Pin each kubelet to its private node IP — all DW nodes

Review the installed service drop-in (`sudo systemctl cat kubelet`) and merge `KUBELET_EXTRA_ARGS` into `/etc/sysconfig/kubelet` if that is the EnvironmentFile it uses. Example on DW01:

```text
KUBELET_EXTRA_ARGS=--node-ip=10.0.18.34
```

Use `.35` on DW02 and `.36` on DW03. Preserve existing approved flags. This avoids advertising the wrong NIC on multi-interface hosts.

## 10. Prepare kubeadm configuration — DW01 only

Use a real enterprise DNS name for the endpoint if available. This POC example uses `dw01:6443`, resolved by all node hosts via step 5. The endpoint remains tied to one machine.

```bash
umask 077
mkdir -p ~/poc-build
cd ~/poc-build
cat > kubeadm.yaml <<'YAML'
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.0.18.34
  bindPort: 6443
nodeRegistration:
  name: dw01
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: dw-poc
kubernetesVersion: vREPLACE_APPROVED_PATCH
controlPlaneEndpoint: dw01:6443
imageRepository: REPLACE_APPROVED_KUBEADM_IMAGE_REPOSITORY
apiServer:
  certSANs:
    - dw01
    - 10.0.18.34
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/16
  dnsDomain: cluster.local
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
systemReserved:
  cpu: "1"
  memory: 2Gi
kubeReserved:
  cpu: "1"
  memory: 2Gi
evictionHard:
  memory.available: 500Mi
  nodefs.available: 10%
  imagefs.available: 15%
  nodefs.inodesFree: 5%
  imagefs.inodesFree: 5%
YAML
```

Replace release/repository placeholders, validate non-overlap for both overlay ranges, and tune reservations with the SME. These reservations are examples and apply cluster-wide through kubeadm's kubelet configuration. Retain extra control-plane capacity in DW01 scheduling/resource requests.

Do not configure `cloud-provider=external` in this baseline: there is no OCI cloud-controller-manager installed here. That flag without a working controller can leave nodes uninitialized. Automatic OCI LoadBalancer services and OCI dynamic block provisioning are not assumed.

## 11. Stage and verify bootstrap images — DW01 then all nodes

```bash
kubeadm config validate --config kubeadm.yaml
kubeadm config images list --config kubeadm.yaml
sudo kubeadm config images pull --config kubeadm.yaml
sudo crictl images
```

Expected: all requested image references are available through the approved registry/mirror. Offline: import exact matching archives on each node; image pull may be skipped only after the inventory is proven complete. Include CoreDNS subpaths and pause tags; do not assume kubeadm mirrors use the same layout as vendor charts.

## 12. Initialize the control plane — DW01 only

```bash
sudo kubeadm init --config kubeadm.yaml
```

Expected: initialization succeeds and emits a `kubeadm join` command. Treat that command's token as a credential: store securely, never paste into GitHub. If initialization fails, read the failing check and `journalctl -u kubelet`; do not repeatedly initialize over partial state.

```bash
mkdir -p "$HOME/.kube"
sudo install -m 0600 -o "$(id -u)" -g "$(id -g)" \
  /etc/kubernetes/admin.conf "$HOME/.kube/config"
kubectl get nodes -o wide
kubectl get pods -A
```

DW01 may be NotReady and CoreDNS Pending until the CNI is installed. Admin kubeconfig grants broad privileges; create scoped team credentials later.

## 13. Install pinned Flannel overlay — DW01 only

This guide selects Flannel VXLAN for minimal VCN IP consumption. Flannel alone does **not** enforce Kubernetes NetworkPolicy; namespaces alone do not isolate Dev/Test traffic.

1. Stage the pinned `kube-flannel.yml` from the official release.
2. Review its RBAC/privileged daemonset, Pod Security requirements, image references and checksums.
3. Confirm `net-conf.json` Network equals `10.244.0.0/16` and Backend Type is VXLAN.
4. If needed set the correct host interface and lower MTU for OCI plus VXLAN/inspection overhead; obtain the tested MTU from the network SME rather than copying jumbo defaults.
5. Rewrite all images to approved mirror references or pre-import the exact upstream references on all nodes.
6. Confirm the runtime CNI binary directory includes the required bridge, host-local, loopback and portmap plugins, not only the Flannel binary.

```bash
kubectl apply -f /srv/poc-artifacts/manifests/kube-flannel.yml
kubectl -n kube-flannel get daemonsets,pods -o wide
```

Pin the release manifest; do not `kubectl apply` a mutable master/latest URL. A compatible policy-enforcing CNI is a separate approved design change if Dev/Test traffic isolation is required.

## 14. Join DW02 and DW03 — each worker only

On DW01 generate a short-lived join command:

```bash
sudo kubeadm token create --ttl 30m --print-join-command
```

On each worker execute the exact generated command, adding the explicit runtime socket:

```bash
sudo kubeadm join dw01:6443 --token REPLACE_SHORT_LIVED_TOKEN \
  --discovery-token-ca-cert-hash sha256:REPLACE_CA_HASH \
  --cri-socket unix:///run/containerd/containerd.sock
```

Do not use `--discovery-token-unsafe-skip-ca-verification`. If the token expires, generate another. Expected: both nodes join without bypassing preflight checks.

## 15. Confirm three nodes — DW01

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl -n kube-system get configmap kubelet-config -o yaml
kubectl -n kube-system get configmap kubeadm-config -o yaml
```

Expect exactly dw01/dw02/dw03; all Ready; CoreDNS, kube-proxy and Flannel healthy. Expected normal roles: dw01 control-plane; dw02/dw03 no control-plane label. There is no fourth control-plane VM.

## 16. Decide whether DW01 also runs DataWalk pods — DW01

Default kubeadm control-plane taint prevents ordinary application pods on DW01. If two workers meet vendor sizing, retain that taint. If the agreed POC requires application capacity on all three VMs and DataWalk accepts the shared role:

```bash
kubectl describe node dw01
kubectl taint nodes dw01 node-role.kubernetes.io/control-plane:NoSchedule-
kubectl label node dw01 dw-poc-role=control-plane-and-worker
kubectl label node dw02 dw-poc-role=worker
kubectl label node dw03 dw-poc-role=worker
```

Reserve resources, define DataWalk CPU/memory requests/limits and monitor DW01. Removing the taint does not make the control plane highly available. If vendor requires three dedicated application workers plus a dedicated control plane, that requirement cannot fit this three-VM baseline; obtain vendor agreement or revise scope explicitly.

## 17. Create shared-cluster Dev/Test namespaces — DW01

```bash
kubectl create namespace dw-dev
kubectl create namespace dw-test
kubectl label namespace dw-dev poc-environment=dev
kubectl label namespace dw-test poc-environment=test
kubectl get namespaces
```

Use separate Helm release names, secrets, PVCs, databases/buckets and FQDNs for each environment. Have DataWalk confirm whether its chart supports two releases in one cluster, including uniqueness of any cluster-scoped resources. Assign scoped RBAC to team identities; do not distribute admin.conf. Set quotas/LimitRanges after vendor requests/limits are known, keeping combined requests within allocatable capacity.

## 18. Verify DNS, cross-node networking and egress — DW01

Use approved mirrored images containing the named utilities. Replace the two image variables with digest-pinned references. This check creates only disposable infrastructure test objects:

```bash
DIAG_IMAGE='REPLACE_REGISTRY/diag@sha256:REPLACE_DIGEST'
HTTP_IMAGE='REPLACE_REGISTRY/http-test@sha256:REPLACE_DIGEST'
kubectl -n dw-dev run net-server --image="$HTTP_IMAGE" --port=8080 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"dw02"}}}'
kubectl -n dw-dev run net-client --image="$DIAG_IMAGE" \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"dw03"}}}' \
  --command -- sleep 3600
kubectl -n dw-dev wait --for=condition=Ready pod/net-server pod/net-client --timeout=180s
kubectl -n dw-dev expose pod net-server --port=8080 --target-port=8080
kubectl -n dw-dev exec net-client -- nslookup kubernetes.default.svc.cluster.local
kubectl -n dw-dev exec net-client -- wget -qO- http://net-server:8080
```

The HTTP image must actually listen on 8080; use its documented arguments if needed. Also repeat using the server pod IP (`kubectl -n dw-dev get pod net-server -o wide`) to distinguish service-routing from overlay failure. Test approved internal DNS/HTTPS destinations, large payload/MTU behavior and access after host reboot. Restrict tests to authorized endpoints. If needed repeat with DW01 after enabling its worker role.

```bash
kubectl -n dw-dev delete service net-server
kubectl -n dw-dev delete pod net-server net-client
```

## 19. Make persistent storage an explicit readiness gate

A healthy kubeadm cluster does not automatically have a default StorageClass. This guide does not falsely claim that CSI/Decoupled Storage is installed.

1. Obtain DataWalk's exact requirements: Decoupled Storage backend/protocol, S3 compatibility if applicable, PVC access modes, capacity, latency/IOPS, topology and backup.
2. Choose the approved backend: existing enterprise NFS, supported OCI storage integration, or another vendor-approved provisioner. OCI Object Storage is not automatically a POSIX filesystem or an accepted DataWalk S3 backend.
3. Install the matching supported CSI/provisioner release using its own documented IAM/credentials, network, region/realm and node-topology setup. A self-managed OCI CSI path needs additional integration; do not copy OKE defaults blindly.
4. Stage driver/sidecar images and apply reviewed configuration. Protect credentials outside Git.
5. Confirm the StorageClass name and reclaim policy. Use retained volumes/backups where required; never assume Helm uninstall preserves data.

```bash
kubectl get csidrivers
kubectl get storageclasses
kubectl get pods -A -o wide
```

Create a 1Gi test PVC with the selected class and a diagnostic pod mounting it. Write a unique marker, delete only the pod, recreate against the same PVC, and read the marker. For shared/network storage test rescheduling across nodes as supported; for node-local storage document node affinity and lack of node-failure portability. Verify restore separately. **Do not proceed to DataWalk install until storage requirements and persistence checks pass.**

### Storage persistence test example — after the provisioner is ready

Create `storage-smoke.yaml`, replacing the StorageClass and diagnostic image before applying:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-smoke
  namespace: dw-dev
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: REPLACE_APPROVED_STORAGECLASS
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: storage-smoke
  namespace: dw-dev
spec:
  containers:
    - name: check
      image: REPLACE_APPROVED_REGISTRY/diag@sha256:REPLACE_DIGEST
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: storage-smoke
```

```bash
kubectl apply -f storage-smoke.yaml
kubectl -n dw-dev wait --for=condition=Ready pod/storage-smoke --timeout=300s
kubectl -n dw-dev exec storage-smoke -- sh -c 'echo poc-persistence-marker > /data/marker; sync'
kubectl -n dw-dev exec storage-smoke -- cat /data/marker
kubectl -n dw-dev delete pod storage-smoke --wait=true
kubectl apply -f storage-smoke.yaml
kubectl -n dw-dev wait --for=condition=Ready pod/storage-smoke --timeout=300s
kubectl -n dw-dev exec storage-smoke -- cat /data/marker
```

Expected: the marker survives pod recreation. This proves that PVC's persistence only; it does not prove backup, cross-node recovery or DataWalk storage compatibility. Retain evidence, then delete only this disposable test pod/PVC when authorized; PVC deletion can delete its underlying volume depending on reclaim policy. Do not reuse this test name for application data.

## 20. Install DataWalk only with the release package

The public container notice is not a release-specific Helm installation manual. Obtain the supported chart/schema, license, required secrets, image digests, sizing and migration instructions from DataWalk; no imaginary chart keys are supplied here.

On DW01 install a pinned Helm binary from approved artifacts, verify its checksum, then:

```bash
helm version
helm show chart /srv/poc-artifacts/datawalk/datawalk-APPROVED_VERSION.tgz
helm show values /srv/poc-artifacts/datawalk/datawalk-APPROVED_VERSION.tgz > dw-default-values.yaml
```

Create reviewed `dw-dev-values.yaml` and `dw-test-values.yaml` using the actual schema. Set separate environment identities, approved registry/pull-secret references, storage, TLS/private FQDNs, resources and anti-affinity. Do not put secret values in a public values file.

```bash
helm lint /srv/poc-artifacts/datawalk/datawalk-APPROVED_VERSION.tgz -f dw-dev-values.yaml
helm template dw-dev /srv/poc-artifacts/datawalk/datawalk-APPROVED_VERSION.tgz \
  -n dw-dev -f dw-dev-values.yaml > dw-dev-rendered.yaml
```

Review locally: images, namespaces, PVCs, service types, privileged/security settings, cluster-scoped objects and secrets. Rendered manifests can include secrets; retain them privately. Install using vendor-approved parameters:

```bash
helm upgrade --install dw-dev /srv/poc-artifacts/datawalk/datawalk-APPROVED_VERSION.tgz \
  --namespace dw-dev --values dw-dev-values.yaml --wait --timeout 20m
kubectl -n dw-dev get pods,services,pvc -o wide
helm status dw-dev -n dw-dev
```

Repeat for `dw-test` with its own values only after the first environment passes. `--wait` is a Kubernetes readiness check, not proof of application acceptance. In this baseline a LoadBalancer service may stay Pending because no OCI cloud controller exists. Use a reviewed private ingress/LB with explicitly chosen NodePorts or add supported OCI integration as a separate platform task. For temporary authorized operator access use `kubectl port-forward` to the actual chart service/port and preserve localhost binding/SSH tunneling.

Migrate sanitized demo data using DataWalk's supported export/restore procedure. Staging the database export through jump host/Object Storage can proceed in parallel with cluster build. Record checksums, object scope and restore validation; do not copy live database files without vendor instructions.

## 21. Kubernetes acceptance and recovery — platform + DataWalk

Record three Ready nodes, image versions, DNS/cross-node tests, storage persistence, private TLS, separate Dev/Test releases, vendor regression results and resource headroom. Keep infrastructure acceptance separate from application acceptance.

Back up `/etc/kubernetes` PKI/configuration securely, a version-matched etcd snapshot using the installed etcd tools and TLS credentials, application-consistent DataWalk data and storage snapshots. Validate an isolated restore before claiming recoverability. Check certificates with `sudo kubeadm certs check-expiration`.

| Symptom | First checks |
|---|---|
| NotReady | kubelet/containerd logs, CRI config, CNI image availability |
| CoreDNS Pending | CNI health, taints, resource availability |
| ImagePullBackOff | Exact reference, registry CA/auth, routing; Podman pull success does not prove containerd auth |
| Node join timeout | DW01 TCP 6443, hostname resolution, CA hash/token, time |
| Pod IP works but service fails | kube-proxy, ClusterIP CIDR, host forwarding |
| Cross-node traffic fails | UDP 8472, MTU, bridge modules, firewall forwarding |
| PVC Pending | No provisioner/class, IAM, storage quota/topology/access mode |
| LoadBalancer Pending | No cloud controller/LB integration in baseline |

Do not run `kubeadm reset` as routine troubleshooting. It removes local cluster state and requires an explicit node-rebuild decision. Avoid draining DW01 or deleting PVCs as a connectivity test.

## 22. Prepare the Hyperscience GPU VM — HS01 only

Do not join HS01 to the DataWalk cluster. The baseline is one RHEL GPU application VM; it does not provision a second trainer or GPU VM.

```bash
cat /etc/redhat-release
uname -r
lscpu
free -h
lsblk -f
df -hT
lspci | grep -i nvidia
chronyc tracking
```

Confirm A10.2's two physical GPU devices are visible and the approved RHEL image/kernel supports the driver. Two GPUs inside one VM do not mean two RHEL VM instances. Confirm package entitlements and the private FQDN/HTTPS URL required for licensing.

Check space separately for bundle download/extraction, image graphroot and application/model data. For the previously proposed v43.2/ORCA deployment budget at least 400 GB application baseline plus 100 GB ORCA allowance and operational headroom; reconfirm the release-specific requirement with Hyperscience. Do not count one filesystem's free space twice for concurrent extraction/image loading. `/dev/shm` is RAM-backed, not disk.

## 23. Install supported Podman — HS01 only

Inspect the RHEL container-tools stream; select the Hyperscience-supported version, not automatically the newest stream:

```bash
sudo dnf module list container-tools
sudo dnf list --showduplicates podman
sudo dnf install -y podman container-selinux skopeo
podman --version
sudo podman info --debug
```

Where a specific supported stream is required, have the RHEL operator enable that stream before package install. Do not reset/change a stream on a host already running containers without a migration plan. Rootless and rootful Podman have separate storage/containers/authentication; this guide uses **rootful** commands consistently pending the vendor bundle's requirements.

Podman is daemonless: no Docker daemon or `systemctl enable podman` is required to run local containers. Do not expose the Podman socket over TCP. Vendor application autostart must use its supplied supported service/Quadlet/systemd procedure.

## 24. Confirm Podman storage and trust — HS01

```bash
sudo podman info --format '{{.Store.GraphRoot}}'
sudo podman info --format '{{.Store.RunRoot}}'
sudo podman images
sudo podman ps -a
sudo cat /etc/containers/storage.conf
```

If relocating graphroot, do it before loading images. Mount the approved filesystem by UUID, retain correct ownership and apply persistent SELinux labels. Example only for an empty dedicated mount `/srv/containers`, after the mount is prepared:

```bash
sudo semanage fcontext -a -e /var/lib/containers/storage /srv/containers
sudo restorecon -Rv /srv/containers
sudoedit /etc/containers/storage.conf
```

Set `graphroot = "/srv/containers"` under the existing `[storage]` section; retain the vendor/RHEL-supported storage driver/options. `semanage` comes from policycoreutils-python-utils if not installed. Do not format an unidentified block device or migrate a live graphroot by copying these commands.

Install enterprise CA certificates under the approved trust workflow. For a private registry, configure the appropriate `/etc/containers/certs.d/REGISTRY_HOST[:PORT]/ca.crt`; use trusted TLS, not insecure-registry flags. Authenticate interactively with `sudo podman login REGISTRY_HOST` only if required. Protect root's authfile; do not put passwords on command lines or in Git.

## 25. Install and validate NVIDIA host driver — HS01

First check existing installation:

```bash
nvidia-smi
rpm -qa | grep -Ei 'nvidia|cuda'
lsmod | grep -E 'nvidia|nouveau'
```

If the driver works and meets the selected HS release requirement, retain it. Otherwise:

1. Obtain the RHEL8/x86_64 driver RPM repository or offline dependency bundle approved for the actual kernel and A10.
2. Select the vendor-required driver branch; the earlier v43.2/ORCA plan calls for driver >=580, which must be reconfirmed for the delivered bundle.
3. Follow NVIDIA's RHEL driver guide to choose its supported precompiled/DKMS method and any necessary kernel-devel/header packages. Secure Boot/module signing, nouveau handling and rebuild requirements depend on that method.
4. Install exact approved driver package NEVRAs through the mirror; do not combine RPM and `.run` installations.
5. Reboot during the change window and verify:

```bash
uname -r
nvidia-smi
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
```

Expected: both A10 devices, no driver/library mismatch, appropriate per-GPU VRAM and driver version. Do not claim that 2 x 24GB devices automatically form one 48GB GPU.

## 26. Install NVIDIA Container Toolkit — HS01

Install the pinned toolkit from the approved signed mirror/offline RPM set:

```bash
sudo dnf install -y nvidia-container-toolkit
nvidia-ctk --version
```

NVIDIA's public repository configuration (only if approved online access is permitted) is documented in the official installation guide. The private POC default is mirrored packages, including libnvidia-container dependencies; Service Gateway alone cannot download them.

There are **two GPU exposure paths**. Use the one supported by the actual Podman version and Hyperscience installer. Do not blindly mix legacy OCI hooks, NVIDIA_VISIBLE_DEVICES settings and CDI.

### CDI path — when supported by installed Podman and the HS package

NVIDIA recommends CDI for Podman. Confirm the installed version supports `--device nvidia.com/gpu=all`. Generate an inventory if the toolkit's automatic refresh service is unavailable:

```bash
sudo install -d -m 0755 /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
sudo nvidia-ctk cdi list
```

Review existing `/usr/share/containers/oci/hooks.d/oci-nvidia-hook.json` if present: the legacy hook can conflict with CDI. Back up and disable it only when moving this host entirely to a vendor-approved CDI path. Regenerate/recheck CDI after driver/device changes; do not create conflicting manual and automatic CDI specifications.

```bash
CUDA_TEST_IMAGE='REPLACE_APPROVED_REGISTRY/cuda@sha256:REPLACE_DIGEST'
sudo podman run --rm --device nvidia.com/gpu=all \
  --security-opt=label=disable "$CUDA_TEST_IMAGE" nvidia-smi
```

The label exception is limited to this reviewed diagnostic invocation; do not globally disable SELinux. Expect container output to identify the same host GPUs. This proves GPU access, not HS model operation. Repeat with one selected CDI device only if the vendor requires assignment of a specific GPU.

### Legacy vendor path — if the delivered HS guide requires NVIDIA OCI runtime/hooks

Use the exact Hyperscience RHEL8 Podman GPU procedure for that release. It may use NVIDIA OCI runtime and environment settings rather than CDI. Do not run Docker-only `nvidia-ctk runtime configure --runtime=docker` on this Podman-only host. Confirm GPU access using the vendor's exact test before proceeding. The HS public pages returned HTTP 403 during this guide's refresh; release-specific runtime/configuration commands therefore remain vendor-supplied, not fabricated here.

## 27. Validate shared memory and basic Podman operation — HS01

```bash
df -h /dev/shm
findmnt /dev/shm
```

For the proposed ORCA release confirm at least 10GiB host shared-memory availability and the application's required container `/dev/shm` setting. If necessary, adjust the existing `/dev/shm` mount through the RHEL-supported mount/fstab configuration during the approved window. The host size alone does not enlarge a container's default shared memory.

Using the approved diagnostic image:

```bash
DIAG_IMAGE='REPLACE_APPROVED_REGISTRY/diag@sha256:REPLACE_DIGEST'
sudo podman run --rm --shm-size=10g "$DIAG_IMAGE" df -h /dev/shm
```

Expected: container reports approximately 10GiB. This is a runtime test; translate the setting into the actual supported HS installer/service configuration rather than replacing its launcher with an ad hoc `podman run`.

## 28. Load Hyperscience artifacts and hand off application installation

```bash
cd /srv/poc-artifacts/hyperscience
sha256sum -c SHA256SUMS
sudo podman load -i APPROVED_VENDOR_IMAGE_ARCHIVE.tar
sudo podman images --digests
```

Run the load command only for files the vendor identifies as Podman/Docker image archives. An entire application bundle may require its own extraction/import procedure instead. Do not unpack or run unreviewed executables as root.

With Chase/the authorized application operator:

1. Confirm the exact TVE/standard bundle, release, supported Podman GPU mode and application roles.
2. Follow the official Docker/Podman sequence and supplied launcher, including role such as `VISION_LANGUAGE_MODEL_GPU` only where that release instructs it.
3. Configure the final private HTTPS URL, certificate, model assets, image storage and shared memory.
4. Obtain/apply the license for that final instance URL using the vendor workflow; keep license contents outside Git.
5. Import flows/layouts/models through supported export/import, not a VM migration.
6. Configure the vendor-supported application restart service and verify after reboot.
7. Decide whether the agreed test cases require a separate Trainer. The one-GPU-VM POC does not assume the Trainer can share this VM, nor silently provision a second VM. Obtain a vendor-supported scope/configuration before trainer-dependent tests.

```bash
sudo podman ps --format '{{.Names}} {{.Status}} {{.Ports}}'
sudo podman logs --tail 100 REPLACE_ACTUAL_CONTAINER_NAME
nvidia-smi
```

Do not publish logs containing tokens, document contents or personal data. Confirm private HTTPS, licensed UI, GPU document processing, resource consumption and application restart. A successful CUDA test alone is not application acceptance.

## 29. Final evidence and completion checklist

| Gate | Required evidence | Status before execution |
|---|---|---|
| Network/IPAM | Approved node IPs, pod/service non-overlap, routes, firewall/MTU | Unverified |
| Package compatibility | Vendor-approved version matrix, kernel/runtime compatibility | Pending confirmation |
| DW platform | Exactly three Ready nodes; role decision recorded | Unverified |
| DW isolation | Separate Dev/Test credentials/data; accepted shared boundary | Unverified |
| DW storage/application | Persistence/restore, chart support, vendor tests | Unverified |
| HS runtime | Podman storage, host/container GPU checks, shared memory | Unverified |
| HS application | License/private URL, models, restart, trainer-scope decision | Unverified |
| Recovery | Secure etcd/application backups and restore evidence | Unverified |

This guide provides operator steps; no commands have been executed against the OCI POC. Mark infrastructure and application acceptance separately after execution. Never turn an unexecuted checklist into a completed deployment status.

## Official references and source limits

- [Kubernetes: install kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) — version-specific repositories, runtime/preflight requirements.
- [Kubernetes: create a kubeadm cluster](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/) — init/join, CNI, control-plane scheduling.
- [Kubernetes: container runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/) — CRI and matching systemd cgroups; consult selected release.
- [Kubernetes: ports and protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/).
- [Flannel: Kubernetes deployment](https://github.com/flannel-io/flannel/blob/master/Documentation/kubernetes.md) — pin an approved release before execution.
- [NVIDIA: Container Toolkit installation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) — packages and Podman CDI recommendation.
- [NVIDIA: CDI support](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html).
- [NVIDIA: driver installation](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/index.html).
- [Red Hat: RHEL 8 containers documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/building_running_and_managing_containers/index).
- [Hyperscience: Docker/Podman](https://help.hyperscience.ai/deployment/docs/docker-podman).
- [Hyperscience: Podman GPU machines](https://help.hyperscience.ai/deployment/docs/enabling-application-machines-with-gpus-in-on-premise-podman-deployments).
- [Hyperscience: infrastructure requirements](https://help.hyperscience.ai/deployment/docs/infrastructure-requirements).
- [DataWalk: preparing for containers](https://datawalk.com/preparing-for-datawalk-on-containers/).

Kubernetes installation and NVIDIA Toolkit documentation were retrieved directly during this revision; Hyperscience pages denied access. Current vendor certification, release-specific HS installer commands and DataWalk chart values must come from the delivered vendor documentation. This is not a claim of live deployment or vendor certification.
