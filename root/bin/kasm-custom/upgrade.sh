#!/usr/bin/env bash
set -e

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

TIMESTAMP=$(date +%s)
LOGFILE="../kasm_upgrade_${TIMESTAMP}.log"
function notify_err() {
  echo "An error has occurred please review the log at ${LOGFILE}"
}
function cleanup_log() {
  rm -f ${LOGFILE}
}
trap notify_err ERR
exec &> >(tee ${LOGFILE})

KASM_VERSION=$([ -n "${KASM_VERSION}" ] && echo "${KASM_VERSION}" || echo "1.15.1")
KASM_INSTALL_BASE=$([ -n "${KASM_HOME}" ] && echo "${KASM_HOME}" || echo "/opt/kasm/${KASM_VERSION}")
OFFLINE_INSTALL=$([ -n "${OFFLINE_INSTALL}" ] && echo "${OFFLINE_INSTALL}" || echo 'false')
PULL_IMAGES=$([ -n "${PULL_IMAGES}" ] && echo "${PULL_IMAGES}" || echo 'false')
PURGE_IMAGES=$([ -n "${PURGE_IMAGES}" ] && echo "${PURGE_IMAGES}" || echo 'false')
DATABASE_HOSTNAME=$([ -n "${DATABASE_HOSTNAME}" ] && echo "${DATABASE_HOSTNAME}" || echo 'false')
DB_PASSWORD=$([ -n "${DB_PASSWORD}" ] && echo "${DB_PASSWORD}" || echo 'false')
DATABASE_PORT=$([ -n "${DATABASE_PORT}" ] && echo "${DATABASE_PORT}" || echo 5432)
DATABASE_USER=$([ -n "${DATABASE_USER}" ] && echo "${DATABASE_USER}" || echo 'kasmapp')
DATABASE_NAME=$([ -n "${DATABASE_NAME}" ] && echo "${DATABASE_NAME}" || echo 'kasm')
REGISTRATION_TOKEN=$([ -n "${REGISTRATION_TOKEN}" ] && echo "${REGISTRATION_TOKEN}" || echo 'false')
DEFAULT_GUAC_TOKEN=$([ -n "${DEFAULT_GUAC_TOKEN}" ] && echo "${DEFAULT_GUAC_TOKEN}" || echo 'false')
DEFAULT_GUAC_ID=$([ -n "${DEFAULT_GUAC_ID}" ] && echo "${DEFAULT_GUAC_ID}" || echo '00000000-0000-0000-0000-000000000000')
DEFAULT_PROXY_LISTENING_PORT=$([ -n "${KASM_PORT}" ] && echo "${KASM_PORT}" || echo '443')
API_SERVER_HOSTNAME=$([ -n "${API_SERVER_HOSTNAME}" ] && echo "${API_SERVER_HOSTNAME}" || echo 'false')
ENABLE_LOSSLESS=$([ -n "${ENABLE_LOSSLESS}" ] && echo "${ENABLE_LOSSLESS}" || echo 'false')
USE_ROLLING=$([ -n "${USE_ROLLING}" ] && echo "${USE_ROLLING}" || echo 'false')
CHECK_DISK=$([ -n "${CHECK_DISK}" ] && echo "${CHECK_DISK}" || echo 'true')

ARGS=("$@")

CURRENT_VERSION=$(readlink -f /opt/kasm/current | awk -F'/' '{print $4}')
CURRENT_MAJOR_VERSION=$(echo ${CURRENT_VERSION} | awk -F'\\.' '{print $1}')
CURRENT_MINOR_VERSION=$(echo ${CURRENT_VERSION} | awk -F'\\.' '{print $2}')
CUSTOM_SCRIPT_PATH="$(
  cd "$(dirname "$0")"
  pwd -P
)"
SCRIPT_PATH="$(
  cd "/kasm_release/"
  pwd -P
)"
KASM_RELEASE="$(realpath $SCRIPT_PATH)"
ARCH=$(uname -m)
DISK_SPACE=50000000000

