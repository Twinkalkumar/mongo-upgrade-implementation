#!/usr/bin/env bash
# File:             src/terraform/modules/az_mongo_upgrade/v1/scripts/mongo_upgrade.sh
# Description:      Upgrades MongoDB on a CES MongoDB VM to MONGO_VERSION, one release at a time
#                   (following MONGO_RELEASE_ORDER). Run as root through a managed Run Command by
#                   the az_mongo_upgrade module.
#
#                   This script does NOT take a backup. Take one (or a data disk snapshot)
#                   before running it.
#
# Environment variables:
#   MONGO_VERSION        Target release series, e.g. 8.3
#   MONGO_RELEASE_ORDER  Ordered release series, space separated, e.g. "6.0 7.0 8.0 8.2 8.3"
#   MONGO_SET_FCV        "true" to raise featureCompatibilityVersion on the final step (default false)
#   PBM_MIN_VERSION      Upgrade Percona Backup for MongoDB only if older than this (empty = never)
#
# A server without MongoDB installed is bootstrapped first (data disk, install, configuration,
# replica set and users, from vm_mongo.sh), but only when MONGO_ALLOW_INSTALL is "true":
#   MONGO_ALLOW_INSTALL  "true" to allow installing MongoDB on a new server (default false)
#   MONGO_SERVER_NAME    Host name used for the replica set member
#   MONGO_ADMIN_USER / MONGO_ADMIN_PASS / MONGO_BACKUP_USER / MONGO_BACKUP_PASS   Users to create

#===============================================================================
# Logging
#===============================================================================
RESULT="FAILED"
LOG_DIR="/root/bootstrap/logs"
mkdir -p -- "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/mongo_upgrade_$(date +%Y%m%d_%H%M%S).log"

finish() {
    if [[ "${RESULT}" != "SUCCESS" ]]; then
        echo "--- last 30 lines of ${LOG_FILE} ---"
        tail -n 30 "${LOG_FILE}"
    fi
    echo "MONGO_UPGRADE_RESULT=${RESULT}"
}
trap finish EXIT

# Progress goes to stdout (captured by Run Command) and the log file; command output only to the log file
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "${LOG_FILE}"; }
run() { "$@" >>"${LOG_FILE}" 2>&1; }

#===============================================================================
# Input validation
#===============================================================================
exec 9>/var/lock/mongo_upgrade.lock
flock -n 9 || { log "ERROR: another mongo_upgrade.sh run is in progress"; exit 1; }

