# dwhs

## Architecture

- [OCI DataWalk and Hyperscience network and compartment architecture](./diagrams/OCI_DW_HS_Network_Compartments.md) — FastConnect/DRG connectivity, SCCA inspection, and separate DataWalk Dev/Test/Prod and Hyperscience Dev/Prod compartments.
- [Editable OCI E6 and A10.2 architecture](./OCI_DW_E6_HS_A10_2_Architecture.drawio) — Draw.io source for the compute and environment views.

## Migration Runbooks

- [VMware → OCI VMDK Migration Runbook](./OCI_VMware_to_OCI_VMDK_Migration_Runbook.md) — guest preparation, DHCP/network cleanup, NTP/NFS validation, VMware VMDK export, Object Storage upload, OCI custom-image import, first-boot/SSH validation, troubleshooting with known-good artifacts, and migration-wave gates.

## Infrastructure as Code

- [OCI VM Foundation (Resource Manager stack)](./terraform/oci-vm-foundation/) — private-only VCN,
  subnet, service gateway, NSG (SSH restricted to an approved jump-host CIDR), optional DRG
  attachment and on-prem routes, and E6 Flex / A10.2 VMs with optional block volumes. Deployable
  from ORM directly against this repository (working directory `terraform/oci-vm-foundation`).
