locals {
  # ---------------------------------------------------------------------------
  # Tags — mandatory tags (root CLAUDE.md contract), lowercase, no spaces.
  # Sorted + de-duplicated so input reordering never produces a perpetual diff.
  # ---------------------------------------------------------------------------
  base_tags = [
    "environment-${var.environment}",
    "project-${var.project}",
    "managed_by-terraform",
  ]

  template_tags = sort(distinct(concat(local.base_tags, ["role-template"])))

  workload_tags = {
    for name, spec in var.workloads :
    name => sort(distinct(concat(local.base_tags, spec.tags)))
  }

  lxc_workload_tags = {
    for name, spec in var.lxc_workloads :
    name => sort(distinct(concat(local.base_tags, spec.tags)))
  }

  # ---------------------------------------------------------------------------
  # Template source resolution
  #   VM:  build it (var.template) OR clone an existing one (vm_clone_template_id)
  #   LXC: download vztmpl (var.lxc_template) OR use an existing file id
  # ---------------------------------------------------------------------------
  vm_template_id = var.template != null ? proxmox_virtual_environment_vm.template[0].vm_id : var.vm_clone_template_id

  lxc_template_file_id = var.lxc_template != null ? proxmox_download_file.lxc_template[0].id : var.lxc_template_file_id

  # Disk placement fallback when not building a template.
  vm_disk_datastore_default = var.template != null ? var.template.disk_datastore : var.default_datastore

  # ---------------------------------------------------------------------------
  # VMID guardrail inputs
  # ---------------------------------------------------------------------------
  # Explicitly requested VMIDs across template + all workloads.
  explicit_ids = concat(
    var.template != null ? [var.template.vm_id] : [],
    [for k, v in var.workloads : v.vm_id if v.vm_id != null],
    [for k, v in var.lxc_workloads : v.vm_id if v.vm_id != null],
  )

  # Names of resources THIS state manages (used to exclude our own VMs from the
  # cluster collision check).
  managed_names = concat(
    var.template != null ? [var.template.name] : [],
    keys(var.workloads),
    keys(var.lxc_workloads),
  )

  # vm_id -> name for everything currently on the cluster (queried at plan time).
  existing_by_id = {
    for vm in data.proxmox_virtual_environment_vms.existing.vms :
    tostring(vm.vm_id) => vm.name
  }

  # Requested IDs that already exist on the cluster under a name we do NOT manage.
  cluster_id_conflicts = [
    for id in local.explicit_ids : tostring(id)
    if contains(keys(local.existing_by_id), tostring(id)) && !contains(local.managed_names, local.existing_by_id[tostring(id)])
  ]
}