if [[ ! "${MONGO_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    log "ERROR: MONGO_VERSION must be a release series such as 8.0"
    exit 1
fi
if [[ -z "${MONGO_RELEASE_ORDER}" ]]; then
    log "ERROR: MONGO_RELEASE_ORDER must be set"
    exit 1
fi
MONGO_SET_FCV="${MONGO_SET_FCV:-false}"
PBM_MIN_VERSION="${PBM_MIN_VERSION:-}"
MONGO_ALLOW_INSTALL="${MONGO_ALLOW_INSTALL:-false}"

#===============================================================================
# Helper functions
#===============================================================================
# Admin credentials written by vm_mongo.sh during the initial bootstrap
INIT_JS="/root/mongo-init.js"

load_credentials() {
    if [[ ! -r "${INIT_JS}" ]]; then
        log "ERROR: ${INIT_JS} not found, cannot read the MongoDB admin credentials"
        return 1
    fi
    adminuser=$(sed -n "s/^const admin_user = '\(.*\)';$/\1/p" "${INIT_JS}")
    adminpass=$(sed -n "s/^const admin_pass = '\(.*\)';$/\1/p" "${INIT_JS}")
    if [[ -z "${adminuser}" || -z "${adminpass}" ]]; then
        log "ERROR: admin credentials not found in ${INIT_JS}"
        return 1
    fi
}

mongo_eval() {
    mongosh --quiet --username "${adminuser}" --password "${adminpass}" \
        --authenticationDatabase admin --eval "$1" 2>>"${LOG_FILE}"
}

mongo_installed_series() {
    mongod --version | awk '/db version/ { sub(/^v/, "", $3); split($3, v, "."); print v[1] "." v[2] }'
}

mongo_fcv() {
    mongo_eval 'db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1}).featureCompatibilityVersion.version'
}

mongo_wait_ready() {
    local i
    for i in {1..24}; do
        mongosh --quiet --eval "db.adminCommand('ping')" &>/dev/null && return 0
        sleep 5
    done
    return 1
}

release_index() {
    local want="$1" i=0 r
    shift
    for r in "$@"; do
        [[ "${r}" == "${want}" ]] && { echo "${i}"; return 0; }
        i=$((i + 1))
    done
    return 1
}

write_mongo_repo() {
    local series="$1"
    cat > "/etc/yum.repos.d/mongodb-org-${series}.repo" << EOF
[mongodb-org-${series}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/${series}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-${series}.asc
EOF
}

mongo_set_fcv() {
    local v="$1"
    [[ "$(mongo_fcv)" == "${v}" ]] && return 0
    log "Setting featureCompatibilityVersion to ${v}"
    mongo_eval "db.adminCommand({setFeatureCompatibilityVersion: '${v}', confirm: true})" >>"${LOG_FILE}"
}

upgrade_pbm_if_needed() {
    [[ -n "${PBM_MIN_VERSION}" ]] || return 0
    local installed
    installed=$(rpm -q --qf '%{VERSION}' percona-backup-mongodb 2>/dev/null) || return 0

    if [[ "$(printf '%s\n' "${PBM_MIN_VERSION}" "${installed}" | sort -V | head -n1)" == "${PBM_MIN_VERSION}" ]]; then
        log "PBM ${installed} meets the minimum ${PBM_MIN_VERSION}"
        return 0
    fi
    log "Upgrading PBM ${installed} (minimum ${PBM_MIN_VERSION})"
    run dnf upgrade -y percona-backup-mongodb || return 1
    run systemctl daemon-reload
}

upgrade_step() {
    local from="$1" to="$2"
    log "Upgrading MongoDB ${from} -> ${to}"

    # MongoDB requires FCV == current series before the next binary upgrade
    mongo_set_fcv "${from}" || { log "ERROR: could not set FCV ${from}"; return 1; }

    if [[ -f "/etc/yum.repos.d/mongodb-org-${from}.repo" ]]; then
        mv -f -- "/etc/yum.repos.d/mongodb-org-${from}.repo" "/root/mongodb-org-${from}.repo.bak"
    fi
    write_mongo_repo "${to}"
    run dnf clean all

    run systemctl stop mongod
    run dnf upgrade -y 'mongodb-org*' || { log "ERROR: package upgrade to ${to} failed, mongod is stopped"; return 1; }
    run systemctl daemon-reload
    run systemctl start mongod
    mongo_wait_ready || { log "ERROR: mongod did not start on ${to}"; return 1; }
    [[ "$(mongo_installed_series)" == "${to}" ]] || { log "ERROR: version check failed for ${to}"; return 1; }
    log "MongoDB is running ${to}"
}

#===============================================================================
# Install (new server only)
#===============================================================================
# print_message, the disk setup functions and run_once() are copied unchanged from vm_mongo.sh

# Decorate output
print_message() {
    local TYPE="$1"
    local MESSAGE="$2"
    local RESET="\033[0m"

    # Define colors and styles
    local BOLD="\033[1m"
    local UNDERLINE="\033[4m"
    local NORMAL="\033[0m"
    local RED="\033[0;31m"
    local GREEN="\033[0;32m"
    local YELLOW="\033[0;33m"
    local LIGHT_GRAY="\033[0;37m"
    local BRIGHT_RED="\033[1;31m"
    local BRIGHT_GREEN="\033[1;32m"
    local BRIGHT_YELLOW="\033[1;33m"
    local BRIGHT_BLUE="\033[1;34m"
    local BRIGHT_CYAN="\033[1;36m"
    local BABY_BLUE="\033[1;94m"
    local WHITE="\033[1;37m"

    # Define fixed-width format for status labels
    local STATUS_LABEL="[${GREEN}STATUS${RESET}]   "
    local WARNING_LABEL="[${YELLOW}WARNING${RESET}]  "
    local INFO_LABEL="[${LIGHT_GRAY}INFO${RESET}]     "
    local ERROR_LABEL="[${RED}ERROR${RESET}]    "
    local COMMAND_LABEL="[${BABY_BLUE}COMMAND${RESET}]  "

    case "$TYPE" in
        status)
            echo -e "${STATUS_LABEL}${BOLD}${WHITE}${MESSAGE}${RESET}"
            ;;
        warning)
            echo -e "${WARNING_LABEL}${BOLD}${WHITE}${MESSAGE}${RESET}"
            ;;
        info)
            echo -e "${INFO_LABEL}${BOLD}${WHITE}${MESSAGE}${RESET}"
            ;;
        error)
            echo -e "${ERROR_LABEL}${BOLD}${WHITE}${MESSAGE}${RESET}"
            ;;
        command)
            echo -e "${COMMAND_LABEL}${BOLD}${WHITE}${MESSAGE}${RESET}"
            ;;
        heading)
            echo -e "\n${BOLD}${UNDERLINE}${BRIGHT_CYAN}===== ${MESSAGE} =====${RESET}\n"
            ;;
        subheading)
            echo -e "\n${BOLD}${BRIGHT_CYAN}--- ${MESSAGE} ---${RESET}\n"
            ;;
        *)
            echo -e "${NORMAL}${MESSAGE}${RESET}"
            ;;
    esac
}

