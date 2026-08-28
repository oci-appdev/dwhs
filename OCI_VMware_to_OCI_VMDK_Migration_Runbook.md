# OCI VMware → OCI VMDK Migration Runbook

**Repository:** `oci-appdev/dwhs`  
**Environment:** OCI Government Cloud / CREAM OCI landing zone  
**Purpose:** Repeatable guest-OS preparation, VMware VMDK export, OCI Object Storage transfer, custom-image import, first-boot validation, and migration-wave execution  
**Updated:** August 28, 2026

---

## 1. Executive Summary

This runbook captures the VMware → OCI VM migration procedure reconstructed during the August 28, 2026 migration/GPU POC working session.

The most important finding from the meeting was the recovery of a **previously prepared, known-good VM** that still contains the OCI-ready guest configuration used during the earlier successful migration. That VM should be treated as the **golden migration reference**.

Do **not** begin by exporting all remaining VMs.

Use the recovered OCI-ready VM to prove the process end to end:

```text
Validate golden VM
        ↓
Reach internal remediation target (~90%)
        ↓
Prepare guest OS for OCI
        ↓
Clean shutdown
        ↓
Export single supported VMDK
        ↓
Upload to OCI Object Storage
        ↓
Import as OCI Custom Image
        ↓
Launch ONE test instance
        ↓
Validate boot + DHCP + SSH + DNS + NTP
        ↓
Rebuild OCI-side dependencies
        ↓
Document evidence/results
        ↓
Repeat for remaining VMs
```

The guiding principle is:

> **The source VM must be capable of booting successfully when completely disconnected from its existing on-premises environment.**

Anything that requires the old static IP, default gateway, MAC address, DNS path, NFS share, attached data disk, startup service, or another on-premises dependency can prevent a successful first OCI boot.

---

## 2. Scope

This runbook covers:

- VMware guest preparation before export
- Linux networking changes required for OCI
- DHCP conversion
- Static-IP and gateway cleanup
- NTP validation/reconfiguration
- NFS and remote mount cleanup
- Boot-dependency validation
- VMDK export requirements
- VMDK upload to OCI Object Storage
- OCI custom-image import
- Launch-mode selection
- First OCI boot validation
- SSH validation
- OCI-specific post-migration configuration
- Comparison against previously working VMDKs/custom images
- Migration-wave rollout for the remaining VMs
- Compartment-move precautions for existing OCI resources

The A10 GPU / OKE POC discussed in the same meeting is related program work, but it is not part of the VMDK execution path. A short coordination note is included at the end of this document.

---

# PART I — SOURCE VM READINESS

## 3. Golden Reference VM

A previously prepared VM was recovered during the working session. The machine still contains the OCI-related guest changes from the earlier migration.

Treat this system as the authoritative **known-good reference** until the fresh migration test completes.

### Required actions

- [ ] Confirm the recovered VM is the machine previously prepared for OCI.
- [ ] Confirm its current remediation/security state.
- [ ] Ask Vivek to verify whether any additional guest-OS preparation was performed previously.
- [ ] Record the current network configuration.
- [ ] Record DHCP configuration.
- [ ] Record routing/default-gateway behavior.
- [ ] Record DNS configuration.
- [ ] Record NTP/chrony configuration.
- [ ] Record `/etc/fstab` and active NFS mounts.
- [ ] Record enabled startup services.
- [ ] Record bootloader/storage configuration.
- [ ] Record installed OCI/cloud-init tooling, if present.
- [ ] Preserve screenshots or command output as migration evidence.

### Golden-image comparison strategy

If the new migration fails, compare the failing VM against all available known-good artifacts:

1. Recovered OCI-ready source VM
2. Previously working VMDK in Object Storage
3. Previously imported OCI Custom Image
4. Current source VM guest configuration
5. Newly exported VMDK
6. New OCI image-import settings
7. Launch-mode settings
8. First-boot console output

This avoids reconstructing a two-year-old process from memory.

---

## 4. Internal Security Remediation Gate

The VM team stated an internal target of approximately **90% remediation** before migration.

This is a **program readiness target**, not an OCI VMDK-format requirement.

Before export:

- [ ] Current remediation score reviewed.
- [ ] Target approximately 90% reached or exception approved.
- [ ] Critical boot/network fixes are not deferred merely to improve the security score.
- [ ] Outstanding findings documented.
- [ ] Security team/VM owner agrees the system may be exported.

Do not allow remediation work to introduce new boot dependencies immediately before export without retesting.

