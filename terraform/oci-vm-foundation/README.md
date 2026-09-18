# OCI VM Foundation (Resource Manager stack)

Self-contained Terraform for a private-only VM foundation on OCI, intended to be
run as an **Oracle Resource Manager (ORM)** stack sourced directly from this
GitHub repository.

Unlike the upstream `oracle-terraform-modules/terraform-oci-compute-instance`
module — which expects an **existing** subnet — this configuration builds the
network itself.

## What it creates

| Area | Resources |
|---|---|
| Network | New VCN, private subnet (`prohibit_public_ip_on_vnic = true`), route table, empty security list |
| Egress to Oracle services | Service gateway + route to the regional Oracle Services Network, NSG egress on TCP/443 |
| Hybrid (optional) | DRG attachment to an **existing** DRG, plus explicit routes to approved on-prem CIDRs |
| Security | NSG allowing SSH **only** from the approved jump-host CIDR, metadata DNS/NTP egress, ICMP type 3 code 4 for path-MTU discovery |
| Compute | 1..N VMs — `VM.Standard.E6.Flex` (DataWalk) or `VM.GPU.A10.2` (Hyperscience), optional block volume per VM |

**No public IPs, no internet gateway, no NAT gateway, no unrestricted internet egress.**

## What it does not do

- No Kubernetes, no application install, no GPU drivers, no OS hardening, no backups, no monitoring.
- FastConnect, shared DRG route import/export, on-prem return routes, and firewall
  approvals remain **network-team prerequisites**. Attaching the DRG alone does not
  establish end-to-end connectivity.

## Running it from ORM

### Option A — ZIP upload (no GitHub link needed)

[`oci-vm-poc.zip`](./oci-vm-poc.zip) in this folder is pre-built and ready to upload —
`main.tf` sits at the archive root, which is what ORM requires.

1. Download `oci-vm-poc.zip` from this folder (use the file's **Download** button on
   GitHub, not "Download repository ZIP" — that wraps everything in a `dwhs-main/`
   folder and breaks the upload).
2. OCI Console → **Developer Services → Resource Manager → Stacks → Create stack**.
3. Origin: **My configuration** → Stack configuration: **.zip file** → select
   `oci-vm-poc.zip`.
4. Select a Terraform version **≥ 1.2** (the config requires `lifecycle { precondition }`).
5. Name the stack and pick the compartment the *stack* lives in (separate from
   `compartment_ocid` below, which is where the VMs are created).
6. Fill in the variables below, then **Plan** → review resources and cost → **Apply**.

> Use a **separate stack per application/environment**. Each stack creates a new VCN,
> so allocate approved, non-overlapping CIDRs.

Updating the config later means re-uploading a new ZIP under the stack's
**Edit → Stack configuration** — there's no auto-pull with this option.

To rebuild the ZIP yourself after editing `main.tf` (run from this directory):

```powershell
Compress-Archive -Path .\main.tf -DestinationPath .\oci-vm-poc.zip -Force
```

### Option B — source directly from this GitHub repository

1. In the OCI Console: **Developer Services → Resource Manager → Configuration Source Providers** —
   add a GitHub provider with a personal access token that can read this repository.
2. **Resource Manager → Stacks → Create stack → Source code control system**.
3. Select the configuration source provider, repository `oci-appdev/dwhs`, the branch
   you want, and set the **working directory** to:

   ```
   terraform/oci-vm-foundation
   ```

4. Select a Terraform version **≥ 1.2**.
5. Fill in the variables below, then **Plan** → review resources and cost → **Apply**.

This option auto-pulls on **Update Stack** when the source branch changes — useful if
you're iterating on `main.tf` directly in the repo.

## Variables

### Required

| Variable | Notes |
|---|---|
| `region` | e.g. `us-ashburn-1` |
| `compartment_ocid` | Target compartment |
| `availability_domain` | Full AD name, e.g. `kIdk:US-ASHBURN-AD-1` |
| `image_ocid` | Regional image OCID, compatible with the chosen shape |
| `ssh_public_key` | Public key text, not a path |
| `vcn_cidr` | Approved, non-overlapping |
| `subnet_cidr` | Within `vcn_cidr` |
| `admin_cidr` | Jump-host CIDR; prefer a `/32`. A `/0` is rejected by validation. |

### Optional

| Variable | Default | Notes |
|---|---|---|
| `name` | `dw-poc` | Prefix for display names and freeform tags |
| `shape` | `VM.Standard.E6.Flex` | Or `VM.GPU.A10.2` |
| `instance_count` | `1` | Positive integer |
| `flex_ocpus` | `8` | **OCPUs, not vCPUs.** Ignored for the fixed-shape A10.2. |
| `flex_memory_gb` | `128` | Ignored for A10.2 |
| `boot_volume_gb` | `100` | OCI minimum is 50 |
| `data_volume_gb` | `0` | `0` disables data volumes. If set, OCI's minimum volume size is 50 GB. |
| `data_volume_vpus` | `20` | VPUs/GB (20 = balanced) |
| `drg_ocid` | `""` | Empty = isolated deployment |
| `drg_route_table_ocid` | `""` | Required when `drg_ocid` is set |
| `onprem_cidrs` | `[]` | Explicit destination CIDRs reached via the DRG. Default routes are rejected. |
| `extra_rules` | `{}` | See below |

The sizing defaults are **illustrative, not vendor-approved**. Confirm shape capacity,
image compatibility, and vendor sizing before applying.

### `extra_rules`

One destination port per entry. `protocol`: `"6"` = TCP, `"17"` = UDP.

```json
{
  "application_https": {
    "direction": "INGRESS",
    "protocol": "6",
    "cidr": "10.20.30.0/24",
    "port": 443
  }
}
```

Replace the example CIDR with your own, and add vendor-required cluster ports and
approved proxy access explicitly.

**Two things `extra_rules` is needed for, by design:**

- **Node-to-node traffic.** The baseline NSG has no intra-subnet allow rule, so with
  `instance_count > 1` the VMs cannot reach each other until you add rules using the
  subnet CIDR. Kubernetes and clustered vendor components will need this.
- **On-prem egress.** Routes to `onprem_cidrs` are installed in the route table, but
  the NSG has no egress rule to them. Traffic the VMs *initiate* toward on-prem
  (AD, DNS, package repos, vendor licence servers) needs explicit `EGRESS` entries.
  Inbound SSH replies are fine — those rules are stateful.

## Outputs

- `private_ips` — private IP of each VM
- `instance_ids` — instance OCIDs
- `network` — `vcn_id`, `subnet_id`, `nsg_id`

## Provider version

Pinned to `oracle/oci ~> 8.29`. If `terraform init` reports that no matching version
exists, adjust the constraint in `main.tf` to the provider version available to your
tenancy's Terraform runtime.
