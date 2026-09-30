# dwhs

## Architecture

- [OCI DataWalk and Hyperscience network and compartment architecture](./diagrams/OCI_DW_HS_Network_Compartments.md) — FastConnect/DRG connectivity, SCCA inspection, and separate DataWalk Dev/Test/Prod and Hyperscience Dev/Prod compartments.
- [Editable OCI E6 and A10.2 architecture](./OCI_DW_E6_HS_A10_2_Architecture.drawio) — Draw.io source for the compute and environment views.
- [Editable OCI DataWalk and Hyperscience application data flow](./OCI_DataWalk_Hyperscience_Application_Data_Flow.drawio) — Numbered end-to-end flow through FastConnect, DRG, Network Firewall, dedicated Hyperscience A10.2 and DataWalk E6 clusters, controlled Object Storage exchange, databases, storage, and shared security and operations services.
- [Editable Azure DataWalk and Hyperscience high-level architecture](./Azure_DataWalk_Hyperscience_High_Level_Architecture.drawio) — Two-page Draw.io design with embedded Azure icons, ExpressRoute hub-and-spoke connectivity, dedicated DataWalk CPU and Hyperscience A10 GPU clusters, shared platform services, and production/non-production separation.

## Azure POC Documentation

- [OCI to Azure POC Migration Plan and Timeline](./Azure_OCI_to_Azure_POC_Migration_Plan_and_Timeline.docx) — Azure Government target design, OCI-to-Azure terminology crosswalk, DataWalk CPU and Hyperscience A10 GPU planning basis, eight-week execution schedule, acceptance criteria, responsibilities, risks, and ETA.

## Migration Runbooks

- [VMware → OCI VMDK Migration Runbook](./OCI_VMware_to_OCI_VMDK_Migration_Runbook.md) — guest preparation, DHCP/network cleanup, NTP/NFS validation, VMware VMDK export, Object Storage upload, OCI custom-image import, first-boot/SSH validation, troubleshooting with known-good artifacts, and migration-wave gates.

## Infrastructure as Code

- [OCI VM Foundation (Resource Manager stack)](./terraform/oci-vm-foundation/) — private-only VCN,
  subnet, service gateway, NSG (SSH restricted to an approved jump-host CIDR), optional DRG
  attachment and on-prem routes, and E6 Flex / A10.2 VMs with optional block volumes.
  Deployable in ORM either by uploading the pre-built
  [`oci-vm-poc.zip`](./terraform/oci-vm-foundation/oci-vm-poc.zip) directly (no GitHub link
  needed), or by sourcing this repository (working directory `terraform/oci-vm-foundation`).