# Functions
function gather_vars() {
  ARCH=$(uname -m)
  if [ "${DB_PASSWORD}" == "false" ]; then
    DB_PASSWORD=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.database.password' /opt/kasm/${CURRENT_VERSION}/conf/app/api.app.config.yaml)
  fi
  MANAGER_TOKEN=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.manager.token' /opt/kasm/${CURRENT_VERSION}/conf/app/agent.app.config.yaml)
  MANAGER_HOSTNAME=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.manager.hostnames.[0]' /opt/kasm/${CURRENT_VERSION}/conf/app/agent.app.config.yaml)
  SERVER_ID=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.agent.server_id' /opt/kasm/${CURRENT_VERSION}/conf/app/agent.app.config.yaml)
  PUBLIC_HOSTNAME=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.agent.public_hostname' /opt/kasm/${CURRENT_VERSION}/conf/app/agent.app.config.yaml)
  MANAGER_ID=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.manager.manager_id' /opt/kasm/${CURRENT_VERSION}/conf/app/api.app.config.yaml)
  SERVER_HOSTNAME=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.server.server_hostname' /opt/kasm/${CURRENT_VERSION}/conf/app/api.app.config.yaml)
  REDIS_PASSWORD=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.redis.redis_password' /opt/kasm/${CURRENT_VERSION}/conf/app/api.app.config.yaml)
  if [ "${DATABASE_HOSTNAME}" == "false" ]; then
    DATABASE_HOSTNAME=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.database.host' /opt/kasm/${CURRENT_VERSION}/conf/app/api.app.config.yaml)
  fi
  DB_IMAGE_NAME=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.services.db.image' /opt/kasm/${CURRENT_VERSION}/docker/.conf/docker-compose-db.yaml)
  DATABASE_USER=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.database.username' /opt/kasm/${CURRENT_VERSION}/conf/app/api.app.config.yaml)
  DATABASE_NAME=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.database.name' /opt/kasm/${CURRENT_VERSION}/conf/app/api.app.config.yaml)
  if [ -f "/opt/kasm/${CURRENT_VERSION}/conf/app/kasmguac.app.config.yaml" ] && ([ "${ROLE}" == "guac" ] || [ -z "${ROLE}" ]); then
    DEFAULT_GUAC_TOKEN=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.api.token' /opt/kasm/${CURRENT_VERSION}/conf/app/kasmguac.app.config.yaml)
    DEFAULT_GUAC_ID=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} '.kasmguac.id' /opt/kasm/${CURRENT_VERSION}/conf/app/kasmguac.app.config.yaml)
  fi
}

function stop_kasm() {
  /opt/kasm/bin/stop
}

function start_kasm() {
  /opt/kasm/bin/start
}

function backup_db() {
  mkdir -p /opt/kasm/backups/
  # Hotfix in case we have old paths for dumping DB
  sed -i 's/tmp/backup/g' /opt/kasm/${CURRENT_VERSION}/bin/utils/db_backup
  # Run backup
  if [ "${ROLE}" == "db" ] || [ -z "${ROLE}" ]; then
    bash /opt/kasm/${CURRENT_VERSION}/bin/utils/db_backup -f /opt/kasm/backups/kasm_db_backup.tar -p /opt/kasm/${CURRENT_VERSION}/
  else
    if [ "${CURRENT_MAJOR_VERSION}" == "1" ] && [ "${CURRENT_MINOR_VERSION}" -le "10" ]; then
      # Kasm versions earlier than 1.11.0 didn't have a backup utility that worked with remote databases
      bash ${SCRIPT_PATH}/bin/utils/db_backup -f /opt/kasm/backups/kasm_db_backup.tar -p /opt/kasm/${CURRENT_VERSION}/ -q "${DATABASE_HOSTNAME}" -c ${DATABASE_USER} -j ${DATABASE_NAME}
    else
      bash /opt/kasm/${CURRENT_VERSION}/bin/utils/db_backup -f /opt/kasm/backups/kasm_db_backup.tar -p /opt/kasm/${CURRENT_VERSION}/ -q "${DATABASE_HOSTNAME}"
    fi
  fi
  if [ ! -f "/opt/kasm/backups/kasm_db_backup.tar" ]; then
    echo "Error backing up database, please follow the instructions at https://kasmweb.com/docs/latest/upgrade/single_server_upgrade.html to manually upgrade your installation"
    start_kasm
    exit 1
  fi
}