MOUNT_PATH=/data
LUN_ID="1"
LUN_PATH="/dev/disk/azure/scsi${LUN_ID}"

check_lun_path() {
    if [[ ! -d ${LUN_PATH} ]]; then
        echo "LUN path does not exist [LUN_PATH=${LUN_PATH}]"
        return 1
    fi
    return 0
}

get_disk_name() {
    DISK_NAME=$(ls -l ${LUN_PATH} | grep -v '^total' | awk -F '/' '{ print $NF }' | grep -i 'sd' | head -1)
    DISK_PATH="/dev/${DISK_NAME}"
}

check_disk_partition_mountpoint() {
    if parted -s ${DISK_PATH} print | grep -q "Partition Table: gpt"; then
        echo "Disk is already partitioned [DISK_PATH=${DISK_PATH}]"
        return 1
    elif [[ -d ${MOUNT_PATH} ]]; then
        echo "Mountpoint already exists [MOUNT_PATH=${MOUNT_PATH}]"
        return 1
    fi
    return 0
}

partition_and_format_disk() {
    parted ${DISK_PATH} --script mklabel gpt mkpart xfspart xfs 0% 100%
    partprobe ${DISK_PATH}
    PARTITION=$(blkid | grep "${DISK_PATH}[0-9]" | awk -F ':' '{ print $1 }')
    mkfs.xfs ${PARTITION}
}

create_mountpoint_and_mount() {
    if [[ ! -d ${MOUNT_PATH} ]]; then
        mkdir -p -- "${MOUNT_PATH}"
        mount ${PARTITION} "${MOUNT_PATH}"
    else
        echo "Mountpoint already exists!"
        return 1
    fi
    return 0
}

update_fstab() {
    UUID=$(blkid -s UUID -o value ${PARTITION})
    if ! grep -q "${UUID}" /etc/fstab; then
        cp -v -- /etc/fstab /etc/fstab.backup.$(date +%Y%m%d)
        echo "UUID=${UUID} ${MOUNT_PATH} xfs defaults,nofail 1 2" >> /etc/fstab
    else
        echo "UUID already exists in /etc/fstab"
    fi
}

disk_init() {
    check_lun_path || return 1
    get_disk_name
    check_disk_partition_mountpoint || return 1
    partition_and_format_disk
    create_mountpoint_and_mount || return 1
    update_fstab
    echo "Disk setup and mount complete"
}