---

# PART II — OCI HARD PREREQUISITES

## 5. OCI Custom Linux Image Requirements

For Linux custom-image import, Oracle currently requires the source image to meet the following key conditions.

### Hard gates

- [ ] Image size is within OCI's supported limit.
- [ ] Image is configured for supported BIOS boot requirements for this import path.
- [ ] There is **one boot disk** in the imported image.
- [ ] The system can boot without requiring additional data volumes.
- [ ] The boot loader identifies the boot volume with a supported persistent method such as UUID/LVM rather than a fragile device assumption.
- [ ] The disk image itself is not encrypted in an unsupported way for image import.
- [ ] VMDK is a supported **single-file** format.
- [ ] Network interface obtains configuration using **DHCP**.
- [ ] Network configuration does not hard-code the source VMware MAC address.

### Supported VMDK characteristics

OCI supports VMDK imports when the VMDK is a single file using a supported layout such as:

- `monolithicSparse`
- `streamOptimized`

Do not upload a VMware snapshot chain, split disk set, descriptor plus dependent snapshot chain, or other multi-file disk representation and assume OCI will reconstruct it.

Oracle reference:

- https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimagelinux.htm
- https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/custom-images-import.htm
- https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/imageimportexport.htm

---

# PART III — GUEST OS PREPARATION

## 6. Capture the Pre-Change State

Before changing the source VM, capture enough information to reverse the preparation if necessary.

For a RHEL-family Linux guest, collect at minimum:

```bash
hostnamectl
uname -a
cat /etc/redhat-release 2>/dev/null || true
ip addr
ip route
nmcli connection show
nmcli device status
cat /etc/resolv.conf
chronyc sources -v 2>/dev/null || true
chronyc tracking 2>/dev/null || true
findmnt
findmnt -t nfs,nfs4 2>/dev/null || true
cat /etc/fstab
lsblk -f
blkid
systemctl --failed
```

Save the output with the VM name and date.

Recommended naming:

```text
<vm-name>_pre-oci-migration_YYYYMMDD.txt
```

---

## 7. Primary NIC Must Use DHCP

This was the key preparation item remembered from the prior successful migration.

The old machine was specifically configured so the primary interface could obtain OCI network configuration automatically on first boot.

The interface may be named `eth0`, `ens3`, `ens160`, or something else depending on the guest OS. The requirement is about the **primary OCI-facing NIC**, not the literal interface name.

### Inspect NetworkManager

```bash
nmcli connection show
nmcli device status
ip addr
ip route
```

Identify the active connection profile attached to the primary interface.

### Convert the connection to DHCP

Example for NetworkManager-managed RHEL systems:

```bash
sudo nmcli connection modify "<CONNECTION_NAME>" \
  ipv4.method auto \
  ipv4.addresses "" \
  ipv4.gateway ""
```

If DNS was statically bound to the on-premises network and DHCP should provide OCI DNS during first boot, remove the old profile-level DNS entries as appropriate for the environment.

Then verify:

```bash
nmcli connection show "<CONNECTION_NAME>"
```

Expected intent:

```text
ipv4.method: auto
No required on-prem static IPv4 address
No required on-prem static default gateway
No source-VMware MAC binding
```

### Important

Do not restart networking on a remotely administered source VM until the team has console access and understands the consequence. A DHCP conversion can immediately break the current management session.

The team may choose to stage the changes and activate them only immediately before shutdown/export.

---

## 8. Remove Hard-Coded Static IP Configuration

Search common RHEL configuration locations for old IP data.

Examples:

```bash
sudo grep -RniE 'IPADDR|PREFIX|NETMASK|GATEWAY|DNS[0-9]*|HWADDR|MACADDR' \
  /etc/sysconfig/network-scripts /etc/NetworkManager 2>/dev/null
```

Also search for the known old IP address or gateway directly:

```bash
sudo grep -Rni '<OLD_IP_OR_GATEWAY>' /etc 2>/dev/null
```

Review before modifying files.

Remove or neutralize settings that would force the guest to reuse the old on-premises address after import.

### Validation

- [ ] No required static IPv4 address remains on the primary NIC.
- [ ] No required old default gateway remains.
- [ ] No hard-coded source MAC address remains.
- [ ] No boot script re-adds the old IP.
- [ ] No custom route script assumes the old subnet.

---

## 9. Remove Hard-Coded Default Gateway and On-Prem Routes

Inspect:

```bash
ip route
nmcli connection show "<CONNECTION_NAME>"
```

Look for:

- old default gateway
- persistent static routes
- source data-center networks
- backup networks
- management VLANs
- routes added by startup scripts

The first OCI boot should receive the relevant OCI subnet/default-route behavior through the OCI VNIC/DHCP environment rather than forcing the old VMware network topology.

### Gate

- [ ] No old default gateway is required for boot.
- [ ] No static route is required merely to reach an on-prem boot service.
- [ ] Any route that will still be required after migration is documented for OCI-side recreation.

---

## 10. DNS Dependency Review

A VM can successfully obtain an IP in OCI and still fail operationally because boot scripts or services depend on an old DNS server.

Inspect:

```bash
cat /etc/resolv.conf
nmcli dev show | grep -i dns
sudo grep -RniE 'nameserver|search|domain' /etc/NetworkManager /etc/sysconfig 2>/dev/null
```

Document:

- current DNS servers
- search suffixes
- application-specific hostnames
- LDAP/AD dependencies
- database hostnames
- NFS server names
- package repository names
- monitoring/logging endpoints

Decide which names must be reachable over FastConnect after migration and which should be replaced with OCI-local services.

---

## 11. NTP / Time Synchronization

The meeting confirmed that NTP was one of the guest settings changed during the previous migration.

Inspect the current configuration:

```bash
chronyc sources -v
chronyc tracking
sudo grep -RniE 'server|pool' /etc/chrony.conf /etc/chrony.d 2>/dev/null
```

The goal is to ensure the guest does not require an unreachable on-premises time source to initialize correctly in OCI.

### Preparation

- [ ] Record current NTP sources.
- [ ] Identify any on-prem-only NTP server.
- [ ] Confirm the approved OCI/enterprise time source for the target landing zone.
- [ ] Remove or replace unreachable sources before final cutover or during first-boot configuration.
- [ ] Verify time synchronization after the OCI instance launches.

After launch:

```bash
chronyc sources -v
chronyc tracking
```

Do not consider the migration complete if the system clock is unsynchronized.

---

## 12. NFS and Network Mounts

The source environment contains NFS mounts used for backups and other purposes. Those mounts are a significant first-boot risk.

Inspect:

```bash
findmnt -t nfs,nfs4
mount | grep -Ei ' type nfs| type nfs4'
grep -Ev '^\s*#|^\s*$' /etc/fstab
```

For each remote mount, determine:

| Mount | Server | Needed for OS boot? | Needed for app? | Reachable from OCI? | First-boot action |
|---|---|---:|---:|---:|---|
| Example `/backup` | `nfs01` | No | Yes | TBD | Disable for first boot; rebuild later |

### Safe first-boot rule

If the mount is not absolutely required to start the operating system, it should not be allowed to block OCI first boot.

Possible actions after review:

- temporarily comment the entry
- disable the dependent service
- use approved non-blocking mount options where appropriate
- recreate the share using OCI File Storage
- retain the on-prem NFS path over FastConnect after connectivity validation

Do not blindly modify `/etc/fstab`. Preserve a backup and review dependencies first.

Example backup:

```bash
sudo cp -a /etc/fstab /etc/fstab.pre-oci-$(date +%Y%m%d)
```

### Gate

- [ ] No unavailable NFS mount can block first boot.
- [ ] Backup mounts are disabled or made non-blocking for first boot.
- [ ] Application dependencies on NFS are documented.
- [ ] Reconnection/rebuild plan exists for required mounts.

---

## 13. Attached Disk / Boot Dependency Review

OCI custom-image import is intended to import the boot disk. The operating system must not require other VMware data disks merely to boot successfully.

Inspect:

```bash
lsblk -f
blkid
cat /etc/fstab
```

Check for:

- application data disks
- swap devices
- LVM volumes spanning multiple virtual disks
- boot-critical mount points on secondary disks
- hard-coded `/dev/sdX` device references
- startup scripts requiring secondary volumes

### Gate

- [ ] Boot volume is self-contained.
- [ ] Boot does not fail when data volumes are absent.
- [ ] Secondary data disks have a separate migration plan.
- [ ] Boot-critical mounts do not point to volumes that will not exist in the imported image.

---

## 14. Startup Services and On-Prem Dependencies

Search for services likely to block, hang, or repeatedly fail when the VM is no longer on premises.

Review:

```bash
systemctl --failed
systemctl list-unit-files --state=enabled
systemctl list-dependencies multi-user.target
```

