#!/usr/bin/env bash
# This script manages to deploy the infrastructure for the Atlassian Data Center products
#
# Usage:  install.sh [-c <config_file>] [-h]
# -c <config_file>: Terraform configuration file. The default value is 'config.tfvars' if the argument is not provided.
# -f : Auto-approve
# -h : provides help to how executing this script.
set -e
set -o pipefail
ROOT_PATH=$(cd $(dirname "${0}"); pwd)
SCRIPT_PATH="${ROOT_PATH}/scripts"
LOG_FILE="${ROOT_PATH}/logs/terraform-dc-install_$(date '+%Y-%m-%d_%H-%M-%S').log"
LOG_TAGGING="${ROOT_PATH}/logs/terraform-dc-asg-tagging_$(date '+%Y-%m-%d_%H-%M-%S').log"

ENVIRONMENT_NAME=
OVERRIDE_CONFIG_FILE=
DIFFERENT_ENVIRONMENT=1

source "${SCRIPT_PATH}/common.sh"

show_help(){
  if [ -n "${HELP_FLAG}" ]; then
cat << EOF
This script provisions the infrastructure for Atlassian Data Center products in AWS environment.
The infrastructure will be generated by terraform and state of the resources will be kept in a S3 bucket which will be provision by this script if is not existed.

Before installing the infrastructure make sure you have completed the configuration process and did all perquisites.
For more information visit https://github.com/atlassian-labs/data-center-terraform.
EOF

  fi
  echo
  echo "Usage:  ./install.sh [-c <config_file>] [-h]"
  echo "   -c <config_file>: Terraform configuration file. The default value is 'config.tfvars' if the argument is not provided."
  echo "   -h : provides help to how executing this script."
  echo
  exit 2
}

# Extract arguments
  CONFIG_FILE=
  HELP_FLAG=
  FORCE_FLAG=
  while getopts hf?c: name ; do
      case $name in
      h)    HELP_FLAG=1; show_help;;  # Help
      c)    CONFIG_FILE="${OPTARG}";; # Config file name to install - this overrides the default, 'config.tfvars'
      f)    FORCE_FLAG="-f";;         # Auto-approve
      ?)    log "Invalid arguments." "ERROR" ; show_help
      esac
  done

  shift $((${OPTIND} - 1))
  UNKNOWN_ARGS="$*"

# Validate the arguments.
process_arguments() {
  # set the default value for config file if is not provided
  if [ -z "${CONFIG_FILE}" ]; then
    CONFIG_FILE="${ROOT_PATH}/config.tfvars"
  else
    if [[ ! -f "${CONFIG_FILE}" ]]; then
      log "Terraform configuration file '${CONFIG_FILE}' not found!" "ERROR"
      show_help
    fi
  fi
  CONFIG_ABS_PATH="$(cd "$(dirname "${CONFIG_FILE}")"; pwd)/$(basename "${CONFIG_FILE}")"
  OVERRIDE_CONFIG_FILE="-var-file=${CONFIG_ABS_PATH}"
  
  log "Terraform will use '${CONFIG_ABS_PATH}' to install the infrastructure."

  if [ -n "${UNKNOWN_ARGS}" ]; then
    log "Unknown arguments:  ${UNKNOWN_ARGS}" "ERROR"
    show_help
  fi
}


# Make sure the infrastructure config file is existed and contains the valid data
verify_configuration_file() {
  log "Verifying the config file."

  HAS_VALIDATION_ERR=
  # Make sure the config values are defined
  set +e
  INVALID_CONTENT=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep '<\|>')
  set -e
  ENVIRONMENT_NAME=$(get_variable 'environment_name' "${CONFIG_ABS_PATH}")
  REGION=$(get_variable 'region' "${CONFIG_ABS_PATH}")

  if [ "${#ENVIRONMENT_NAME}" -gt 24 ]; then
    log "The environment name '${ENVIRONMENT_NAME}' is too long(${#ENVIRONMENT_NAME} characters)." "ERROR"
    log "Please make sure your environment name is less than 24 characters."
    HAS_VALIDATION_ERR=1
  fi

  if [ -n "${INVALID_CONTENT}" ]; then
    log "Configuration file '${CONFIG_ABS_PATH##*/}' is not valid." "ERROR"
    log "Terraform uses this file to generate customised infrastructure for '${ENVIRONMENT_NAME}' on your AWS account."
    log "Please modify '${CONFIG_ABS_PATH##*/}' using a text editor and complete the configuration. "
    log "Then re-run the install.sh to deploy the infrastructure."
    log "${INVALID_CONTENT}"
    HAS_VALIDATION_ERR=1
  fi
  INSTALL_BAMBOO=$(get_product "bamboo" "${CONFIG_ABS_PATH}")
  if [ -n "${INSTALL_BAMBOO}" ]; then
    # check license and admin password
    export POPULATED_LICENSE=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep 'bamboo_license')
    export POPULATED_ADMIN_PWD=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep 'bamboo_admin_password')

    if [ -z "${POPULATED_LICENSE}" ] && [ -z "${TF_VAR_bamboo_license}" ]; then
      log "License is missing. Please provide Bamboo license in config file, or export it to the environment variable 'TF_VAR_bamboo_license'." "ERROR"
      HAS_VALIDATION_ERR=1
    fi
    if [ -z "${POPULATED_ADMIN_PWD}" ] && [ -z "${TF_VAR_bamboo_admin_password}" ]; then
      log "Admin password is missing. Please provide Bamboo admin password in config file, or export it to the environment variable 'TF_VAR_bamboo_admin_password'." "ERROR"
      HAS_VALIDATION_ERR=1
    fi
  fi

  if [ -n "${HAS_VALIDATION_ERR}" ]; then
    log "There was a problem with the configuration file. Execution is aborted." "ERROR"
    exit 1
  fi
}

