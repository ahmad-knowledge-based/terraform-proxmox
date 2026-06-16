# -----------------------------------------------------------------------------
# Provider connection
# -----------------------------------------------------------------------------
variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://pve.example.com:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form user@realm!tokenid=<uuid>"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification against the Proxmox endpoint (true for self-signed certs)"
  type        = bool
  default     = false
}

variable "proxmox_node" {
  description = "Name of the Proxmox node that hosts the template and workloads"
  type        = string
}

variable "proxmox_ssh" {
  description = "SSH access to the Proxmox node — REQUIRED only when use_cloud_config = true (snippet user-data is uploaded over SSH, not the API). null = no SSH."
  type = object({
    username         = string           # SSH user on the node (e.g. root)
    private_key_file = optional(string) # PATH to a PEM key (read via file() in providers.tf); omit to use agent
    agent            = optional(bool, false)
    node_address     = optional(string) # SSH host/IP if different from the API endpoint host
  })
  default   = null
  sensitive = true # carries private_key
}

# -----------------------------------------------------------------------------
# Tagging (mandatory tags enforced in locals.tf)
# -----------------------------------------------------------------------------
variable "environment" {
  description = "Deployment environment for this state (e.g. dev, prod). One environment per state."
  type        = string
}

variable "project" {
  description = "Project label applied as a tag to all resources"
  type        = string
  default     = "lab"
}