Investigate services tied to:

- NFS
- SMB/CIFS
- LDAP/AD
- old DNS servers
- backup agents
- monitoring agents
- database listeners/clients
- license servers
- application clustering
- external storage
- static network routes
- startup shell scripts

Search custom startup files as appropriate:

```bash
sudo grep -RniE 'mount|nfs|route|ip addr|ifconfig|nmcli|systemctl|service' \
  /etc/rc.d /etc/systemd/system /usr/local 2>/dev/null
```

### Principle

The first goal in OCI is not full application functionality.

The first goal is:

> **Boot the OS cleanly enough to obtain OCI networking and establish administrative access.**

Application integrations can be rebuilt after that point.

---

## 15. SSH / Administrative Access Readiness

Before export, verify the guest has a viable administrative access path after migration.

- [ ] `sshd` enabled.
- [ ] Local admin account known.
- [ ] Authentication method approved.
- [ ] `cloud-init` status reviewed if SSH-key injection is expected.
- [ ] Host firewall will allow the approved management path.
- [ ] OCI subnet/NSG/security-list path for SSH is planned.
- [ ] OCI Bastion or private management path is available if direct SSH is not permitted.

Checks:

```bash
systemctl is-enabled sshd
systemctl status sshd --no-pager
ss -lntp | grep ':22'
cloud-init status 2>/dev/null || true
```

Do not depend on public SSH if the landing-zone design requires private-only administration.

---

## 16. Final Source VM Pre-Export Checklist

Before shutdown:

- [ ] Golden reference comparison completed.
- [ ] Internal remediation target satisfied/accepted.
- [ ] Primary NIC prepared for DHCP.
- [ ] Static IP removed/staged for removal.
- [ ] Old default gateway removed/staged for removal.
- [ ] Hard-coded MAC bindings removed.
- [ ] DNS dependencies documented.
- [ ] NTP dependencies documented/reconfigured.
- [ ] NFS mounts cannot block first boot.
- [ ] Secondary disks are not required for OS boot.
- [ ] Startup dependencies reviewed.
- [ ] SSH/admin access path validated.
- [ ] Host firewall implications documented.
- [ ] Current config evidence saved.
- [ ] Clean snapshot/rollback method exists on VMware side if allowed by local policy.
- [ ] VM owner approves shutdown.

---

# PART IV — VMWARE EXPORT

## 17. Clean Shutdown

Perform a controlled guest shutdown rather than exporting a live, changing system.

Example:

```bash
sudo shutdown -h now
```

In VMware verify the VM is fully powered off before producing the migration artifact.

Do not treat a VMware snapshot chain itself as the OCI import artifact.

---

## 18. Export the VM as VMDK

Export/clone the source boot disk into a **single OCI-supported VMDK**.

### Required result

```text
One boot-disk VMDK
Supported single-file VMDK layout
No active snapshot chain dependency
No split disk set
No additional boot-required disks
```

Recommended artifact naming:

```text
<vm-name>_oci_<YYYYMMDD>.vmdk
```

Example:

```text
app01_oci_20260828.vmdk
```

### Record

- VM name
- source vCenter/cluster
- source OS/version
- export date/time
- source boot-disk size
- VMDK size
- export method
- checksum
- operator

Generate a checksum after the file is finalized:

```bash
sha256sum <vm-name>_oci_<YYYYMMDD>.vmdk
```

Save it:

```bash
sha256sum <vm-name>_oci_<YYYYMMDD>.vmdk > <vm-name>_oci_<YYYYMMDD>.vmdk.sha256
```

---

# PART V — TRANSFER TO OCI OBJECT STORAGE

## 19. Select the Target Bucket

For each migration, identify:

```text
OCI region:
OCI compartment:
Object Storage namespace:
Bucket:
Object name:
```

The meeting confirmed that older successful VMDKs still appear to exist in the current Object Storage environment. Preserve those files as known-good troubleshooting references.

Do not overwrite them.

Use a distinct object name for each new attempt.

---

## 20. Upload Using OCI CLI

The team previously used CLI transfer because browser-based transfer was less reliable. With FastConnect available, the same CLI method remains appropriate and repeatable.

Basic OCI CLI upload:

```bash
oci os object put \
  --bucket-name "<BUCKET_NAME>" \
  --file "<PATH_TO_VMDK>" \
  --name "<OBJECT_NAME>"
```

For large images, use the OCI CLI's supported multipart/resume behavior as appropriate for the installed CLI version and network environment.