# Generates ./terraform-backend.tf and ./modules/tfstate/tfstate-local.tf using the content of local.tf and current aws account
generate_terraform_backend_variables() {
  log "${ENVIRONMENT_NAME}' infrastructure deployment is started using '${CONFIG_ABS_PATH##*/}'."

  log "Terraform state backend/variable files are to be created."

  bash "${SCRIPT_PATH}/generate-variables.sh" -c "${CONFIG_ABS_PATH}" "${FORCE_FLAG}"
  S3_BUCKET=$(get_variable 'bucket' "${ROOT_PATH}/terraform-backend.tf")
}

# Create S3 bucket, bucket key, and dynamodb table to keep state and manage lock if they are not created yet
create_tfstate_resources() {
  # Check if the S3 bucket is existed otherwise create the bucket to keep the terraform state
  log "Checking the terraform state."
  if ! test -d "${ROOT_PATH}/logs" ; then
    mkdir "${ROOT_PATH}/logs"
  fi
  touch "${LOG_FILE}"
  local STATE_FOLDER="${ROOT_PATH}/modules/tfstate"
  set +e
  aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null
  S3_BUCKET_EXISTS=$?
  set -e
  if [ ${S3_BUCKET_EXISTS} -eq 0 ]
  then
    log "S3 bucket '${S3_BUCKET}' already exists."
  else
    # create s3 bucket to be used for keep state of the terraform project
    log "Creating '${S3_BUCKET}' bucket for storing the terraform state..."
    if ! test -d "${STATE_FOLDER}/.terraform" ; then
      terraform -chdir="${STATE_FOLDER}" init -no-color | tee -a "${LOG_FILE}"
    fi
    terraform -chdir="${STATE_FOLDER}" apply -auto-approve "${OVERRIDE_CONFIG_FILE}" | tee -a "${LOG_FILE}"
    sleep 5
  fi
}

# Deploy the infrastructure if is not created yet otherwise apply the changes to existing infrastructure
create_update_infrastructure() {
  log "Starting to analyze the infrastructure..."
  if [ -n "${DIFFERENT_ENVIRONMENT}" ]; then
    log "Migrating the terraform state to S3 bucket..."
    terraform -chdir="${ROOT_PATH}" init -migrate-state -no-color | tee -a "${LOG_FILE}"
    terraform -chdir="${ROOT_PATH}" init -no-color | tee -a "${LOG_FILE}"
  fi
  terraform -chdir="${ROOT_PATH}" apply -auto-approve -no-color "${OVERRIDE_CONFIG_FILE}" | tee -a "${LOG_FILE}"
  terraform -chdir="${ROOT_PATH}" output -json > outputs.json
}

# Apply the tags into ASG and EC2 instances created by ASG
add_tags_to_asg_resources() {
  log "Tagging Auto Scaling Group and EC2 instances. It may take a few minutes. Please wait..."
  TAG_MODULE_PATH="${ROOT_PATH}/modules/AWS/asg_ec2_tagging"

  terraform -chdir="${TAG_MODULE_PATH}" init -no-color > "${LOG_TAGGING}"
  terraform -chdir="${TAG_MODULE_PATH}" apply -auto-approve -no-color "${OVERRIDE_CONFIG_FILE}" >> "${LOG_TAGGING}"
  log "Resource tags are applied to ASG and all EC2 instances."
}

