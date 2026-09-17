terraform {
  required_version = ">= 1.2.0, < 2.0.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.29"
    }
  }
}

# ORM supplies authentication. Do not embed API private keys.
provider "oci" {
  region = var.region
}

# Required inputs
variable "region" { type = string }
variable "compartment_ocid" { type = string }
variable "availability_domain" { type = string }
variable "image_ocid" { type = string }
variable "ssh_public_key" { type = string }
variable "vcn_cidr" { type = string }
variable "subnet_cidr" { type = string }

variable "admin_cidr" {
  type        = string
  description = "Jump-host private CIDR; preferably a single /32."
  validation {
    condition = (
      can(cidrnetmask(var.admin_cidr)) &&
      try(tonumber(split("/", var.admin_cidr)[1]) > 0, false)
    )
    error_message = "Provide an IPv4 CIDR; unrestricted /0 SSH is prohibited."
  }
}

variable "name" { default = "dw-poc" }

variable "shape" {
  type    = string
  default = "VM.Standard.E6.Flex"
  validation {
    condition = contains([
      "VM.Standard.E6.Flex",
      "VM.GPU.A10.2"
    ], var.shape)
    error_message = "Choose VM.Standard.E6.Flex or VM.GPU.A10.2."
  }
}

variable "instance_count" {
  type    = number
  default = 1
  validation {
    condition = (
      var.instance_count >= 1 &&
      var.instance_count == floor(var.instance_count)
    )
    error_message = "Instance count must be a positive integer."
  }
}

# Illustrative E6 settings, not vendor-approved application sizing.
# These are OCPUs, not vCPUs. Ignored for fixed-shape A10.2.
variable "flex_ocpus" { default = 8 }
variable "flex_memory_gb" { default = 128 }
variable "boot_volume_gb" { default = 100 }

# Zero disables additional data volumes.
variable "data_volume_gb" { default = 0 }
variable "data_volume_vpus" { default = 20 }

# Leave DRG inputs empty for an isolated deployment.
# For connected deployment, supply an approved existing DRG route table.
variable "drg_ocid" { default = "" }
variable "drg_route_table_ocid" { default = "" }

variable "onprem_cidrs" {
  type        = set(string)
  default     = []
  description = "Approved destination networks reached through the DRG."
  validation {
    condition = alltrue([
      for cidr in var.onprem_cidrs :
      can(cidrnetmask(cidr)) &&
      try(tonumber(split("/", cidr)[1]) > 0, false)
    ])
    error_message = "Use explicit IPv4 destination CIDRs, not a default route."
  }
}

# Optional app, cluster, or approved proxy rules.
# protocol: TCP=6, UDP=17. Each entry opens one destination port.
variable "extra_rules" {
  type = map(object({
    direction = string
    protocol  = string
    cidr      = string
    port      = number
  }))
  default = {}
  validation {
    condition = alltrue([
      for rule in values(var.extra_rules) :
      contains(["INGRESS", "EGRESS"], rule.direction) &&
      contains(["6", "17"], rule.protocol) &&
      can(cidrnetmask(rule.cidr)) &&
      try(tonumber(split("/", rule.cidr)[1]) > 0, false) &&
      rule.port >= 1 &&
      rule.port <= 65535 &&
      rule.port == floor(rule.port)
    ])
    error_message = "Use INGRESS/EGRESS, protocol 6/17, an explicit IPv4 CIDR, and a valid port."
  }
}

# ---------- Network ----------
resource "oci_core_vcn" "workload" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "workload"
}

data "oci_core_services" "regional" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "services" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.workload.id
  display_name   = "${var.name}-service-gateway"
  services {
    service_id = data.oci_core_services.regional.services[0].id
  }
}

resource "oci_core_drg_attachment" "existing" {
  count              = var.drg_ocid != "" ? 1 : 0
  drg_id             = var.drg_ocid
  drg_route_table_id = var.drg_route_table_ocid
  display_name       = "${var.name}-drg-attachment"
  network_details {
    id             = oci_core_vcn.workload.id
    type           = "VCN"
    vcn_route_type = "SUBNET_CIDRS"
  }
  lifecycle {
    precondition {
      condition     = var.drg_route_table_ocid != ""
      error_message = "Supply the network team's approved DRG route-table OCID."
    }
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.workload.id
  display_name   = "${var.name}-private-routes"
  route_rules {
    destination       = data.oci_core_services.regional.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.services.id
  }
  dynamic "route_rules" {
    for_each = var.onprem_cidrs
    content {
      destination       = route_rules.value
      destination_type  = "CIDR_BLOCK"
      network_entity_id = var.drg_ocid
    }
  }
  lifecycle {
    precondition {
      condition     = length(var.onprem_cidrs) == 0 || var.drg_ocid != ""
      error_message = "DRG routes require an existing DRG OCID."
    }
  }
  depends_on = [oci_core_drg_attachment.existing]
}

# An empty security list avoids inheriting the VCN's default allow rules.
# Workload permissions are controlled by the NSG below.
resource "oci_core_security_list" "empty" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.workload.id
  display_name   = "${var.name}-empty-security-list"
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.workload.id
  display_name               = "${var.name}-private-subnet"
  cidr_block                 = var.subnet_cidr
  dns_label                  = "nodes"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
}