After upload, confirm the object exists:

```bash
oci os object head \
  --bucket-name "<BUCKET_NAME>" \
  --name "<OBJECT_NAME>"
```

### Transfer evidence

- [ ] Local file SHA-256 recorded.
- [ ] Upload command captured.
- [ ] OCI Object Storage object confirmed.
- [ ] Object size matches expectation.
- [ ] Bucket/object permissions permit image import.

---

# PART VI — OCI CUSTOM IMAGE IMPORT

## 21. Console Navigation

Use:

```text
OCI Console
→ Compute
→ Custom Images
→ Import Image
```

Then configure:

1. **Create in compartment** — compartment where the custom-image resource should live.
2. **Name** — meaningful migration image name.
3. **Operating system** — select the correct OS family.
4. **Import from an Object Storage bucket**.
5. Select the **bucket** containing the VMDK.
6. Select the **VMDK object**.
7. Set **Image type = VMDK**.
8. Select the appropriate **launch mode**.
9. Add approved tags if required.
10. Select **Import image**.

### Important compartment clarification

The custom image does **not** have to live in the same compartment as the Compute instance that will eventually use it.

The image compartment primarily controls:

- organization
- visibility
- IAM access
- lifecycle ownership

For simplicity, the program may colocate related compute artifacts, but that is an administrative design decision rather than a strict image-import requirement.

---

## 22. Launch Mode

For imported non-OCI VMDK images, the OCI import wizard currently allows modes including:

- Paravirtualized
- Emulated

Use the launch mode validated for the source operating system and drivers.

The working session expected **Paravirtualized** to be the normal target for these Linux VMs, but do not turn that meeting assumption into a blanket rule for every operating system.

If the imported image fails to boot, compare the launch mode against the old known-good OCI custom image before changing guest configuration blindly.

---

## 23. Wait for Image State = AVAILABLE

After starting the import:

```text
IMPORTING
    ↓
AVAILABLE
```

Do not launch an instance until the custom image is `AVAILABLE`.

If import fails:

1. Confirm OCI can read the Object Storage object.
2. Confirm the object is a supported single-file VMDK.
3. Confirm the VMDK is not a snapshot-chain or split-disk representation.
4. Confirm source boot-disk prerequisites.
5. Compare with the old successful VMDK.
6. Compare the new import parameters with the old custom image.

---

# PART VII — FIRST OCI LAUNCH

## 24. Launch ONE Test Instance

Do not launch all five migrated VMs immediately.

Create one test instance from the newly imported custom image.

Select:

- target CREAM landing-zone compartment
- approved VCN
- approved subnet
- appropriate compute shape
- imported custom image
- private IP assignment through OCI
- approved NSGs/security lists
- approved SSH key/admin-access method
- tags required by the landing zone

The objective is to prove the guest-OS migration path before scaling the process.

---

## 25. First-Boot Observation

During initial startup, watch for:

- bootloader errors
- emergency mode
- missing-disk waits
- filesystem failures
- NFS timeout
- NetworkManager failure
- duplicate/static IP behavior
- unresolved boot services
- long systemd timeouts

Use OCI console/serial-console capabilities where authorized if normal network access is not yet available.

### Success criteria

- [ ] Instance reaches normal multi-user boot.
- [ ] Primary VNIC receives an OCI IP through DHCP.
- [ ] Default route points to the expected OCI network path.
- [ ] No old source static IP is active.
- [ ] No old source default gateway is active.
- [ ] OS does not hang on NFS or missing data volumes.
- [ ] SSH daemon starts.

---

## 26. Validate OCI Networking

After access is established:

```bash
ip addr
ip route
nmcli device status
nmcli connection show
cat /etc/resolv.conf
```

Validate:

- [ ] OCI-assigned private IP is present.
- [ ] Expected OCI subnet is present.
- [ ] Default route is correct.
- [ ] DNS resolution works.
- [ ] Required on-prem routes are reachable through the landing-zone/DRG/FastConnect design where applicable.
- [ ] No duplicate route competes with OCI networking.

---

## 27. Validate SSH

From the approved management path:

```bash
ssh <user>@<target>
```

Validate:

- [ ] Authentication succeeds.
- [ ] Expected administrator account is usable.
- [ ] `sudo` works where required.
- [ ] SSH host keys/security handling is documented.
- [ ] Access traverses the intended Bastion/private path if required by policy.

If the VM boots but SSH fails, distinguish between:

1. subnet/route issue
2. NSG/security-list issue
3. host firewall issue
4. `sshd` issue
5. account/key issue
6. cloud-init/key-injection issue

Do not immediately declare the custom-image import failed merely because TCP/22 is unreachable.

---

## 28. Validate DNS and NTP

DNS:

```bash
getent hosts <known-hostname>
cat /etc/resolv.conf
```

Time synchronization:

```bash
chronyc sources -v
chronyc tracking
```

Success criteria:

- [ ] Required DNS names resolve.
- [ ] System time is synchronized.
- [ ] No unreachable on-prem NTP source is the only configured source.

---

## 29. Validate Boot Health

```bash
systemctl --failed
journalctl -b -p warning --no-pager
```

Investigate failures related to:

- NFS
- old NIC names
- missing disks
- monitoring
- backup agents
- application middleware
- directory services
- license servers

A small number of intentionally disabled application integrations may be acceptable during the migration test. Boot-critical failures are not.

---

# PART VIII — POST-MIGRATION RECONFIGURATION

## 30. Rebuild OCI-Specific Services

Once the VM boots and is reachable, rebuild services deliberately rather than restoring every old dependency automatically.

Possible tasks:

- configure final DNS behavior
- configure approved NTP source
- recreate required static routes at the proper OCI/network layer
- reconnect approved on-prem services over FastConnect
- recreate NFS mounts or move them to OCI File Storage
- attach/import additional data volumes
- reconfigure backup targets
- reconfigure monitoring/logging agents
- reconfigure application endpoints
- validate certificates
- validate identity/LDAP/AD integration
- validate vulnerability/security tooling
- validate OCI agent/cloud-init behavior

---

## 31. Application Validation

After OS validation succeeds:

- [ ] Application starts.
- [ ] Required local services start.
- [ ] Required ports listen.
- [ ] Database connectivity works.
- [ ] File dependencies work.
- [ ] Authentication works.
- [ ] Logging reaches approved destination.
- [ ] Monitoring reaches approved destination.
- [ ] Backup plan is re-established.
- [ ] Performance is within expected POC/migration tolerance.

Only after the first migrated VM passes should the exact procedure be promoted to the remaining migration wave.

---

# PART IX — TROUBLESHOOTING USING OLD ARTIFACTS

## 32. Old Object Storage VMDKs

The meeting confirmed that older migration VMDKs appear to remain in the existing Object Storage bucket.

Treat them as protected troubleshooting references.

If a new VMDK fails:

| Compare | Old working artifact | New artifact |
|---|---|---|
| VMDK structure | Known working | Verify single supported VMDK |
| Source OS | Record | Record |
| DHCP | Working baseline | Must match intent |
| Static IP | Removed | Verify removed |
| Gateway | OCI-compatible | Verify no old gateway |
| MAC binding | OCI-compatible | Verify none |
| NTP | Known working | Compare |
| NFS boot dependency | Known working | Compare |
| Launch mode | Known working | Compare |
| OCI image settings | Known working | Compare |

Do not delete old artifacts until the new migration factory is proven and records-retention requirements permit cleanup.

---

## 33. Old OCI Custom Images

The team also found the old entries under:

```text
Compute → Custom Images
```

These images are useful for:

- launch-mode comparison
- OS metadata comparison
- historical image naming
- compartment-placement comparison
- image export for preservation

OCI supports exporting eligible custom images back to Object Storage, including VMDK format.

This creates an additional known-good reference artifact if needed.

Do not overwrite or delete the old working custom image during the new POC.

---

# PART X — MIGRATION WAVE

## 34. Promote the Proven Procedure

After the first golden test succeeds, freeze the successful procedure as the baseline.

For each remaining VM:

```text
Inventory VM
   ↓
Compare against golden source
   ↓
Remediate
   ↓
DHCP/network cleanup
   ↓
NTP/NFS/boot cleanup
   ↓
Export supported VMDK
   ↓
Checksum
   ↓
Upload to Object Storage
   ↓
Import Custom Image
   ↓
Launch test instance
   ↓
Boot/network/SSH validation
   ↓
Application validation
   ↓
Approve migration
```

Do not assume all five VMs are identical simply because the export operation is the same.

Each VM requires its own dependency review.

---

## 35. Per-VM Migration Record

Create one record per migrated VM:

