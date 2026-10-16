# File:             src/terraform/modules/az_mongo_upgrade/v1/main.tf
# Description:      Installs (new server only) and upgrades MongoDB on an existing VM by running
#                   scripts/mongo_upgrade.sh through a managed Run Command. A Run Command is used
#                   because a VM can only have one CustomScript extension and vm_mongo.tf already
#                   uses it for the bootstrap.
#
#                   No backup is taken. Take one (or a data disk snapshot) before applying.

variable "virtual_machine_name" {
  description = "Name of the existing MongoDB virtual machine"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group of the existing MongoDB virtual machine"
  type        = string
}

variable "mongo_version" {
  description = "Target MongoDB release series, e.g. 8.0"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.mongo_version))
    error_message = "mongo_version must be a release series such as \"8.0\"."
  }
}

variable "mongo_set_fcv" {
  description = "Raise featureCompatibilityVersion on the final step; intermediate steps always raise it"
  type        = bool
  default     = false
}

variable "mongo_release_order" {
  description = "Ordered MongoDB release series that can be stepped through; append new series at the end"
  type        = list(string)
  default     = ["6.0", "7.0", "8.0", "8.2", "8.3"]

  validation {
    condition     = alltrue([for r in var.mongo_release_order : can(regex("^[0-9]+\\.[0-9]+$", r))])
    error_message = "mongo_release_order entries must be release series such as \"8.0\"."
  }
}

variable "pbm_min_version" {
  description = "Minimum Percona Backup for MongoDB version; PBM is upgraded only if older. Empty disables"
  type        = string
  default     = "2.11.0"

  validation {
    condition     = var.pbm_min_version == "" || can(regex("^[0-9]+(\\.[0-9]+)*$", var.pbm_min_version))
    error_message = "pbm_min_version must be empty or a version such as \"2.11.0\"."
  }
}

variable "run_id" {
  description = "Change this value to run the script again without changing anything else"
  type        = string
  default     = "1"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.run_id))
    error_message = "run_id may only contain letters, numbers, dots, underscores and hyphens."
  }
}

variable "install_mongodb" {
  description = "Allow installing MongoDB when it is not installed (a new server); needs the admin and backup passwords"
  type        = bool
  default     = false
}

variable "mongo_admin_username" {
  description = "MongoDB admin user created when installing"
  type        = string
  default     = "mongo_admin"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.mongo_admin_username))
    error_message = "mongo_admin_username may only contain letters, numbers and underscores."
  }
}

variable "mongo_admin_password" {
  description = "MongoDB admin password used when installing"
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.mongo_admin_password == null || can(regex("^[A-Za-z0-9]{12,}$", var.mongo_admin_password))
    error_message = "mongo_admin_password must be at least 12 letters or numbers."
  }
}

variable "mongo_backup_username" {
  description = "MongoDB backup user created when installing"
  type        = string
  default     = "mongo_backup"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.mongo_backup_username))
    error_message = "mongo_backup_username may only contain letters, numbers and underscores."
  }
}

variable "mongo_backup_password" {
  description = "MongoDB backup password used when installing"
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.mongo_backup_password == null || can(regex("^[A-Za-z0-9]{12,}$", var.mongo_backup_password))
    error_message = "mongo_backup_password must be at least 12 letters or numbers."
  }
}

variable "tags" {
  description = "Tags to apply to all possible resources"
  type        = map(string)
  default     = {}
}

data "azurerm_linux_virtual_machine" "mongo" {
  name                = var.virtual_machine_name
  resource_group_name = var.resource_group_name
}

locals {
  upgrade_script = replace(file("${path.module}/scripts/mongo_upgrade.sh"), "\r\n", "\n")

  # Written to the VM and run with bash, whatever shell Run Command uses
  run_script_raw = <<-EOT
    #!/bin/sh
    # run_id: ${var.run_id}
    cat > /root/mongo_upgrade.sh <<'MONGO_UPGRADE_EOF'
    ${local.upgrade_script}
    MONGO_UPGRADE_EOF
    chmod 700 /root/mongo_upgrade.sh
    export MONGO_ADMIN_PASS MONGO_BACKUP_PASS
    MONGO_VERSION='${var.mongo_version}' MONGO_SET_FCV='${var.mongo_set_fcv}' MONGO_RELEASE_ORDER='${join(" ", var.mongo_release_order)}' PBM_MIN_VERSION='${var.pbm_min_version}' MONGO_ALLOW_INSTALL='${var.install_mongodb}' MONGO_SERVER_NAME='${var.virtual_machine_name}' MONGO_ADMIN_USER='${var.mongo_admin_username}' MONGO_BACKUP_USER='${var.mongo_backup_username}' bash /root/mongo_upgrade.sh
  EOT

  run_script = replace(local.run_script_raw, "\r\n", "\n")
}

resource "azurerm_virtual_machine_run_command" "mongo_upgrade" {
  name               = "mongo-upgrade"
  location           = data.azurerm_linux_virtual_machine.mongo.location
  virtual_machine_id = data.azurerm_linux_virtual_machine.mongo.id
  tags               = var.tags

  source {
    script = local.run_script
  }

  # Passwords are only sent when installing MongoDB on a new server
  dynamic "protected_parameter" {
    for_each = var.install_mongodb ? ["MONGO_ADMIN_PASS", "MONGO_BACKUP_PASS"] : []
    content {
      name  = protected_parameter.value
      value = protected_parameter.value == "MONGO_ADMIN_PASS" ? var.mongo_admin_password : var.mongo_backup_password
    }
  }

  lifecycle {
    precondition {
      condition     = contains(var.mongo_release_order, var.mongo_version)
      error_message = "mongo_version must be one of mongo_release_order."
    }

    precondition {
      condition     = !var.install_mongodb || (var.mongo_admin_password != null && var.mongo_backup_password != null)
      error_message = "mongo_admin_password and mongo_backup_password are required when install_mongodb is true."
    }
  }

  timeouts {
    create = "120m"
    update = "120m"
    delete = "30m"
  }
}

output "run_command_id" {
  value = azurerm_virtual_machine_run_command.mongo_upgrade.id
}

output "status_command" {
  description = "Shows the exit code and output of the last run"
  value       = "az vm run-command show --name ${azurerm_virtual_machine_run_command.mongo_upgrade.name} --vm-name ${var.virtual_machine_name} --resource-group ${var.resource_group_name} --expand instanceView"
}