function clean_install() {
  echo "Installing Kasm Workspaces ${KASM_VERSION}"
  bash ${CUSTOM_SCRIPT_PATH}/install.sh -b -N -B -e -H -D ${OPTS} ${LOSSLESS} -Q ${DB_PASSWORD} -M ${MANAGER_TOKEN} -L ${DEFAULT_PROXY_LISTENING_PORT} -c ${DATABASE_USER} -j ${DATABASE_NAME}
}

function db_install() {
  echo "Installing Kasm Workspaces ${KASM_VERSION}"
  if [ "${ROLE}" == "db" ]; then
    bash ${CUSTOM_SCRIPT_PATH}/install.sh -e -H -D ${OPTS} -S db -Q ${DB_PASSWORD} -R ${REDIS_PASSWORD} -L ${DEFAULT_PROXY_LISTENING_PORT} -c ${DATABASE_USER} -j ${DATABASE_NAME}
  else
    bash ${CUSTOM_SCRIPT_PATH}/install.sh -N -B -e -H -D ${OPTS} -S init_remote_db -q "${DATABASE_HOSTNAME}" -Q "${DB_PASSWORD}" -R "${REDIS_PASSWORD}" -L ${DEFAULT_PROXY_LISTENING_PORT} -g "${DATABASE_MASTER_USER}" -G "${DATABASE_MASTER_PASSWORD}" -c ${DATABASE_USER} -j ${DATABASE_NAME}
  fi
}

function agent_install() {
  echo "Installing Kasm Workspaces ${KASM_VERSION}"
  bash ${CUSTOM_SCRIPT_PATH}/install.sh -b -N -B -e -H ${OPTS} ${ROLLING} -S agent -D -p ${PUBLIC_HOSTNAME} -m ${MANAGER_HOSTNAME} -M ${MANAGER_TOKEN} -L ${DEFAULT_PROXY_LISTENING_PORT}
}

function app_install() {
  echo "Installing Kasm Workspaces ${KASM_VERSION}"
  bash ${CUSTOM_SCRIPT_PATH}/install.sh -N -B -e -H ${OPTS} -S app -D -q ${DATABASE_HOSTNAME} -Q ${DB_PASSWORD} -R ${REDIS_PASSWORD} -L ${DEFAULT_PROXY_LISTENING_PORT} -c ${DATABASE_USER} -j ${DATABASE_NAME}
}

function proxy_install() {
  echo "Installing Kasm Workspaces ${KASM_VERSION}"
  if [ "${API_SERVER_HOSTNAME}" == "false" ]; then
    echo "FATAL: option -n|--api-hostname is required for the proxy role"
    cleanup_log
    exit 1
  fi
  bash ${CUSTOM_SCRIPT_PATH}/install.sh -e -H ${OPTS} -S proxy -L ${DEFAULT_PROXY_LISTENING_PORT} -n ${API_SERVER_HOSTNAME}
}

function guac_install() {
  echo "Installing Kasm Workspaces ${KASM_VERSION}"
  if [ ! -z "${SERVICE_IMAGE_TARFILE}" ]; then
    OPTS="-s ${SERVICE_IMAGE_TARFILE}"
  fi
  if [ "${API_SERVER_HOSTNAME}" == "false" ]; then
    echo "FATAL: option -n|--api-hostname is required for the guac role"
    exit 1
  fi
  if [ "${REGISTRATION_TOKEN}" == "false" ]; then
    echo "FATAL: option -k|--registration-token is required for the guac role"
    exit 1
  fi
  bash ${CUSTOM_SCRIPT_PATH}/install.sh -e -H ${OPTS} -S guac -L ${DEFAULT_PROXY_LISTENING_PORT} -n ${API_SERVER_HOSTNAME} -k ${REGISTRATION_TOKEN} -p ${PUBLIC_HOSTNAME} -l ${DEFAULT_GUAC_TOKEN}
}

