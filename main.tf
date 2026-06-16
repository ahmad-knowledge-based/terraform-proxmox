# -----------------------------------------------------------------------------
# Existing cluster inventory — used by the VMID guardrail (terraform_data.id_guard).
# Queried against the Proxmox API at plan time.
# -----------------------------------------------------------------------------
data "proxmox_virtual_environment_vms" "existing" {}

# -----------------------------------------------------------------------------
# Guardrails — fail the plan early on VMID conflicts or invalid template config.
# -----------------------------------------------------------------------------
resource "terraform_data" "id_guard" {
  lifecycle {
    # No duplicate VMIDs declared within this configuration.
    precondition {
      condition     = length(local.explicit_ids) == length(distinct(local.explicit_ids))
      error_message = "Duplicate vm_id values declared across template/workloads/lxc_workloads. Each VMID must be unique."
    }

    # No requested VMID already taken by a foreign VM on the cluster.
    precondition {
      condition     = length(local.cluster_id_conflicts) == 0
      error_message = "These VMIDs are already in use on the cluster by other VMs: ${join(", ", local.cluster_id_conflicts)}. Choose different vm_id values."
    }

    # VM workloads need exactly one template source.
    precondition {
      condition     = length(var.workloads) == 0 || !(var.template == null && var.vm_clone_template_id == null)
      error_message = "VM workloads require either var.template (build one) or var.vm_clone_template_id (clone an existing one)."
    }
    precondition {
      condition     = !(var.template != null && var.vm_clone_template_id != null)
      error_message = "Set only ONE of var.template or var.vm_clone_template_id, not both."
    }

    # LXC workloads need exactly one OS template source.
    precondition {
      condition     = length(var.lxc_workloads) == 0 || !(var.lxc_template == null && var.lxc_template_file_id == null)
      error_message = "LXC workloads require either var.lxc_template (download one) or var.lxc_template_file_id (use an existing vztmpl)."
    }
    precondition {
      condition     = !(var.lxc_template != null && var.lxc_template_file_id != null)
      error_message = "Set only ONE of var.lxc_template or var.lxc_template_file_id, not both."
    }

    # Cloud-config snippets are uploaded over SSH — require it when enabled.
    precondition {
      condition     = !var.use_cloud_config || var.proxmox_ssh != null
      error_message = "use_cloud_config = true requires var.proxmox_ssh (snippets are uploaded over SSH, not the API)."
    }
  }
}

# -----------------------------------------------------------------------------
# 1. (Optional) Download the cloud image — only when building a VM template.
#    content_type = "import" requires the 'import' content type on the target
#    DIRECTORY datastore (PVE 8.4+ / 9.x). ZFS pools cannot hold the file.
# -----------------------------------------------------------------------------
resource "proxmox_download_file" "cloud_image" {
  count = var.template != null ? 1 : 0

  content_type       = "import"
  datastore_id       = var.template.image_datastore
  node_name          = var.proxmox_node
  url                = var.template.image_url
  file_name          = var.template.image_file_name
  checksum           = var.template.checksum
  checksum_algorithm = var.template.checksum_algorithm
}

# -----------------------------------------------------------------------------
# 2. (Optional) Build the VM template from the imported image.
#    template = true is an in-place conversion (v0.100.0+), not a recreate.
# -----------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "template" {
  count = var.template != null ? 1 : 0

  name      = var.template.name
  node_name = var.proxmox_node
  vm_id     = var.template.vm_id
  template  = true
  started   = false
  tags      = local.template_tags

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  # Import the downloaded cloud image as the boot disk on the ZFS pool.
  disk {
    datastore_id = var.template.disk_datastore
    import_from  = proxmox_download_file.cloud_image[0].id
    interface    = "scsi0"
    size         = var.template.disk_size
  }

  network_device {
    bridge = "vmbr0"
  }

  # Cloud images require a serial console.
  serial_device {}
}

# -----------------------------------------------------------------------------
# 3. (Optional) Per-VM cloud-config VENDOR-data snippet.
#    Uploaded over SSH (snippets aren't an API operation) to a Snippets-enabled
#    datastore. Used as cloud-init *vendor-data*, which is MERGED with user-data —
#    so the structured user_account (users/keys/password) is preserved while this
#    adds packages + runcmd (e.g. qemu-guest-agent). yamlencode keeps YAML valid.
# -----------------------------------------------------------------------------
resource "proxmox_virtual_environment_file" "vendor_data" {
  for_each = var.use_cloud_config ? { for k, v in var.workloads : k => v if v.cloud_init } : {}

  content_type = "snippets"
  datastore_id = var.snippet_datastore
  node_name    = var.proxmox_node

  source_raw {
    file_name = "vendor-data-${each.key}.yaml"
    data = "#cloud-config\n${yamlencode({
      timezone       = var.cloud_config.timezone
      package_update = true
      packages       = var.cloud_config.packages
      runcmd         = var.cloud_config.runcmd
    })}"
  }
}