run_once() {
print_message "subheading" "Running 'run once' components"
#------------------------------------------------------------------------------
# Install and tuning
#------------------------------------------------------------------------------
# Add MongoDB repository
print_message "command" "Adding MongoDB repository"
write_mongo_repo "${MONGO_VERSION}"

# Install application dependencies
print_message "command" "Installing dependencies"
dnf install \
    logrotate \
    wget \
    vim \
    policycoreutils-python-utils \
    checkpolicy -y

# Install MongoDB
print_message "command" "Installing MongoDB"
dnf install mongodb-org -y

# Update Kernel parameters
print_message "command" "Updating /etc/sysctl.d/99-mongo.conf"
cat > /etc/sysctl.d/99-mongo.conf << 'EOF'
net.core.somaxconn = 4096
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_max_syn_backlog = 4096
fs.file-max = 98000
kernel.pid_max = 64000
kernel.threads-max = 64000
vm.max_map_count = 128000
vm.swappiness=10
EOF

# Apply kernel changes
sysctl -p /etc/sysctl.d/99-mongo.conf

# Create systemd unit for disabling transparent huge pages
print_message "command" "Creating systemd unit for disabling transparent huge pages"
cat > /etc/systemd/system/disable-transparent-huge-pages.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null'
[Install]
WantedBy=basic.target
EOF

# Start disable-transparent-huge-pages
systemctl start disable-transparent-huge-pages

# Ensure disable-transparent-huge-pages starts at boot
systemctl enable disable-transparent-huge-pages

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
# Set defaults for MongoDB
# NOTE: The comments are used for progressively enabling features as we require
#       them during the bootstrap process
#       - #SEC# = Security
#       - #REP# = Replication
print_message "command" "Updating /etc/mongod.conf"
cat > /etc/mongod.conf << 'EOF'
# /etc/mongod.conf

systemLog:
    verbosity: 0 # 1-5 increase verbosity to include debug messages
    destination: file
    logAppend: true
    logRotate: reopen
    path: /var/log/mongodb/mongod.log

storage:
    dbPath: /data/mongo
    directoryPerDB: true

processManagement:
    timeZoneInfo: /usr/share/zoneinfo
    pidFilePath: /var/run/mongodb/mongod.pid

net:
    port: 27017
    bindIpAll: true

setParameter:
    diagnosticDataCollectionEnabled: false

#SEC#security:
#SEC#    keyFile: /data/mongo/mongo.key
#SEC#    authorization: enabled

#REP#replication:
#REP#    replSetName: rs0
EOF

# Setup log rotate
print_message "command" "Updating /etc/logrotate.d/mongod"
cat > /etc/logrotate.d/mongod << 'EOF'
/var/log/mongodb/mongod.log {
    daily
    rotate 30
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    create 0660 mongod mongod
    postrotate
        /bin/kill -s USR1 `cat /var/run/mongodb/mongod.pid 2> /dev/null`
    endscript
}
EOF


# Create override directory and file
print_message "command" "Creating systemd override for MongoDB"
MONGOD_UNIT=$(systemctl show mongod.service --property=FragmentPath | cut -d'=' -f2)
MONGOD_OVRD="${MONGOD_UNIT}.d"
mkdir -vp -- "${MONGOD_OVRD}"
cat > "${MONGOD_OVRD}/override.conf" << EOF
[Unit]
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
Restart=on-failure
EOF

# Reload systemd
systemctl daemon-reload

#------------------------------------------------------------------------------
# SELinux
#------------------------------------------------------------------------------
print_message "command" "SELinux udpates"
# Create cgroup policy for MongoDB
cat > /root/mongodb_cgroup_memory.te <<EOF
module mongodb_cgroup_memory 1.0;
require {
    type cgroup_t;
    type mongod_t;
    class dir search;
    class file { getattr open read };
}
#============= mongod_t ==============
allow mongod_t cgroup_t:dir search;
allow mongod_t cgroup_t:file { getattr open read };
EOF
checkmodule -M -m -o /root/mongodb_cgroup_memory.mod /root/mongodb_cgroup_memory.te
semodule_package -o /root/mongodb_cgroup_memory.pp -m /root/mongodb_cgroup_memory.mod
semodule -i /root/mongodb_cgroup_memory.pp

# Create filesystem access policy for MongoDB
cat > /root/mongodb_fs_access.te <<EOF
module mongodb_fs_access 1.0;
require {
    type mongod_t;
    type sysctl_net_t;
    type unlabeled_t;
    class dir search;
    class file { getattr open read };
}
#============= mongod_t ==============
allow mongod_t sysctl_net_t:dir search;
allow mongod_t sysctl_net_t:file { getattr open read };
allow mongod_t unlabeled_t:dir search;
EOF
checkmodule -M -m -o /root/mongodb_fs_access.mod /root/mongodb_fs_access.te
semodule_package -o /root/mongodb_fs_access.pp -m /root/mongodb_fs_access.mod
semodule -i /root/mongodb_fs_access.pp

# Update SELinux context on new directory
# mongod_var_lib_t  = data directory
# mongod_log_t      = log file directory
# mongod_var_run_t  = pid file directory
rm -rf -- "${MOUNT_PATH}/mongo"
mkdir -p ${MOUNT_PATH}/mongo
chown mongod:mongod -R ${MOUNT_PATH}/mongo
semanage fcontext -a -t mongod_var_lib_t "${MOUNT_PATH}/mongo.*"
chcon -Rv -u system_u -t mongod_var_lib_t "${MOUNT_PATH}/mongo"
restorecon -R -v "${MOUNT_PATH}/mongo"

#------------------------------------------------------------------------------
# Initialisation
#------------------------------------------------------------------------------
# Create MongoDB keyfile
print_message "command" "Creating MongoDB keyfile"
openssl rand -base64 756 > "${MOUNT_PATH}/mongo/mongo.key"
chown mongod:mongod "${MOUNT_PATH}/mongo/mongo.key"
chmod 400 "${MOUNT_PATH}/mongo/mongo.key"

# Restart MongoDB
systemctl restart mongod

# Ensure MongoDB starts at boot
systemctl enable mongod

# Disable MongoDB telemetry
print_message "command" "Disable Telemetry for MongoDB"
mongosh --nodb --eval "disableTelemetry()"

# Create MongoDB initialisation script
print_message "command" "Creating initialisation script /root/mongo-init.js"
cat > /root/mongo-init.js <<EOF
// Server
const db_server = 'mongodb://localhost:27017';

// Databases
const admin_db = connect(db_server + '/admin');

// Users
const admin_user = '${adminuser}';
const admin_pass = '${adminpass}';
const backup_user = '${backupuser}';
const backup_pass = '${backuppass}';

// Role - Percona Backup for MongoDB (PBM)
admin_db.createRole(
    {
        role: 'pbmAnyAction',
        privileges: [
            { resource: { anyResource: true }, actions: ['anyAction'] }
        ],
        roles: []
    }
);

// User - admin_user
admin_db.createUser(
    {
        user: admin_user,
        pwd: admin_pass,
        roles: [
            { role: 'root', db: 'admin' }
        ]
    }
);

// User - backup_user
admin_db.createUser(
    {
        user: backup_user,
        pwd: backup_pass,
        roles: [
            { role: 'pbmAnyAction', db: 'admin' },
            { role: 'readWrite', db: 'admin', collection: '' },
            { role: 'backup', db: 'admin' },
            { role: 'restore', db: 'admin' },
            { role: 'clusterMonitor', db: 'admin' }
        ],
        passwordDigestor: 'server'
    }
);
EOF

# Remove comments from the configuration file (REPLICATION)
echo -e "\nRemove comments from the configuration file (REPLICATION)\n"
sed -i 's/#REP#//' /etc/mongod.conf

# Restart MongoDB
echo -e "\nRestart MongoDB\n"
systemctl restart mongod

# Check if MongoDB has completed the restart, retry 5 times
# NOTE: This is necessary as the systemctl restart command returns before the
#       MongoDB instance is fully operational
echo -e "\nCheck if MongoDB has completed the restart, retry 5 times\n"
for i in {1..5}; do
    if mongosh --eval "db.adminCommand('ping')" &> /dev/null; then
        break
    fi
    echo "  - MongoDB is not ready, retrying in 5 seconds... [${i}/5]"
    sleep 5
done

# Initiate replica set
# NOTE: We must define '_id' and 'members' explicitly, as running 
#       'rs.initiate()' without arguments will result in an error
echo -e "\nInitiate replica set\n"
mongosh --eval "rs.initiate(
    {
        _id: 'rs0',
        members: [
            {_id: 0, host: '${servername}:27017'}
        ]
    }
)"