function modify_agent_configs() {
  ${SCRIPT_PATH}/bin/utils/yq_${ARCH} -i '.agent.server_id = "'${SERVER_ID}'"' /opt/kasm/${KASM_VERSION}/conf/app/agent.app.config.yaml
  ${SCRIPT_PATH}/bin/utils/yq_${ARCH} -i '.agent.public_hostname = "'${PUBLIC_HOSTNAME}'"' /opt/kasm/${KASM_VERSION}/conf/app/agent.app.config.yaml
  # There may be multiple manager hostnames we want to populate all of them.
  MANAGER_HOSTNAMES=$(${SCRIPT_PATH}/bin/utils/yq_${ARCH} -o j '.manager.hostnames' /opt/kasm/${CURRENT_VERSION}/conf/app/agent.app.config.yaml)
  ${SCRIPT_PATH}/bin/utils/yq_${ARCH} -i ".manager.hostnames |= ${MANAGER_HOSTNAMES}" /opt/kasm/${KASM_VERSION}/conf/app/agent.app.config.yaml
}

function modify_api_configs() {
  ${SCRIPT_PATH}/bin/utils/yq_${ARCH} -i '.manager.manager_id = "'${MANAGER_ID}'"' /opt/kasm/${KASM_VERSION}/conf/app/api.app.config.yaml
  ${SCRIPT_PATH}/bin/utils/yq_${ARCH} -i '.server.server_hostname = "'${SERVER_HOSTNAME}'"' /opt/kasm/${KASM_VERSION}/conf/app/api.app.config.yaml
}

function modify_guac_configs() {
  if [ "${CURRENT_MAJOR_VERSION}" == "1" ] && [ "${CURRENT_MINOR_VERSION}" -ge "12" ]; then
    ${SCRIPT_PATH}/bin/utils/yq_${ARCH} -i '.kasmguac.id = "'${DEFAULT_GUAC_ID}'"' /opt/kasm/${KASM_VERSION}/conf/app/kasmguac.app.config.yaml
  fi
}