variable "default_datastore" {
  description = "Fallback datastore for disks when not building a template and not set per-workload (e.g. local-zfs)"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# VM base template — choose ONE:
#   - set `template`            -> Terraform downloads the image and builds it
#   - set `vm_clone_template_id`-> clone from an EXISTING template (no download)
# Leave both null if you only create LXC workloads.
# -----------------------------------------------------------------------------
variable "template" {
  description = "Cloud image + template build spec. Null = do not build a template."
  type = object({
    name               = string              # template VM name, e.g. ubuntu-2204-cloudinit
    vm_id              = number              # template VMID, e.g. 9000
    image_url          = string              # cloud image URL (.img recommended for PVE < 8.4)
    image_file_name    = optional(string)    # override download filename; derived from URL if null
    image_datastore    = string              # DIRECTORY datastore with 'import' content, e.g. local
    disk_datastore     = string              # ZFS pool datastore for the disk, e.g. local-zfs
    disk_size          = optional(number, 8) # template disk size in GB (>= image virtual size)
    checksum           = optional(string)    # expected image checksum (recommended)
    checksum_algorithm = optional(string)    # md5 | sha1 | sha256 | sha512
  })
  default = null
}

variable "vm_clone_template_id" {
  description = "VMID of an EXISTING VM template to clone workloads from (used when var.template is null)"
  type        = number
  default     = null
}

# -----------------------------------------------------------------------------
# LXC OS template — choose ONE (only needed if lxc_workloads is non-empty):
#   - set `lxc_template`         -> Terraform downloads the vztmpl
#   - set `lxc_template_file_id` -> use an EXISTING vztmpl (no download)
# -----------------------------------------------------------------------------
variable "lxc_template" {
  description = "LXC OS template (vztmpl) download spec. Null = do not download."
  type = object({
    url                = string           # vztmpl URL (.tar.zst / .tar.gz)
    file_name          = optional(string) # override filename; derived from URL if null
    datastore          = string           # datastore with 'vztmpl' content, e.g. local
    checksum           = optional(string)
    checksum_algorithm = optional(string)
  })
  default = null
}

variable "lxc_template_file_id" {
  description = "Volume ID of an EXISTING vztmpl, e.g. local:vztmpl/ubuntu-22.04-standard_*.tar.zst (used when var.lxc_template is null)"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Cloud-init / provisioning defaults applied to workloads
# -----------------------------------------------------------------------------
variable "ci_user" {
  description = "Default cloud-init username for VM workloads (LXC always uses root)"
  type        = string
  default     = "ubuntu"
}

variable "ci_password" {
  description = "Optional cloud-init password for the VM user (null = SSH-key-only login)"
  type        = string
  default     = null
  sensitive   = true
}

variable "qemu_agent_enabled" {
  description = "Enable the QEMU guest agent on VMs and wait for it to report IPs. Set false when the guest has no qemu-guest-agent installed — avoids long agent-probe timeouts on plan/apply."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Custom cloud-config user-data snippet (opt-in)
#   When enabled, each VM gets a #cloud-config snippet (uploaded over SSH) used
#   as cloud-init user-data INSTEAD of the structured user_account block (they
#   conflict in bpg). Use this to install qemu-guest-agent, extra packages, etc.
#   Requires var.proxmox_ssh and a datastore with the 'Snippets' content type.
# -----------------------------------------------------------------------------
variable "use_cloud_config" {
  description = "Generate a per-VM #cloud-config user-data snippet instead of the structured user_account. Requires proxmox_ssh + a Snippets-enabled datastore."
  type        = bool
  default     = false
}

variable "snippet_datastore" {
  description = "Datastore with the 'Snippets' content type enabled, used to store cloud-config user-data"
  type        = string
  default     = "local"
}

variable "cloud_config" {
  description = "Settings for the generated cloud-config user-data (used when use_cloud_config = true)"
  type = object({
    timezone = optional(string, "UTC")
    packages = optional(list(string), ["qemu-guest-agent", "net-tools", "curl"])
    runcmd = optional(list(string), [
      "systemctl enable qemu-guest-agent",
      "systemctl start qemu-guest-agent",
    ])
  })
  default = {}
}

variable "ssh_public_keys" {
  description = "SSH public keys injected into workloads (VMs via cloud-init, LXC via user_account)"
  type        = list(string)
  default     = []
}

variable "nameservers" {
  description = "DNS servers for workloads (empty list = inherit from template/DHCP)"
  type        = list(string)
  default     = ["1.1.1.1"]
}

variable "search_domain" {
  description = "DNS search domain for workloads"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# QEMU VM workloads — for_each keyed by VM name (stable, key-based identity)
# -----------------------------------------------------------------------------
variable "workloads" {
  description = "Map of QEMU VM workloads to clone from the template, keyed by VM name"
  type = map(object({
    vm_id           = optional(number)     # explicit VMID; auto-assigned if null
    cloud_init      = optional(bool, true) # false = clone a non-cloud-init template (no initialization block)
    cores           = optional(number, 2)
    sockets         = optional(number, 1)
    cpu_type        = optional(string, "host")
    memory          = optional(number, 2048) # MB (max / dedicated)
    balloon_minimum = optional(number, 0)    # MB; 0 = ballooning OFF, >0 = balloon floor (enables ballooning)
    disk_size       = optional(number, 20)   # GB (only applied when cloud_init = true)
    disk_datastore  = optional(string)       # cloud_init: disk datastore; non-cloud: clone target datastore
    ip_address      = optional(string)       # CIDR (required when cloud_init = true) — never DHCP
    gateway         = optional(string)
    bridge          = optional(string, "vmbr0")
    tags            = optional(list(string), []) # extra per-VM tags (merged with mandatory tags)
    password        = optional(string)           # per-VM cloud-init password; falls back to var.ci_password
    agent_enabled   = optional(bool)             # per-VM QEMU agent toggle; falls back to var.qemu_agent_enabled
    on_boot         = optional(bool, true)
    full_clone      = optional(bool, true)
    started         = optional(bool, false)
  }))
  default = {}
}

# -----------------------------------------------------------------------------
# LXC container workloads — for_each keyed by container name
# -----------------------------------------------------------------------------
variable "lxc_workloads" {
  description = "Map of LXC containers created from the vztmpl OS template, keyed by container name"
  type = map(object({
    vm_id          = optional(number) # explicit VMID; auto-assigned if null
    cores          = optional(number, 1)
    memory         = optional(number, 512) # MB
    swap           = optional(number, 512) # MB
    disk_size      = optional(number, 8)   # GB
    disk_datastore = optional(string)      # defaults to default_datastore
    ip_address     = string                # CIDR or "dhcp"
    gateway        = optional(string)
    bridge         = optional(string, "vmbr0")
    os_type        = optional(string, "ubuntu")
    unprivileged   = optional(bool, true)
    password       = optional(string) # root password (optional if using SSH keys)
    tags           = optional(list(string), [])
    started        = optional(bool, true)
    on_boot        = optional(bool, true)
  }))
  default = {}
}
