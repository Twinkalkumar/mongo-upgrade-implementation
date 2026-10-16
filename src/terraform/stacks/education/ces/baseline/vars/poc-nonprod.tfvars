# Existing MongoDB VM(s) to upgrade. Set hostname (the Azure VM name) and resource_group first.
# For a new server without MongoDB set install_mongodb = true and provide the passwords with
# TF_VAR_mongo_admin_password and TF_VAR_mongo_backup_password (12+ letters/numbers).
mongo_vms = {
  "mdb1" = {
    hostname        = "REPLACE-WITH-POC-MONGO-VM-NAME"
    resource_group  = "REPLACE-WITH-POC-RESOURCE-GROUP"
    mongo_version   = "8.0"
    mongo_set_fcv   = false
    install_mongodb = false
  }
}
