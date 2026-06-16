terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.109"
    }
  }

  # The Terraform backend block CANNOT use variables/tfvars (it is initialized
  # before variables load). All per-deployment VALUES — bucket, key, region,
  # endpoint, credentials — are supplied via backend.hcl (partial configuration):
  #   terraform init -backend-config=backend.hcl
  # Only the constant Ceph RadosGW behavior flags are kept here.
  backend "s3" {
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true # RadosGW/RustFS reject AWS SDK v2 checksum trailers
    encrypt                     = false
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # SSH is only needed to upload cloud-config snippets (use_cloud_config = true).
  dynamic "ssh" {
    for_each = var.proxmox_ssh != null ? [var.proxmox_ssh] : []
    content {
      username    = ssh.value.username
      private_key = ssh.value.private_key_file != null ? file(pathexpand(ssh.value.private_key_file)) : null
      agent       = ssh.value.agent

      dynamic "node" {
        for_each = ssh.value.node_address != null ? [1] : []
        content {
          name    = var.proxmox_node
          address = ssh.value.node_address
        }
      }
    }
  }
}