# Execute script
echo -e "\nExecute script\n"
mongosh --file /root/mongo-init.js

# Remove comments from the configuration file (SECURITY)
echo -e "\nRemove comments from the configuration file (SECURITY)\n"
sed -i 's/#SEC#//' /etc/mongod.conf

# Restart MongoDB
echo -e "\nRestart MongoDB\n"
systemctl restart mongod

# Ensure pbm-agent starts at boot
systemctl enable pbm-agent

# Export connection string for current session to run PBM commands without --mongo-uri
export PBM_MONGODB_URI="mongodb://${backupuser}:${backuppass}@localhost:27017/"
pbm config --file /root/pbm_config.yaml

echo "EXECUTED ON: $(date)" > /root/MONGO_BOOTSTRAP
}

# Wrapper around the code above for a server without MongoDB
install_mongodb() {
    if [[ "${MONGO_ALLOW_INSTALL}" != "true" ]]; then
        log "ERROR: MongoDB is not installed and installation is not allowed (set install_mongodb = true)"
        return 1
    fi
    local v
    for v in MONGO_SERVER_NAME MONGO_ADMIN_USER MONGO_ADMIN_PASS MONGO_BACKUP_USER MONGO_BACKUP_PASS; do
        if [[ -z "${!v}" ]]; then
            log "ERROR: ${v} must be set to install MongoDB"
            return 1
        fi
    done

    log "MongoDB is not installed, installing ${MONGO_VERSION}"

    # Names used by run_once()
    servername="${MONGO_SERVER_NAME}"
    adminuser="${MONGO_ADMIN_USER}"
    adminpass="${MONGO_ADMIN_PASS}"
    backupuser="${MONGO_BACKUP_USER}"
    backuppass="${MONGO_BACKUP_PASS}"

    disk_init >>"${LOG_FILE}" 2>&1
    if ! mountpoint -q "${MOUNT_PATH}"; then
        log "ERROR: ${MOUNT_PATH} is not a mounted data disk"
        return 1
    fi
    # run_once() starts with rm -rf of the data directory, so never run it over existing data
    if [[ -n "$(ls -A "${MOUNT_PATH}/mongo" 2>/dev/null)" ]]; then
        log "ERROR: ${MOUNT_PATH}/mongo is not empty, refusing to overwrite existing data"
        return 1
    fi

    log "Running the first-time setup from vm_mongo.sh (details in ${LOG_FILE})"
    run_once >>"${LOG_FILE}" 2>&1
    chmod 600 "${INIT_JS}"

    mongo_wait_ready || { log "ERROR: mongod did not start"; return 1; }
    load_credentials || return 1
    [[ "$(mongo_eval 'db.runCommand({ping: 1}).ok')" == "1" ]] || { log "ERROR: cannot log in as the MongoDB admin user"; return 1; }
    log "MongoDB ${MONGO_VERSION} installed"
}

