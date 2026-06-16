# proxmox-workloads

Terraform module that provisions **QEMU VMs and LXC containers on Proxmox VE**
using the [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox)
provider. It can build a cloud-init **template** from an image (or reuse an
existing one), clone VM workloads from it, and create LXC containers from a
vztmpl OS template.

## What this manages

- `proxmox_download_file` — downloads the VM cloud image and/or LXC vztmpl (optional)
- `proxmox_virtual_environment_vm` (template) — the base VM template (`template = true`), optional
- `proxmox_virtual_environment_vm` (workloads) — one VM per entry in `var.workloads`, cloned from the template
- `proxmox_virtual_environment_container` (workloads) — one LXC per entry in `var.lxc_workloads`
- `terraform_data.id_guard` — VMID conflict / template-source guardrails (see below)

## What this does **not** manage

- The Proxmox node, networking bridges, or storage pools — those must already exist.
- The S3 state bucket — it must exist before `init` (the backend won't create it).
- Firewall rules, HA groups, or backup jobs — add explicitly if you need them.

## Architecture

```
VMs:
  [build]  proxmox_download_file ─▶ template VM (template=true) ─┐
  [reuse]  var.vm_clone_template_id ────────────────────────────┤─clone─▶ workload VMs  (for_each)
                                                                 │
LXC:
  [build]  proxmox_download_file (vztmpl) ─┐
  [reuse]  var.lxc_template_file_id ───────┴─▶ LXC containers (operating_system) (for_each)
```

The VM template is **optional**: set `var.template` to build one, or
`var.vm_clone_template_id` to clone from a template that already exists on the
node (no download). Same choice for LXC via `var.lxc_template` /
`var.lxc_template_file_id`. Everything is one `terraform apply`.

## Prerequisites

- **Terraform** >= 1.6.0
- **Proxmox VE** 9.x (8.x mostly works; bpg targets 9.x)
- A **Proxmox API token** (`user@realm!tokenid=<uuid>`) with permission to create
  VMs, download files, and use the datastores (roughly: `VM.Allocate`, `VM.Config.*`,
  `VM.Clone`, `Datastore.AllocateSpace`, `Datastore.Audit`)
- A **directory datastore** with the **`import`** content type enabled (e.g. `local`)
  to receive the downloaded image — PVE 8.4+/9.x. ZFS pools cannot hold the source file.
- A **ZFS pool datastore** (e.g. `local-zfs`) for the VM disks.
- Access to the **Ceph RadosGW** S3 bucket used as the Terraform state backend, and
  the bucket (`my-terraform-state`) must already exist.
- An **SSH public key** to inject into workloads via cloud-init.

> ℹ️ **No SSH access to the node is required.** Disks are imported via `import_from`
> (a datastore reference), not a host path, so the provider works over the API alone.

## Files

| File                       | Purpose                                              |
| -------------------------- | ---------------------------------------------------- |
| `providers.tf`             | bpg/proxmox provider + S3/RadosGW backend config     |
| `variables.tf`             | Input variable declarations                          |
| `locals.tf`                | Derived values — sorted tag lists                    |
| `main.tf`                  | download → template → workload clone resources       |
| `outputs.tf`               | Output values                                        |
| `terraform.tfvars.example` | Example input values — copy to `terraform.tfvars`    |
| `backend.hcl.example`      | Example backend config — copy to `backend.hcl`       |

`terraform.tfvars` and `backend.hcl` are gitignored — never commit real values.

## Setup

### 1. Configure the state backend (Ceph RadosGW)

```fish
cp backend.hcl.example backend.hcl
# edit backend.hcl with your bucket, key, region, RadosGW endpoint, and credentials
```

> **Why backend.hcl and not `terraform.tfvars`?** Terraform's `backend` block is
> initialized *before* variables are loaded, so it **cannot use `var.*`/tfvars**.
> All backend *values* are supplied via `backend.hcl` (partial configuration);
> `providers.tf` keeps only the constant RadosGW behavior flags.

`backend.hcl` shape (all per-deployment values live here):

```hcl
bucket = "my-terraform-state"
key    = "proxmox-workloads/terraform.tfstate"
region = "us-east-1" # set to the RadosGW zonegroup api_name if you hit SignatureDoesNotMatch

endpoints = {
  s3 = "https://s3.example.com"
}

access_key = "..."
secret_key = "..."
```

Only the constant flags (`use_path_style`, `skip_s3_checksum`, the `skip_*` set,
`encrypt`) stay in `providers.tf` — they're RadosGW requirements, not per-deployment
values. `backend.hcl` is **required** at init (state won't resolve without it).

#### Required: disable AWS SDK checksums (RadosGW)

Terraform **1.11.2+** ignores `skip_s3_checksum` on `PutObject`, so saving state to
RadosGW fails with `XAmzContentSHA256Mismatch`. Force the AWS SDK back to
checksum-only-when-required via env vars (set once, persistently, in fish):

```fish
set -Ux AWS_REQUEST_CHECKSUM_CALCULATION when_required
set -Ux AWS_RESPONSE_CHECKSUM_VALIDATION when_required
```

(`-Ux` = universal + exported; persists across all sessions. Use `set -gx` for a
single session, or a `.envrc` to scope it to this directory.) Keep
`skip_s3_checksum = true` in `providers.tf` as well — these env vars are the extra
piece this Terraform version needs.

### 2. Configure inputs

```fish
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: connection, template, ssh keys, workloads
```

### 3. Initialize

```fish
terraform init -backend-config=backend.hcl
```

## Usage

```fish
terraform plan  -var-file=terraform.tfvars -out=tfplan-proxmox
terraform apply "tfplan-proxmox"
```

To destroy (⚠️ removes all VMs **and** the template):

```fish
terraform destroy -var-file=terraform.tfvars
```

## Inputs

### Connection

| Variable            | Type           | Description                                                |
| ------------------- | -------------- | ---------------------------------------------------------- |
| `proxmox_endpoint`  | string         | API endpoint, e.g. `https://pve.example.com:8006/`         |
| `proxmox_api_token` | string (sens.) | `user@realm!tokenid=<uuid>`                                |
| `proxmox_insecure`  | bool           | Skip TLS verification (true for self-signed certs)         |
| `proxmox_node`      | string         | Node hosting the template and workloads                    |

### Tagging

| Variable            | Type   | Description                                            |
| ------------------- | ------ | ------------------------------------------------------ |
| `environment`       | string | e.g. `dev`/`prod` — one environment per state          |
| `project`           | string | Project label (default `lab`)                          |
| `default_datastore` | string | Fallback disk datastore when not building a template   |

Every VM/LXC is tagged `environment-<env>`, `project-<project>`, `managed_by-terraform`
automatically (built sorted in `locals.tf`), plus any per-workload `tags`.

### VM template — build one **or** reuse an existing one (pick one)

**Build it** — set `var.template` (Terraform downloads the image):

```hcl
template = {
  name            = "ubuntu-2204-cloudinit"
  vm_id           = 9000
  image_url       = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  image_file_name = "jammy-server-cloudimg-amd64.qcow2" # see "Image filename / extension" below
  image_datastore = "local"     # DIRECTORY datastore with 'import' content
  disk_datastore  = "local-zfs" # ZFS pool for the disk
  disk_size       = 8
  checksum           = "<sha256-of-image>" # recommended
  checksum_algorithm = "sha256"
}
```

**Reuse it** — leave `template = null` and point at an existing template VMID
(no download, no image needed on disk beyond what the template already has):

```hcl
template             = null
vm_clone_template_id = 9000
```

The guardrail rejects setting both, or setting neither when `workloads` is non-empty.

#### Image filename / extension (`.img` vs `.qcow2`)

The `import` content type validates the **stored filename's extension** and only
accepts `.qcow2`, `.raw`, `.vmdk`, or `.ova` — **`.img` is rejected** (it's valid
only for the `iso` content type). Ubuntu's `*-cloudimg-amd64.img` files are
*actually* qcow2 despite the name, so download from the `.img` URL but set
`image_file_name` to a `.qcow2` name. Omitting it lets the filename default to the
URL's `.img` and fails with `HTTP 400 … invalid filename or wrong extension`.

### Cloud-init defaults

| Variable          | Type           | Description                                          |
| ----------------- | -------------- | ---------------------------------------------------- |
| `ci_user`         | string         | Default username (default `ubuntu`)                  |
| `ci_password`     | string (sens.) | Optional VM user password (default `null` = key-only)|
| `ssh_public_keys` | list(string)   | SSH keys injected into every workload                |
| `nameservers`     | list(string)   | DNS servers (default `["1.1.1.1"]`)                  |
| `search_domain`   | string         | DNS search domain (default `null`)                   |

### `workloads` — the VMs to create

A map **keyed by VM name** (the key becomes the VM name and its Terraform address):

```hcl
workloads = {
  "web-01" = {
    cores      = 2
    memory     = 4096            # MB
    disk_size  = 20             # GB
    ip_address = "10.0.0.11/24" # CIDR — never DHCP for workloads
    gateway    = "10.0.0.1"
    tags       = ["role-web"]
  }
  "db-01" = {
    cores      = 4
    memory     = 8192
    disk_size  = 40
    ip_address = "10.0.0.21/24"
    gateway    = "10.0.0.1"
    tags       = ["role-db"]
  }
}
```

Per-VM optional fields with defaults: `vm_id` (auto), `cloud_init` (true),
`sockets` (1), `cpu_type` (`host`), `balloon_minimum` (`0` = ballooning off; set >0
MB to enable a balloon floor up to `memory`), `disk_datastore` (template's /
`default_datastore`), `bridge` (`vmbr0`), `password` (per-VM cloud-init password;
falls back to `ci_password`), `agent_enabled` (per-VM QEMU agent toggle; falls back
to `qemu_agent_enabled`), `on_boot` (true), `full_clone` (true), `started` (true).

### Cloning a non-cloud-init template (`cloud_init = false`)

To clone a template that **isn't** cloud-init based (ISO install, a converted VM),
set `cloud_init = false` on the workload. Then:

- The `initialization` block is **omitted entirely** — no IP/user/keys are injected;
  the clone inherits the template's baked-in networking and credentials (configure
  them in-guest or in the template). `ip_address` is therefore not required.
- The `disk` block is **dropped** — the clone inherits the template's disk *as-is*
  (any interface, the template's size), avoiding `scsi0` mismatches. `disk_size` is
  ignored; resize with `qm resize` afterward if needed.
- Disk placement is steered by `disk_datastore` via the clone's `datastore_id`
  (omit to inherit the template's datastore).

Pair it with `vm_clone_template_id` pointing at your non-cloud template (and leave
the cloud-image `template` null), e.g.:

```hcl
template             = null
vm_clone_template_id = 9001        # your ISO-built template
workloads = {
  "legacy-01" = { cloud_init = false, cores = 2, memory = 4096, disk_datastore = "local-zfs" }
}
```

### QEMU guest agent

`qemu_agent_enabled` (default **`false`**) controls whether the agent is enabled
on VMs. Leave it `false` when your image has no `qemu-guest-agent` running — bpg
otherwise **blocks until a timeout** waiting for the agent to report IPs on every
started VM, slowing `plan`/`apply` and emitting `error waiting for network
interfaces from QEMU agent`. Set it `true` (globally, or per-VM via `agent_enabled`)
only once the guest actually runs the agent; that's also what populates the
`ipv4_addresses` output.

### Custom cloud-config vendor-data (`use_cloud_config`)

VMs always use bpg's structured `user_account` (username/keys/password). Set
`use_cloud_config = true` to *additionally* attach a per-VM `#cloud-config`
**vendor-data snippet** for things the structured form can't do — installing
`qemu-guest-agent`, extra packages, `runcmd`, etc. cloud-init **merges** vendor-data
with the user-data, so `user_account` is **preserved**. One snippet is created per
workload via `proxmox_virtual_environment_file` and referenced through
`initialization.vendor_data_file_id`.

Two requirements (enforced by a plan-time guardrail / Proxmox):

- **`proxmox_ssh`** must be set — snippets are uploaded over **SSH**, not the API.
  Provide a node SSH `username` + `private_key_file` path (or `agent = true`).
- The **`snippet_datastore`** (default `local`) must have the **Snippets** content
  type enabled in Proxmox.

```hcl
use_cloud_config  = true
snippet_datastore = "local"
proxmox_ssh = {
  username         = "root"
  private_key_file = "~/.ssh/id_ed25519" # path only — file() is called in providers.tf
}
cloud_config = {
  timezone = "Asia/Jakarta"
  packages = ["qemu-guest-agent", "net-tools", "curl"]
  runcmd   = ["systemctl enable --now qemu-guest-agent"]
}
```

Notes:
- Users/keys/password come from `user_account` (`ci_user`, `ssh_public_keys`,
  `password`/`ci_password`); the vendor-data snippet only adds packages/runcmd/timezone.
- Because the snippet installs the agent, pair it with `qemu_agent_enabled = true` —
  cloud-init starts the agent on first boot and bpg picks up the IPs.
- Like all cloud-init, vendor-data applies on **first boot** — editing it later
  won't reconfigure a VM that's already booted (recreate it to re-run first-boot).

### LXC containers — `lxc_workloads` (optional)

LXC containers are created from a **vztmpl OS template** (not by cloning the VM
template). Provide the OS template the same two ways:

```hcl
# Build it: download the vztmpl
lxc_template = {
  url       = "http://download.proxmox.com/images/system/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  datastore = "local"
}
# OR reuse one already on the node:
# lxc_template_file_id = "local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"

lxc_workloads = {
  "ct-dns-01" = {
    cores      = 1
    memory     = 512            # MB
    swap       = 512
    disk_size  = 8              # GB
    ip_address = "10.0.0.31/24"
    gateway    = "10.0.0.1"
    tags       = ["role-dns"]
    password   = "change-me"    # optional if SSH keys suffice; LXC user is always root
  }
}
```

Per-LXC optional defaults: `vm_id` (auto), `cores` (1), `memory` (512),
`swap` (512), `disk_size` (8), `disk_datastore` (`default_datastore`),
`bridge` (`vmbr0`), `os_type` (`ubuntu`), `unprivileged` (true),
`started` (true), `on_boot` (true). `ssh_public_keys` are injected via `user_account`.

## VMID guardrail

A central `terraform_data.id_guard` resource fails the **plan** (before any create)
when:

- a `vm_id` is declared more than once across `template` / `workloads` / `lxc_workloads`;
- a requested `vm_id` is already used on the cluster by a VM whose name this state
  does **not** manage (checked via `data "proxmox_virtual_environment_vms"`, queried
  live at plan time); or
- the template-source combination is invalid (both `template` and
  `vm_clone_template_id` set, or neither while `workloads` is non-empty — likewise for LXC).

Omit `vm_id` entirely to let Proxmox auto-assign the next free ID (never conflicts).

> ⚠️ The cluster data source is QEMU-focused, so an ID clash with an **LXC-only**
> container created outside Terraform may not be caught by the live check — the
> in-config duplicate check always applies. When in doubt, omit `vm_id`.

## Outputs

| Output          | Description                                                          |
| --------------- | ------------------------------------------------------------------- |
| `template_id`   | VMID of the VM template (built one, or `vm_clone_template_id`)       |
| `workloads`     | Map of VM name → `{ vm_id, node_name, ipv4_addresses }`             |
| `lxc_workloads` | Map of LXC name → `{ vm_id, node_name }`                            |

`ipv4_addresses` is reported by the QEMU guest agent — it stays empty unless
`qemu_agent_enabled = true` (or per-VM `agent_enabled = true`) **and** the guest is
actually running `qemu-guest-agent`. See "QEMU guest agent" above.

## `count` vs `for_each` and safe state changes

Workloads use **`for_each` keyed by VM name**, never `count`. This matters:

- The resource address is `proxmox_virtual_environment_vm.workload["web-01"]` — tied
  to the **name**, not a list index. Removing one workload from the map never shifts
  the others' addresses, so Terraform won't destroy/recreate unrelated VMs.
- `count` would address VMs by index (`[0]`, `[1]`); deleting a middle entry shifts
  every later index and triggers a cascade of destroy/recreate — unacceptable for VMs.

If you ever **rename** a workload key (or restructure), use a `moved {}` block so the
change is reviewed and applies for everyone — don't hand-edit state:

```hcl
moved {
  from = proxmox_virtual_environment_vm.workload["web-01"]
  to   = proxmox_virtual_environment_vm.workload["web-1"]
}
```

To **adopt an existing Proxmox VM** into management, use an `import {}` block (note
the quoted for_each key):

```hcl
import {
  to = proxmox_virtual_environment_vm.workload["web-01"]
  id = "pve/100" # <node>/<vmid>
}
```

Always `terraform plan` after a `moved`/`import` and confirm **zero diff**. Back up
state first with `terraform state pull > backup.tfstate`.

## Notes for future maintainers

- **Provider is `bpg/proxmox`, not telmate.** bpg can build the template from a cloud
  image in Terraform (telmate cannot) and is the actively maintained, PVE 9.x provider.
  Don't switch back without updating `CLAUDE.md`.
- **`template = true` is an in-place toggle** (bpg v0.100.0+) — it does not recreate the VM.
- **Tags are a list, built sorted** in `locals.tf`. The provider stores tags in canonical
  sorted order; an unsorted input list produces a perpetual diff. Keep the `sort()`.
- **Clone ordering** is expressed by referencing `proxmox_virtual_environment_vm.template.vm_id`
  in the workload `clone` block — not `depends_on`.
- **RadosGW backend requires `skip_s3_checksum = true` and `use_path_style = true`** in
  `providers.tf`. The AWS SDK v2 checksum trailers are rejected by RadosGW; path-style
  avoids needing wildcard DNS for the bucket. If you hit `SignatureDoesNotMatch`, set the
  backend `region` to the RadosGW zonegroup `api_name` instead of `us-east-1`.
- **ZFS is node-local.** A template on `local-zfs` exists only on its node; for multi-node
  clones use shared storage (Ceph/NFS) or pin workloads to the template's node.
- **`content_type = "import"`** must be enabled on the directory datastore receiving the
  image. Without it, the download fails.