| Field | Value |
|---|---|
| VM name | |
| Owner | |
| Source VMware cluster | |
| OS/version | |
| Security remediation % | |
| Golden comparison complete | |
| DHCP prepared | |
| Static IP removed | |
| Gateway removed | |
| NTP reviewed | |
| NFS reviewed | |
| Boot dependencies reviewed | |
| VMDK filename | |
| SHA-256 | |
| Object Storage bucket | |
| Object name | |
| Custom image OCID | |
| Custom image compartment | |
| Launch mode | |
| Test instance OCID | |
| OCI compartment | |
| First boot pass/fail | |
| SSH pass/fail | |
| DNS pass/fail | |
| NTP pass/fail | |
| App smoke test | |
| Issues/waivers | |
| Migration approval | |

---

# PART XI — MOVING EXISTING OCI RESOURCES INTO CREAM

## 36. Compartment Move Principle

The working session also discussed reorganizing existing OCI resources into the new CREAM OCI landing-zone compartment structure.

Moving a supported resource between compartments generally changes its administrative placement rather than recreating the resource.

The resource OCID remains the stable identity unless the specific OCI service documents otherwise for that operation.

Conceptually:

```text
Before
Old Compartment
   └── Resource
       OCID: ocid1....

After
CREAM Landing Zone
   └── Resource
       OCID: ocid1....
```

The primary migration risk is therefore usually **authorization/governance**, not the mere logical folder move.

---

## 37. Pre-Move IAM / Landing-Zone Checklist

Before moving FastConnect, networking, Compute, or other shared resources, verify:

- [ ] IAM policies in the destination compartment.
- [ ] Dynamic-group rules.
- [ ] Instance-principal permissions.
- [ ] Terraform/CD3 permissions.
- [ ] Quotas.
- [ ] Defined-tag permissions/default tags.
- [ ] Monitoring permissions.
- [ ] Logging permissions.
- [ ] Automation/service-account access.
- [ ] Backup policies.
- [ ] Alarm destinations.
- [ ] Resource Manager stack assumptions.
- [ ] Any scripts that explicitly reference compartment OCIDs.

The fact that a resource keeps the same OCID does not guarantee that every principal retains permission after the move.

---

## 38. FastConnect Move Precaution

For FastConnect/virtual-circuit resources, the meeting expectation was that a supported compartment move should not itself interrupt forwarding simply because administrative compartment metadata changes.

However, treat FastConnect as a critical shared service.

Before moving it:

- [ ] Confirm the exact OCI resource supports compartment movement.
- [ ] Capture current virtual-circuit OCID.
- [ ] Capture DRG association.
- [ ] Capture BGP state.
- [ ] Capture route-table state.
- [ ] Capture monitoring/alarm configuration.
- [ ] Validate destination-compartment IAM.
- [ ] Validate Terraform/CD3 ownership/state expectations.
- [ ] Schedule the change with a rollback/escalation plan.

Immediately after the move:

- [ ] Confirm virtual circuit state.
- [ ] Confirm BGP sessions.
- [ ] Confirm routes.
- [ ] Run an on-prem ↔ OCI connectivity test.
- [ ] Confirm monitoring still sees the circuit.

Do not use the statement “OCID stays the same” as a substitute for a post-change connectivity check.

---

# PART XII — ACTION PLAN FROM THE MEETING

## 39. Immediate Action Items

| Owner | Action | Priority |
|---|---|---:|
| Charlie / VM team | Finish remediation of reference VM toward internal ~90% target | High |
| VM team | Confirm recovered VM is still OCI-ready | High |
| Vivek | Validate additional guest preparation performed during the previous migration | High |
| VM team | Document DHCP/NTP/network/NFS changes from reference VM | High |
| VM team | Export reference VM as supported single-file VMDK | High |
| OCI team | Upload VMDK to Object Storage | High |
| OCI team | Import VMDK as OCI Custom Image | High |
| OCI team | Launch one test Compute instance | High |
| Team | Validate first boot, DHCP, SSH, DNS, and NTP | High |
| Team | Record exact successful procedure | High |
| Team | Repeat process for remaining approximately five VMs | Medium |
| Johnny | Continue reorganizing resources into CREAM landing zone | Medium |
| Johnny | Verify IAM/policies before moving FastConnect/network resources | High |
| OCI team | Identify OKE/Kubernetes SME for A10 POC | High |
| App + OCI teams | Coordinate joint A10 GPU POC | High |

---

# PART XIII — A10 GPU / OKE POC COORDINATION NOTE

## 40. Separate Workstream

