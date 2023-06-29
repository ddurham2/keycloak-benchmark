#!/bin/bash
set -e

if [ -f ./.env ]; then
  source ./.env
fi

AWS_ACCOUNT=${AWS_ACCOUNT:-$(aws sts get-caller-identity --query "Account" --output text)}
if [ -z "$AWS_ACCOUNT" ]; then echo "Variable AWS_ACCOUNT needs to be set."; exit 1; fi

if [ -z "$VERSION" ]; then echo "Variable VERSION needs to be set."; exit 1; fi
CLUSTER_NAME=${CLUSTER_NAME:-$(whoami)}
if [ -z "$CLUSTER_NAME" ]; then echo "Variable CLUSTER_NAME needs to be set."; exit 1; fi
if [ -z "$REGION" ]; then echo "Variable REGION needs to be set."; exit 1; fi
if [ -z "$COMPUTE_MACHINE_TYPE" ]; then echo "Variable COMPUTE_MACHINE_TYPE needs to be set."; exit 1; fi

if [ "$MULTI_AZ" = "true" ]; then MULTI_AZ_PARAM="--multi-az"; else MULTI_AZ_PARAM=""; fi
if [ -z "$REPLICAS" ]; then echo "Variable REPLICAS needs to be set."; exit 1; fi

echo "Checking if cluster ${CLUSTER_NAME} already exists."
if rosa describe cluster --cluster="${CLUSTER_NAME}"; then
  echo "Cluster ${CLUSTER_NAME} already exists."
else
  echo "Verifying ROSA prerequisites."
  echo "Check if AWS CLI is installed."; aws --version
  echo "Check if ROSA CLI is installed."; rosa version
  echo "Check if ELB service role is enabled."
  if ! aws iam get-role --role-name "AWSServiceRoleForElasticLoadBalancing" --no-cli-pager; then
    aws iam create-service-linked-role --aws-service-name "elasticloadbalancing.amazonaws.com"
  fi
  rosa whoami
  rosa verify quota

  echo "Installing ROSA cluster ${CLUSTER_NAME}"

  ROSA_CMD="rosa create cluster \
  --sts \
  --cluster-name ${CLUSTER_NAME} \
  --version ${VERSION} \
  --role-arn arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Installer-Role \
  --support-role-arn arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Support-Role \
  --controlplane-iam-role arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-ControlPlane-Role \
  --worker-iam-role arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Worker-Role \
  --operator-roles-prefix ${CLUSTER_NAME} \
  --region ${REGION} ${MULTI_AZ_PARAM} \
  --replicas ${REPLICAS} \
  --compute-machine-type ${COMPUTE_MACHINE_TYPE} \
  --machine-cidr 10.0.0.0/16 \
  --service-cidr 172.30.0.0/16 \
  --pod-cidr 10.128.0.0/14 \
  --host-prefix 23"

  echo $ROSA_CMD
  $ROSA_CMD
fi

mkdir -p "logs/${CLUSTER_NAME}"

function custom_date() {
    date '+%Y%m%d-%H%M%S'
}

echo "Creating operator roles."
rosa create operator-roles --cluster "${CLUSTER_NAME}" --mode auto --yes > "logs/${CLUSTER_NAME}/$(custom_date)_create-operator-roles.log"

echo "Creating OIDC provider."
rosa create oidc-provider --cluster "${CLUSTER_NAME}" --mode auto --yes > "logs/${CLUSTER_NAME}/$(custom_date)_create-oidc-provider.log"

echo "Waiting for cluster installation to finish."
# There have been failures with 'ERR: Failed to watch logs for cluster ... connection reset by peer' probably because services in the cluster were restarting during the cluster initialization.
# Those errors don't show an installation problem, and installation will continue asynchronously. Therefore, retry.
TIMEOUT=$(($(date +%s) + 3600))
while true ; do
  if (rosa logs install --cluster "${CLUSTER_NAME}" --watch --tail=1000000 >> "logs/${CLUSTER_NAME}/$(custom_date)_create-cluster.log"); then
    break
  fi
  if (( TIMEOUT < $(date +%s))); then
    echo "Timeout exceeded"
    exit 1
  fi
  echo "retrying watching logs after failure"
  sleep 1
done

echo "Cluster installation complete."
echo

./rosa_recreate_admin.sh

./rosa_efs_create.sh
