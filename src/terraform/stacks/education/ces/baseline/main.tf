#-------------------------------------------------------------------------------
# MongoDB upgrade (POC)
#-------------------------------------------------------------------------------
# Upgrades the MongoDB VMs listed in mongo_vms, which must already exist. A VM without MongoDB
# installed is also bootstrapped when it has install_mongodb = true.

terraform {
  required_version = ">= 1.9.4"
  backend "azurerm" {}
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.22.0"
    }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
  tenant_id                       = var.tenant_id
  subscription_id                 = var.subscription_id
}

# Provided by backend/<subscription>.tfvars
variable "tenant_id" {}
variable "subscription_id" {}
variable "client_id" {}
variable "resource_group_name" {}
variable "storage_account_name" {}
variable "container_name" {}

variable "mongo_vms" {
  description = "Existing MongoDB VMs to upgrade, keyed by a short name"
  type = map(object({
    hostname        = string
    resource_group  = string
    mongo_version   = string
    mongo_set_fcv   = optional(bool, false)
    install_mongodb = optional(bool, false)
    run_id          = optional(string, "1")
  }))
}

variable "mongo_admin_password" {
  description = "MongoDB admin password, only used for VMs with install_mongodb = true (e.g. TF_VAR_mongo_admin_password)"
  type        = string
  default     = null
  sensitive   = true
}

variable "mongo_backup_password" {
  description = "MongoDB backup password, only used for VMs with install_mongodb = true (e.g. TF_VAR_mongo_backup_password)"
  type        = string
  default     = null
  sensitive   = true
}

variable "mongo_release_order" {
  description = "Ordered MongoDB release series that can be stepped through; append new series at the end"
  type        = list(string)
  default     = ["6.0", "7.0", "8.0", "8.2", "8.3"]
}

variable "mongo_pbm_min_version" {
  description = "Minimum PBM version after a MongoDB upgrade; PBM is upgraded only if older. Empty disables"
  type        = string
  default     = "2.11.0"
}

locals {
  tags = {
    market        = "edu"
    product       = "ces"
    team          = "edu_ces"
    resource_type = "mongo-upgrade"
  }
}

#-------------------------------------------------------------------------------
# Modules
#-------------------------------------------------------------------------------
module "mongo_upgrade" {
  source   = "../../../../modules/az_mongo_upgrade/v1"
  for_each = var.mongo_vms

  virtual_machine_name  = each.value.hostname
  resource_group_name   = each.value.resource_group
  mongo_version         = each.value.mongo_version
  mongo_set_fcv         = each.value.mongo_set_fcv
  install_mongodb       = each.value.install_mongodb
  mongo_admin_password  = var.mongo_admin_password
  mongo_backup_password = var.mongo_backup_password
  run_id                = each.value.run_id
  mongo_release_order   = var.mongo_release_order
  pbm_min_version       = var.mongo_pbm_min_version
  tags                  = local.tags
}

output "status_commands" {
  description = "Commands to check the result of each upgrade"
  value       = { for k, m in module.mongo_upgrade : k => m.status_command }
}