function copy_nginx() {
  if [ $(ls -A /opt/kasm/${CURRENT_VERSION}/conf/nginx/containers.d/) ]; then
    cp /opt/kasm/${CURRENT_VERSION}/conf/nginx/containers.d/* /opt/kasm/${KASM_VERSION}/conf/nginx/containers.d/
  fi
}

function restore_db() {
  if [ "${ROLE}" == "db" ] || [ -z "${ROLE}" ]; then
    /opt/kasm/${KASM_VERSION}/bin/utils/db_restore -a -f /opt/kasm/backups/kasm_db_backup.tar -p /opt/kasm/${KASM_VERSION} -c ${DATABASE_USER} -j ${DATABASE_NAME}
    /opt/kasm/${KASM_VERSION}/bin/utils/db_upgrade -p /opt/kasm/${KASM_VERSION}
  else
    /opt/kasm/${KASM_VERSION}/bin/utils/db_restore -a -f /opt/kasm/backups/kasm_db_backup.tar -p /opt/kasm/${KASM_VERSION} -q "${DATABASE_HOSTNAME}" -g "${DATABASE_MASTER_USER}" -G "${DATABASE_MASTER_PASSWORD}" -c ${DATABASE_USER} -j ${DATABASE_NAME}
    /opt/kasm/${KASM_VERSION}/bin/utils/db_upgrade -p /opt/kasm/${KASM_VERSION} -q "${DATABASE_HOSTNAME}"
  fi
}

function pull_images() {
  CLEAN_ARCH=$(uname -p | sed 's/aarch64/arm64/g' | sed 's/x86_64/amd64/g')
  if [ "${PURGE_IMAGES}" == "true" ] && [ "${PULL_IMAGES}" == "true" ]; then
    if [ -z "${ROLE}" ]; then
      echo "Purging old images from system"
      sudo docker exec kasm_db psql -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "SELECT name FROM images;" | xargs -L 1 sudo docker rmi || :
    elif [ "${ROLE}" == "agent" ]; then
      echo "Purging old images from system"
      docker run -e PGPASSWORD="${DB_PASSWORD}" --rm "${DB_IMAGE_NAME}" psql -h "${DATABASE_HOSTNAME}" -p "${DATABASE_PORT}" -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "SELECT name FROM images;" | xargs -L 1 sudo docker rmi || :
    fi
    if [ "${ROLE}" == "db" ] || [ -z "${ROLE}" ]; then
      sudo docker exec kasm_db psql -v ON_ERROR_STOP=on -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "DELETE FROM images;"
    elif [ "${ROLE}" == "remote_db" ]; then
      docker run -e PGPASSWORD="${DB_PASSWORD}" --rm "${DB_IMAGE_NAME}" psql -v ON_ERROR_STOP=on -h "${DATABASE_HOSTNAME}" -p "${DATABASE_PORT}" -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "DELETE FROM images;"
    fi
  elif [ "${PURGE_IMAGES}" == "false" ] && [ "${PULL_IMAGES}" == "true" ]; then
    if [ "${ROLE}" == "db" ] || [ -z "${ROLE}" ]; then
      sudo docker exec kasm_db psql -v ON_ERROR_STOP=on -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "UPDATE images set enabled = 'false';"
    elif [ "${ROLE}" == "remote_db" ]; then
      docker run -e PGPASSWORD="${DB_PASSWORD}" --rm "${DB_IMAGE_NAME}" psql -v ON_ERROR_STOP=on -h "${DATABASE_HOSTNAME}" -p "${DATABASE_PORT}" -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "UPDATE images set enabled = 'false';"
    fi
  fi
  if [ ! -z "${WORKSPACE_IMAGE_TARFILE}" ]; then
    echo "Adding offline Workspaces images"
    tar xf ${WORKSPACE_IMAGE_TARFILE} --strip-components=1 -C /opt/kasm/${KASM_VERSION}/conf/database/seed_data/ workspace_images/default_images_${CLEAN_ARCH}.yaml
  fi
  if [ ! -z "${WORKSPACE_IMAGE_TARFILE}" ] || [ "${PULL_IMAGES}" == "true" ]; then
    if [ -z "${ROLE}" ] || [ "${ROLE}" == "db" ]; then
      /opt/kasm/${KASM_VERSION}/bin/utils/db_init -s /opt/kasm/${KASM_VERSION}/conf/database/seed_data/default_images_${CLEAN_ARCH}.yaml
      start_kasm
    elif [ "${ROLE}" == "remote_db" ]; then
      /opt/kasm/${KASM_VERSION}/bin/utils/db_init -s /opt/kasm/${KASM_VERSION}/conf/database/seed_data/default_images_${CLEAN_ARCH}.yaml -q "${DATABASE_HOSTNAME}"
    fi
  fi
  if [ ! -z "${WORKSPACE_IMAGE_TARFILE}" ] && ([ -z "${ROLE}" ] || [ "${ROLE}" == "agent" ]); then
    echo "Extracting offline Workspace images"
    tar xf "${WORKSPACE_IMAGE_TARFILE}" -C "${KASM_RELEASE}"
    # install all kasm infrastructure images
    while IFS="" read -r image || [ -n "$image" ]; do
      echo "Loading image: $image"
      IMAGE_FILENAME=$(echo $image | sed -r 's#[:/]#_#g')
      docker load --input ${KASM_RELEASE}/workspace_images/${IMAGE_FILENAME}.tar
    done <${KASM_RELEASE}/workspace_images/images.txt
  elif [ "${PULL_IMAGES}" == "true" ]; then
    if [ -z "${ROLE}" ]; then
      if [ $(sudo docker exec kasm_db psql -v ON_ERROR_STOP=on -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "SELECT name FROM images WHERE enabled = true;" | sed '/^ *$/ d' | wc -l) -ne 0 ]; then
        echo "Pulling default Workspaces Images"
        sudo docker exec kasm_db psql -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "SELECT name FROM images WHERE enabled = true;" | xargs -L 1 sudo docker pull
      fi
    elif [ "${ROLE}" == "agent" ]; then
      if [ $(docker run -e PGPASSWORD="${DB_PASSWORD}" --rm "${DB_IMAGE_NAME}" psql -h "${DATABASE_HOSTNAME}" -p "${DATABASE_PORT}" -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "SELECT name FROM images WHERE enabled = true;" | sed '/^ *$/ d' | wc -l) -ne 0 ]; then
        echo "Pulling default Workspaces Images"
        docker run -e PGPASSWORD="${DB_PASSWORD}" --rm "${DB_IMAGE_NAME}" psql -h "${DATABASE_HOSTNAME}" -p "${DATABASE_PORT}" -U ${DATABASE_USER} -d ${DATABASE_NAME} -t -c "SELECT name FROM images WHERE enabled = true;" | xargs -L 1 sudo docker pull
      fi
    fi
  fi
}

function connection_proxy_db_init() {
  if [ -z "${ROLE}" ] || [ "${ROLE}" == "db" ]; then
    if [ "${CURRENT_MAJOR_VERSION}" == "1" ] && [ "${CURRENT_MINOR_VERSION}" -le "11" ]; then
      # Only seed connection proxy if 1.11 or below
      /opt/kasm/${KASM_VERSION}/bin/utils/db_init -s /opt/kasm/${KASM_VERSION}/conf/database/seed_data/default_connection_proxies.yaml
      start_kasm
    fi
  fi
}

function display_help() {
  CMD='\033[0;31m'
  NC='\033[0m'
  echo "Kasm Upgrader ${KASM_VERSION}"
  echo "Usage IE:"
  echo "${0} --add-images --proxy-port 443"
  echo ""
  echo "Flag                                        Description"
  echo "---------------------------------------------------------------------------------------------------------------"
  echo -e "| ${CMD}-h|--help${NC}                     | Display this help menu                                                      |"
  echo -e "| ${CMD}-L|--proxy-port${NC}               | Default Proxy Listening Port                                                |"
  echo -e "| ${CMD}-I|--no-images${NC}                | Don't seed or pull default Workspaces Images                                |"
  echo -e "| ${CMD}-U|--upgrade-images${NC}           | Upgrade Images to current set purging previous images                       |"
  echo -e "| ${CMD}-K|--add-images${NC}               | Ingest the latest images keeping old images in place                        |"
  echo -e "| ${CMD}-w|--offline-workspaces${NC}       | Path to the tar.gz workspace images offline installer                       |"
  echo -e "| ${CMD}-s|--offline-service${NC}          | Path to the tar.gz service images offline installer                         |"
  echo -e "| ${CMD}-S|--role${NC}                     | Role to Upgrade: [app|db|agent|remote_db|guac|proxy]                        |"
  echo -e "| ${CMD}-p|--public-hostname${NC}          | Agent/Component <IP/Hostname> used to register with deployment.             |"
  echo -e "| ${CMD}-g|--database-master-user${NC}     | Database master username required for remote DB                             |"
  echo -e "| ${CMD}-G|--database-master-password${NC} | Database master password required for remote DB                             |"
  echo -e "| ${CMD}-q|--db-hostname${NC}              | Database Hostname needed when upgrading agent and pulling images            |"
  echo -e "| ${CMD}-T|--db-port${NC}                  | Database port needed when upgrading agent and pulling images (default 5432) |"
  echo -e "| ${CMD}-Q|--db-password${NC}              | Database Password needed when upgrading agent and pulling images            |"
  echo -e "| ${CMD}-b|--no-check-disk${NC}            | Do not check disk space                                                     |"
  echo -e "| ${CMD}-n|--api-hostname${NC}             | Set API server hostname                                                     |"
  echo -e "| ${CMD}-A|--enable-lossless${NC}          | Enable lossless streaming option (1.12 and above)                           |"
  echo -e "| ${CMD}-O|--use-rolling-images${NC}       | Use rolling Workspaces images                                               |"
  echo -e "| ${CMD}-k|--registration-token${NC}       | Register a component with an existing deployment.                           |"
  echo "---------------------------------------------------------------------------------------------------------------"
}

function check_role() {
  if [ "${ROLE}" != "agent" ] && [ "${ROLE}" != "app" ] && [ "${ROLE}" != "db" ] && [ "${ROLE}" != "remote_db" ] && [ "${ROLE}" != "guac" ] && [ "${ROLE}" != "proxy" ]; then
    echo "Invalid Role Defined"
    display_help
    cleanup_log
    exit 1
  fi
}

# Command line opts
for index in "${!ARGS[@]}"; do
  case ${ARGS[index]} in
  -L | --proxy-port)
    DEFAULT_PROXY_LISTENING_PORT="${ARGS[index + 1]}"
    echo "Setting Default Listening Port as ${DEFAULT_PROXY_LISTENING_PORT}"
    ;;
  -S | --role)
    ROLE="${ARGS[index + 1]}"
    check_role
    echo "Setting Role as ${ROLE}"
    ;;
  -h | --help)
    display_help
    cleanup_log
    exit 0
    ;;
  -I | --no-images)
    PULL_IMAGES="false"
    ;;
  -U | --upgrade-images)
    PURGE_IMAGES="true"
    PULL_IMAGES="true"
    ;;
  -K | --add-images)
    PURGE_IMAGES="false"
    PULL_IMAGES="true"
    ;;
  -w | --offline-workspaces)
    WORKSPACE_IMAGE_TARFILE="${ARGS[index + 1]}"
    OFFLINE_INSTALL="true"

    if [ ! -f "$WORKSPACE_IMAGE_TARFILE" ]; then
      echo "FATAL: Workspace image tarfile does not exist: ${WORKSPACE_IMAGE_TARFILE}"
      cleanup_log
      exit 1
    fi

    echo "Setting workspace image tarfile to ${WORKSPACE_IMAGE_TARFILE}"
    ;;
  -s | --offline-service)
    SERVICE_IMAGE_TARFILE="${ARGS[index + 1]}"
    OFFLINE_INSTALL="true"
    PULL_IMAGES="false"

    if [ ! -f "$SERVICE_IMAGE_TARFILE" ]; then
      echo "FATAL: Service image tarfile does not exist: ${SERVICE_IMAGE_TARFILE}"
      cleanup_log
      exit 1
    fi

    echo "Setting service image tarfile to ${SERVICE_IMAGE_TARFILE}"
    ;;
  -g | --database-master-user)
    DATABASE_MASTER_USER="${ARGS[index + 1]}"
    echo "Using Database Master User ${DATABASE_MASTER_USER}"
    ;;
  -G | --database-master-password)
    DATABASE_MASTER_PASSWORD="${ARGS[index + 1]}"
    echo "Using Database Master Password from stdin -G"
    ;;
  -q | --db-hostname)
    DATABASE_HOSTNAME="${ARGS[index + 1]}"
    echo "Setting Database Hostname as ${DATABASE_HOSTNAME}"
    ;;
  -T | --db-port)
    DATABASE_PORT="${ARGS[index + 1]}"
    echo "Setting Database Port to ${DATABASE_PORT}"
    ;;
  -Q | --db-password)
    DB_PASSWORD="${ARGS[index + 1]}"
    echo "Setting Default Database Password from stdin -Q"
    ;;
  -n | --api-hostname)
    API_SERVER_HOSTNAME="${ARGS[index + 1]}"
    echo "Setting API Server Hostname as ${API_SERVER_HOSTNAME}"
    ;;
  -A | --enable-lossless)
    ENABLE_LOSSLESS="true"
    ;;
  -O | --use-rolling-images)
    USE_ROLLING="true"
    ;;
  -k | --registration-token)
    REGISTRATION_TOKEN="${ARGS[index + 1]}"
    ;;
  -b | --no-check-disk)
    CHECK_DISK="false"
    ;;
  -* | --*)
    echo "Unknown option ${ARG}"
    display_help
    cleanup_log
    exit 1
    ;;
  esac
done

# Check to ensure docker has enough disk space
if ([ -z "${ROLE}" ] || [ "${ROLE}" == "agent" ]) && [ "${CHECK_DISK}" == "true" ]; then
  DOCKER_DIR=$(docker info | awk -F': ' '/Docker Root Dir/ {print $2}')
  BYTES=$(df --output=avail -B 1 "${DOCKER_DIR}" | tail -n 1)
  if [ "${BYTES}" -lt "${DISK_SPACE}" ] && [ "${PULL_IMAGES}" == "true" ]; then
    echo "#############################################################"
    echo "# The upgrade has detected less than 50 Gigabytes free    #"
    echo "# in the directory used for Docker storage: ${DOCKER_DIR} #"
    echo "#############################################################"
    df -h ${DOCKER_DIR}
    printf "\n"
    echo "Using the default image set for Workspaces we reccomend at least"
    echo "50 Gigabytes of available space. This check can be disabled using"
    echo "the --no-check-disk upgrade flag or alternatively upgrading"
    echo "without seeding images using the --no-images install flag."
    read -e -p "Proceed with upgrade anyway (n/y)? " -i "n" choice
    case "$choice" in
    y | Y)
      echo "Bypassing disk check"
      ;;
    n | N)
      echo "Upgrade cancelled by user"
      cleanup_log
      exit 1
      ;;
    *)
      echo "Invalid Response"
      echo "Upgrade cannot continue"
      cleanup_log
      exit 1
      ;;
    esac
  fi
fi

# Set some installer variables based on flags passed
LOSSLESS=""
if [ "${ENABLE_LOSSLESS}" == "true" ]; then
  LOSSLESS="-A"
fi
ROLLING=""
if [ "${USE_ROLLING}" == "true" ]; then
  ROLLING="-O"
fi
if [ ! -z "${SERVICE_IMAGE_TARFILE}" ]; then
  OPTS="-s ${SERVICE_IMAGE_TARFILE} -I"
else
  OPTS="-I"
fi

# Perform upgrade
if [ -z "${ROLE}" ]; then
  gather_vars
  stop_kasm
  backup_db
  clean_install
  modify_agent_configs
  modify_api_configs
  modify_guac_configs
  copy_nginx
  restore_db
  start_kasm
  connection_proxy_db_init
  pull_images
  start_kasm
elif [ "${ROLE}" == "db" ]; then
  gather_vars
  stop_kasm
  backup_db
  db_install
  restore_db
  start_kasm
  connection_proxy_db_init
  pull_images
  start_kasm
elif [ "${ROLE}" == "remote_db" ]; then
  gather_vars
  stop_kasm
  backup_db
  db_install
  restore_db
  pull_images
elif [ "${ROLE}" == "agent" ]; then
  gather_vars
  stop_kasm
  agent_install
  modify_agent_configs
  copy_nginx
  start_kasm
  pull_images
  start_kasm
elif [ "${ROLE}" == "app" ]; then
  gather_vars
  stop_kasm
  app_install
  modify_api_configs
  start_kasm
elif [ "${ROLE}" == "guac" ]; then
  gather_vars
  stop_kasm
  guac_install
  modify_guac_configs
  start_kasm
elif [ "${ROLE}" == "proxy" ]; then
  stop_kasm
  proxy_install
  start_kasm
fi

printf "\n\n"
echo "Upgrade from ${CURRENT_VERSION} to ${KASM_VERSION} Complete"

cleanup_log