set_current_context_k8s() {
  local EKS_PREFIX="atlas-"
  local EKS_SUFFIX="-cluster"
  local EKS_CLUSTER_NAME=${EKS_PREFIX}${ENVIRONMENT_NAME}${EKS_SUFFIX}
  local EKS_CLUSTER="${EKS_CLUSTER_NAME:0:38}"
  CONTEXT_FILE="${ROOT_PATH}/kubeconfig_${EKS_CLUSTER}"

  if [[ -f  "${CONTEXT_FILE}" ]]; then
    log "EKS Cluster ${EKS_CLUSTER} in region ${REGION} is ready to use."
    log "Kubernetes config file could be found at '${CONTEXT_FILE}'"
    # No need to update Kubernetes context when run by e2e test
    if [ -z "${FORCE_FLAG}" ]; then
      aws --region "${REGION}" eks update-kubeconfig --name "${EKS_CLUSTER}"
    fi
  else
    log "Kubernetes context file '${CONTEXT_FILE}' could not be found."
  fi
}

resume_bamboo_server() {
  # Please note that if you import the dataset, make sure admin credential in config file (config.tfvars)
  # is matched with admin info stored in dataset you import. 
  BAMBOO_DATASET=$(get_variable 'dataset_url' "${CONFIG_ABS_PATH}")
  INSTALL_BAMBOO=$(get_product "bamboo" "${CONFIG_ABS_PATH}")
  local SERVER_STATUS=

  # resume the server only if a dataset is imported
  if [ -n "${BAMBOO_DATASET}" ] && [ -n "${INSTALL_BAMBOO}" ]; then
    log "Resuming Bamboo server."

    ADMIN_USERNAME=$(get_variable 'bamboo_admin_username' "${CONFIG_ABS_PATH}")
    ADMIN_PASSWORD=$(get_variable 'bamboo_admin_password' "${CONFIG_ABS_PATH}")
    if [ -z "${ADMIN_USERNAME}" ]; then
      ADMIN_USERNAME="${TF_VAR_bamboo_admin_username}"
    fi
    if [ -z "${ADMIN_PASSWORD}" ]; then
      ADMIN_PASSWORD="${TF_VAR_bamboo_admin_password}"
    fi
    if [ -z "${ADMIN_USERNAME}" ]; then
      read -p "Please enter the bamboo administrator username: " ADMIN_USERNAME
    fi
    if [ -n "${ADMIN_USERNAME}" ]; then
      if [ -z "${ADMIN_PASSWORD}" ]; then
        echo "Please enter password of the Bamboo '${ADMIN_USERNAME}' user: "
        read -s ADMIN_PASSWORD
      fi
      bamboo_url=$(terraform output | grep '"bamboo" =' | sed -nE 's/^.*"(.*)".*$/\1/p')
      resume_bamboo_url="${bamboo_url}/rest/api/latest/server/resume"
      local RESULT=$(curl -s -u "${ADMIN_USERNAME}:${ADMIN_PASSWORD}" -X POST "${resume_bamboo_url}")
      if [[ "x${RESULT}" == *"RUNNING"* ]]; then
        SERVER_STATUS="RUNNING"
        log "Bamboo server was resumed and it is running successfully."
      elif [ "x${RESULT}" == *"AUTHENTICATED_FAILED"* ]; then
        log "The provided admin username and password is not matched with the credential stored in the dataset." "ERROR"
      else
        log "Unexpected state when resuming Bamboo server, state: ${RESULT}" "ERROR"
      fi
    fi
    if [ -z $SERVER_STATUS ]; then
      log "We were not able to login into the Bamboo software to resume the server." "WARN"
      log "Please login into the Bamboo and 'RESUME' the server before start using the product."
    fi
  fi
}

set_synchrony_url() {
  DOMAIN=$(get_variable 'domain' "${CONFIG_ABS_PATH}")
  INSTALL_CONFLUENCE=$(get_product "confluence" "${CONFIG_ABS_PATH}")

  if [ -z "${DOMAIN}" ] && [ -n "${INSTALL_CONFLUENCE}" ]; then
    log "Configuring the Synchrony service."
    SYNCHRONY_FULL_URL=$(terraform output | sed "s/ //g" | grep "synchrony_url=" | sed -nE 's/^.*"(.*)".*$/\1/p')
    helm upgrade confluence atlassian-data-center/confluence -n atlassian --reuse-values --set synchrony.ingressUrl="${SYNCHRONY_FULL_URL}" > /dev/null
    log "Synchrony URL is set to '${SYNCHRONY_FULL_URL}'."
  fi
}

# Process the arguments
process_arguments

# Verify the configuration file
verify_configuration_file

# Generates ./terraform-backend.tf and ./modules/tfstate/tfstate-local.tf
generate_terraform_backend_variables

# Create S3 bucket and dynamodb table to keep state
create_tfstate_resources

# Deploy the infrastructure
create_update_infrastructure

# Manually add resource tags into ASG and EC2 
add_tags_to_asg_resources

# Print information about manually adding the new k8s context
set_current_context_k8s

# Resume bamboo server if the credential is provided
resume_bamboo_server

# Set the correct Synchrony URL
set_synchrony_url