#===============================================================================
# Upgrade
#===============================================================================
upgrade_mongodb() {
    local -a order
    read -ra order <<< "${MONGO_RELEASE_ORDER}"
    local target="${MONGO_VERSION}" current c_idx t_idx k

    load_credentials || return 1
    systemctl is-active --quiet mongod || { log "ERROR: mongod is not running"; return 1; }

    current=$(mongo_installed_series)
    c_idx=$(release_index "${current}" "${order[@]}") || { log "ERROR: installed ${current} is not in MONGO_RELEASE_ORDER"; return 1; }
    t_idx=$(release_index "${target}"  "${order[@]}") || { log "ERROR: target ${target} is not in MONGO_RELEASE_ORDER"; return 1; }

    if (( t_idx < c_idx )); then
        log "ERROR: downgrade ${current} -> ${target} is not supported"
        return 1
    fi
    if (( t_idx == c_idx )); then
        log "MongoDB is already on ${current}"
        if [[ "${MONGO_SET_FCV}" == "true" ]]; then
            mongo_set_fcv "${target}" || { log "ERROR: could not set FCV ${target}"; return 1; }
        fi
        return 0
    fi

    log "MongoDB upgrade ${current} -> ${target} (steps: ${order[*]:c_idx+1:t_idx-c_idx})"

    [[ "$(mongo_eval 'rs.status().myState')" == "1" ]] || { log "ERROR: node is not PRIMARY"; return 1; }

    # Stop DR restores mid-upgrade; the job is put back once the upgrade succeeds
    local restore_cron="/etc/cron.d/pbm-restore" paused="/root/pbm-restore.cron.paused"
    [[ -f "${restore_cron}" ]] && mv -f -- "${restore_cron}" "${paused}"

    run systemctl stop pbm-agent

    for (( k = c_idx + 1; k <= t_idx; k++ )); do
        upgrade_step "${order[k-1]}" "${order[k]}" || return 1
    done

    upgrade_pbm_if_needed || { log "ERROR: PBM upgrade failed"; return 1; }
    run systemctl start pbm-agent
    if [[ -r /etc/sysconfig/pbm-cron ]]; then
        . /etc/sysconfig/pbm-cron
        run pbm config --force-resync --wait
    fi
    [[ -f "${paused}" ]] && mv -f -- "${paused}" "${restore_cron}"

    # Intermediate FCVs are raised by upgrade_step; only the last one is optional
    if [[ "${MONGO_SET_FCV}" == "true" ]]; then
        mongo_set_fcv "${target}" || { log "ERROR: could not set FCV ${target}"; return 1; }
    fi

    echo "UPGRADED ${current} -> ${target} ON: $(date)" >> /root/MONGO_UPGRADE
}

if ! rpm -q mongodb-org-server &>/dev/null; then
    install_mongodb || { log "MongoDB installation failed"; exit 1; }
fi

upgrade_mongodb || { log "MongoDB upgrade failed; pbm-agent and the DR restore cron may be left stopped/paused until it is re-run"; exit 1; }

log "Done: MongoDB $(mongo_installed_series), FCV $(mongo_fcv)"
RESULT="SUCCESS"