The same meeting confirmed the direction to proceed with an OCI-based A10 GPU Kubernetes POC rather than purchasing on-premises GPU infrastructure for the initial evaluation.

The Kubernetes point clarified during the meeting is important:

> **Twenty pods do not require twenty physical servers.**

Pods are scheduled across OKE worker nodes according to resources and scheduling policies such as:

- CPU requests/limits
- memory requests/limits
- GPU requests
- affinity / anti-affinity
- taints / tolerations
- node selectors

The initial POC discussion centered on approximately two GPU worker nodes supporting multiple application pods, subject to final sizing and vendor validation.

Keep this workstream separate from the VMware VMDK migration test so a Kubernetes design issue does not block proving the basic VM migration factory.

---

# PART XIV — GO / NO-GO CHECKLIST

## 41. Golden VM Export — GO Gate

Proceed with the first export only when all are true:

- [ ] Golden VM identity confirmed.
- [ ] Vivek/previous migration knowledge captured as available.
- [ ] Remediation target accepted.
- [ ] DHCP ready.
- [ ] Static IP removed/staged.
- [ ] Old gateway removed/staged.
- [ ] MAC hard-coding removed.
- [ ] NTP reviewed.
- [ ] NFS boot blocking removed.
- [ ] Secondary disk boot dependencies removed.
- [ ] SSH/admin path prepared.
- [ ] VMware rollback path exists.
- [ ] Export will produce supported single-file VMDK.

If any boot-critical item is unknown, **NO-GO**.

---

## 42. OCI Image Import — GO Gate

- [ ] VMDK exported cleanly.
- [ ] SHA-256 recorded.
- [ ] Single supported VMDK confirmed.
- [ ] Object Storage upload completed.
- [ ] Object is readable by the importing principal/service path.
- [ ] OS selection confirmed.
- [ ] Launch mode selected based on source/known-good image.
- [ ] Custom-image compartment selected.

---

## 43. Migration Factory — GO Gate

Do not proceed to the remaining VMs until the first new OCI instance passes:

- [ ] Normal OS boot.
- [ ] OCI DHCP.
- [ ] Correct default route.
- [ ] DNS.
- [ ] SSH/admin access.
- [ ] NTP synchronization.
- [ ] No boot-blocking NFS dependency.
- [ ] No boot-blocking missing-volume dependency.
- [ ] Required FastConnect reachability.
- [ ] Application smoke test.
- [ ] Procedure/evidence documented.

Only then promote the process to the remaining migration wave.

---

# 44. Final Recommended Sequence

```text
1. Validate recovered golden VM
        ↓
2. Confirm prior Vivek preparation steps
        ↓
3. Reach/approve ~90% internal remediation target
        ↓
4. Capture pre-change evidence
        ↓
5. Convert primary NIC to DHCP
        ↓
6. Remove static IP / old gateway / MAC bindings
        ↓
7. Review DNS + NTP
        ↓
8. Disable boot-blocking NFS/network dependencies
        ↓
9. Confirm boot disk is self-contained
        ↓
10. Validate SSH/admin path
        ↓
11. Clean shutdown
        ↓
12. Export supported single-file VMDK
        ↓
13. Generate SHA-256
        ↓
14. Upload to OCI Object Storage
        ↓
15. Compute → Custom Images → Import Image
        ↓
16. Select Object Storage VMDK + OS + launch mode
        ↓
17. Wait for image AVAILABLE
        ↓
18. Launch ONE test OCI Compute instance
        ↓
19. Validate boot + DHCP + route + SSH
        ↓
20. Validate DNS + NTP
        ↓
21. Rebuild OCI/on-prem dependencies deliberately
        ↓
22. Application smoke test
        ↓
23. Record exact successful settings
        ↓
24. Repeat for remaining VMs
```

---

## 45. Source References

Oracle Cloud Infrastructure documentation:

- Importing Custom Linux Images  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimagelinux.htm

- Importing Custom Images  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/custom-images-import.htm

- Importing and Exporting Custom Images  
  https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/imageimportexport.htm

- OCI CLI Compute Image Import Reference  
  https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/image/import/from-object.html

---

## 46. Operational Rule

**Do not migrate all remaining VMs until one fresh VMware → VMDK → Object Storage → OCI Custom Image → Compute launch has passed end-to-end validation.**

The recovered VM, old VMDKs, and old OCI custom images provide a rare advantage: the team has known-good artifacts from the previous successful migration. Use them as the baseline and convert the result into a repeatable migration factory rather than relying on tribal knowledge.