# ---------- Security ----------
resource "oci_core_network_security_group" "vm" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.workload.id
  display_name   = "${var.name}-vm-nsg"
}

locals {
  baseline_rules = {
    ssh = {
      direction = "INGRESS"
      protocol  = "6"
      cidr      = var.admin_cidr
      port      = 22
    }
    dns_tcp = {
      direction = "EGRESS"
      protocol  = "6"
      cidr      = "169.254.169.254/32"
      port      = 53
    }
    dns_udp = {
      direction = "EGRESS"
      protocol  = "17"
      cidr      = "169.254.169.254/32"
      port      = 53
    }
    ntp = {
      direction = "EGRESS"
      protocol  = "17"
      cidr      = "169.254.169.254/32"
      port      = 123
    }
  }

  rules = merge(
    local.baseline_rules,
    { for key, rule in var.extra_rules : "extra-${key}" => rule }
  )
}

resource "oci_core_network_security_group_security_rule" "ports" {
  for_each                  = local.rules
  network_security_group_id = oci_core_network_security_group.vm.id
  description               = each.key
  direction                 = each.value.direction
  protocol                  = each.value.protocol
  stateless                 = false

  source = each.value.direction == "INGRESS" ? each.value.cidr : null
  source_type = (
    each.value.direction == "INGRESS" ? "CIDR_BLOCK" : null
  )

  destination = each.value.direction == "EGRESS" ? each.value.cidr : null
  destination_type = (
    each.value.direction == "EGRESS" ? "CIDR_BLOCK" : null
  )

  dynamic "tcp_options" {
    for_each = each.value.protocol == "6" ? [each.value.port] : []
    content {
      destination_port_range {
        min = tcp_options.value
        max = tcp_options.value
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "17" ? [each.value.port] : []
    content {
      destination_port_range {
        min = udp_options.value
        max = udp_options.value
      }
    }
  }
}

resource "oci_core_network_security_group_security_rule" "oci_https" {
  network_security_group_id = oci_core_network_security_group.vm.id
  direction                 = "EGRESS"
  protocol                  = "6"
  stateless                 = false
  destination               = data.oci_core_services.regional.services[0].cidr_block
  destination_type          = "SERVICE_CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# Permit IPv4 path-MTU discovery; this does not open application ports.
resource "oci_core_network_security_group_security_rule" "pmtu" {
  network_security_group_id = oci_core_network_security_group.vm.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  icmp_options {
    type = 3
    code = 4
  }
}

# ---------- Compute ----------
resource "oci_core_instance" "vm" {
  count               = var.instance_count
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.name}-${count.index + 1}"
  shape               = var.shape

  dynamic "shape_config" {
    for_each = var.shape == "VM.Standard.E6.Flex" ? [1] : []
    content {
      ocpus         = var.flex_ocpus
      memory_in_gbs = var.flex_memory_gb
    }
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_ocid
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.vm.id]
    hostname_label   = "node${count.index + 1}"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  is_pv_encryption_in_transit_enabled = true

  freeform_tags = {
    Workload = var.name
    Purpose  = "POC"
  }

  depends_on = [
    oci_core_network_security_group_security_rule.ports,
    oci_core_network_security_group_security_rule.oci_https,
    oci_core_network_security_group_security_rule.pmtu
  ]
}

# Optional block volume per VM. Attaches only; does not format or mount.
resource "oci_core_volume" "data" {
  count               = var.data_volume_gb > 0 ? var.instance_count : 0
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.name}-${count.index + 1}-data"
  size_in_gbs         = var.data_volume_gb
  vpus_per_gb         = var.data_volume_vpus
}

resource "oci_core_volume_attachment" "data" {
  count           = var.data_volume_gb > 0 ? var.instance_count : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.vm[count.index].id
  volume_id       = oci_core_volume.data[count.index].id

  is_pv_encryption_in_transit_enabled = true
}

output "private_ips" {
  value = oci_core_instance.vm[*].private_ip
}

output "instance_ids" {
  value = oci_core_instance.vm[*].id
}

output "network" {
  value = {
    vcn_id    = oci_core_vcn.workload.id
    subnet_id = oci_core_subnet.private.id
    nsg_id    = oci_core_network_security_group.vm.id
  }
}