# -----------------------------------------------------------------------------
# 4. QEMU VM workloads — cloned from the (built or existing) template.
# -----------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "workload" {
  for_each = var.workloads

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  tags      = local.workload_tags[each.key]
  on_boot   = each.value.on_boot
  started   = each.value.started

  # Referencing local.vm_template_id (the built template, when present) expresses
  # ordering without depends_on; falls back to an existing template VMID.
  clone {
    vm_id = local.vm_template_id
    full  = each.value.full_clone
    # cloud_init VMs place their disk via the disk block below; non-cloud clones
    # steer placement here (null = inherit the template's datastore).
    datastore_id = each.value.cloud_init ? null : try(coalesce(each.value.disk_datastore, var.default_datastore), null)
  }

  # Only enable (and wait for) the guest agent when the image actually runs it,
  # otherwise bpg blocks until the agent timeout on every started VM.
  agent {
    enabled = each.value.agent_enabled != null ? each.value.agent_enabled : var.qemu_agent_enabled
  }

  cpu {
    cores   = each.value.cores
    sockets = each.value.sockets
    type    = each.value.cpu_type
  }

  # floating = 0 disables the balloon device (fixed RAM). Set balloon_minimum > 0
  # to enable ballooning between that floor and `dedicated`.
  memory {
    dedicated = each.value.memory
    floating  = each.value.balloon_minimum
  }

  # Only manage the disk for cloud-init clones (scsi0, resizable). Non-cloud clones
  # inherit the template's disk as-is — avoids interface mismatches.
  dynamic "disk" {
    for_each = each.value.cloud_init ? [1] : []
    content {
      datastore_id = coalesce(each.value.disk_datastore, local.vm_disk_datastore_default)
      interface    = "scsi0"
      size         = each.value.disk_size
    }
  }

  # Cloud-init config — omitted entirely for non-cloud templates (cloud_init = false),
  # so the clone inherits the template's network/credentials untouched.
  dynamic "initialization" {
    for_each = each.value.cloud_init ? [1] : []
    content {
      datastore_id = coalesce(each.value.disk_datastore, local.vm_disk_datastore_default)

      ip_config {
        ipv4 {
          address = each.value.ip_address
          gateway = each.value.gateway
        }
      }

      # Structured cloud-init users/keys/password — always present for cloud-init VMs.
      user_account {
        username = var.ci_user
        keys     = var.ssh_public_keys
        # per-VM password wins; otherwise fall back to the global ci_password (null = key-only)
        password = each.value.password != null ? each.value.password : var.ci_password
      }

      # Optional vendor-data snippet (packages, runcmd) — merged WITH user_account above.
      vendor_data_file_id = var.use_cloud_config ? proxmox_virtual_environment_file.vendor_data[each.key].id : null

      dynamic "dns" {
        for_each = length(var.nameservers) > 0 ? [1] : []
        content {
          servers = var.nameservers
          domain  = var.search_domain
        }
      }
    }
  }

  network_device {
    bridge = each.value.bridge
  }

  serial_device {}

  depends_on = [terraform_data.id_guard]

  lifecycle {
    precondition {
      condition     = each.value.balloon_minimum <= each.value.memory
      error_message = "workload '${each.key}': balloon_minimum (${each.value.balloon_minimum} MB) cannot exceed memory (${each.value.memory} MB)."
    }
    precondition {
      condition     = !each.value.cloud_init || each.value.ip_address != null
      error_message = "workload '${each.key}': ip_address is required when cloud_init = true."
    }
  }
}

# -----------------------------------------------------------------------------
# 4. (Optional) Download the LXC OS template (vztmpl) — only when requested.
# -----------------------------------------------------------------------------
resource "proxmox_download_file" "lxc_template" {
  count = var.lxc_template != null ? 1 : 0

  content_type       = "vztmpl"
  datastore_id       = var.lxc_template.datastore
  node_name          = var.proxmox_node
  url                = var.lxc_template.url
  file_name          = var.lxc_template.file_name
  checksum           = var.lxc_template.checksum
  checksum_algorithm = var.lxc_template.checksum_algorithm
}

# -----------------------------------------------------------------------------
# 5. LXC container workloads — created from the vztmpl OS template.
# -----------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "workload" {
  for_each = var.lxc_workloads

  node_name    = var.proxmox_node
  vm_id        = each.value.vm_id
  tags         = local.lxc_workload_tags[each.key]
  started      = each.value.started
  unprivileged = each.value.unprivileged

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
    swap      = each.value.swap
  }

  disk {
    datastore_id = coalesce(each.value.disk_datastore, var.default_datastore)
    size         = each.value.disk_size
  }

  operating_system {
    template_file_id = local.lxc_template_file_id
    type             = each.value.os_type
  }

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.ip_address
        gateway = each.value.gateway
      }
    }

    user_account {
      keys     = var.ssh_public_keys
      password = each.value.password
    }

    dynamic "dns" {
      for_each = length(var.nameservers) > 0 ? [1] : []
      content {
        servers = var.nameservers
        domain  = var.search_domain
      }
    }
  }

  network_interface {
    name   = "eth0"
    bridge = each.value.bridge
  }

  depends_on = [terraform_data.id_guard]
}
