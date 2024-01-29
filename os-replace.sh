#!/bin/bash
set -exuo pipefail

# Required env variables list
# PLATFORM: openstack, gcp, aws
# TEST_OS: rhel-9-4, centos-stream-9
# ARCH: x86_64, aarch64
# QUAY_USERNAME, QUAY_PASSWORD
# DOWNLOAD_NODE
# For RHEL only: RHEL_REGISTRY_URL, QUAY_SECRET
# For GCP only: GCP_SERVICE_ACCOUNT_FILE, GCP_SERVICE_ACCOUNT_NAME, GCP_PROJECT
# For AWS only: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION

# Colorful timestamped output.
function greenprint {
    echo -e "\033[1;32m[$(date -Isecond)] ${1}\033[0m"
}

function redprint {
    echo -e "\033[1;31m[$(date -Isecond)] ${1}\033[0m"
}

TEMPDIR=$(mktemp -d)

# SSH configurations
SSH_KEY=${TEMPDIR}/id_rsa
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 2048
SSH_KEY_PUB="${SSH_KEY}.pub"

INSTALL_CONTAINERFILE=${TEMPDIR}/Containerfile.install
UPGRADE_CONTAINERFILE=${TEMPDIR}/Containerfile.upgrade
QUAY_REPO_TAG="${QUAY_REPO_TAG:-$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')}"
INVENTORY_FILE="${TEMPDIR}/inventory"

case "$TEST_OS" in
    "rhel-9-4")
        IMAGE_NAME="rhel9-rhel_bootc"
        TIER1_IMAGE_URL="${RHEL_REGISTRY_URL}/${IMAGE_NAME}:rhel-9.4"
        SSH_USER="cloud-user"
        sed "s/REPLACE_ME/${DOWNLOAD_NODE}/g" files/rhel-9-4.template | tee rhel-9-4.repo > /dev/null
        ADD_REPO="COPY rhel-9-4.repo /etc/yum.repos.d/rhel-9-4.repo"
        sed "s/REPLACE_ME/${QUAY_SECRET}/g" files/auth.template | tee auth.json > /dev/null
        ADD_AUTH="COPY auth.json /etc/ostree/auth.json"
        if [[ "$PLATFORM" == "aws" ]]; then SSH_USER="ec2-user"; fi
        ;;
    "centos-stream-9")
        IMAGE_NAME="centos-bootc"
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:stream9"
        SSH_USER="cloud-user"
        ADD_REPO=""
        ADD_AUTH=""
        if [[ "$PLATFORM" == "aws" ]]; then SSH_USER="ec2-user"; fi
        ;;
    "fedora-eln")
        IMAGE_NAME="fedora-bootc"
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:eln"
        SSH_USER="fedora"
        ADD_REPO=""
        ADD_AUTH=""
        ;;
    *)
        redprint "Variable TEST_OS has to be defined"
        exit 1
        ;;
esac

TEST_IMAGE_NAME="${IMAGE_NAME}-os_replace"
TEST_IMAGE_URL="quay.io/xiaofwan/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}"

greenprint "Create $TEST_OS installation Containerfile"
tee "$INSTALL_CONTAINERFILE" > /dev/null << EOF
FROM "$TIER1_IMAGE_URL"
$ADD_REPO
RUN dnf -y install python3 cloud-init && \
    dnf -y clean all
$ADD_AUTH
EOF

greenprint "Check $TEST_OS installation Containerfile"
cat "$INSTALL_CONTAINERFILE"

greenprint "Login quay.io"
podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io

greenprint "Build $TEST_OS installation container image"
podman build -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$INSTALL_CONTAINERFILE" .

greenprint "Push $TEST_OS installation container image"
podman push "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Prepare inventory file"
tee -a "$INVENTORY_FILE" > /dev/null << EOF
[cloud]
localhost

[guest]

[cloud:vars]
ansible_connection=local

[guest:vars]
ansible_user="$SSH_USER"
ansible_private_key_file="$SSH_KEY"
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

greenprint "Prepare ansible.cfg"
export ANSIBLE_CONFIG="${PWD}/playbooks/ansible.cfg"

greenprint "Deploy $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e ssh_user="$SSH_USER" \
    -e ssh_key_pub="$SSH_KEY_PUB" \
    -e test_image_url="$TEST_IMAGE_URL" \
    -e inventory_file="$INVENTORY_FILE" \
    "playbooks/deploy-${PLATFORM}.yaml"

greenprint "Install $TEST_OS bootc system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e test_image_url="$TEST_IMAGE_URL" \
    playbooks/install.yaml

greenprint "Run ostree checking test on $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$TEST_IMAGE_URL" \
    playbooks/check-system.yaml

greenprint "Create upgrade Containerfile"
tee "$UPGRADE_CONTAINERFILE" > /dev/null << EOF
FROM "$TEST_IMAGE_URL"
RUN dnf -y install wget && \
    dnf -y clean all
EOF

greenprint "Build $TEST_OS upgrade container image"
podman build -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$UPGRADE_CONTAINERFILE" .
greenprint "Push $TEST_OS upgrade container image"
podman push "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Upgrade $TEST_OS system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    playbooks/upgrade.yaml

greenprint "Run ostree checking test after upgrade on $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$TEST_IMAGE_URL" \
    -e upgrade="true" \
    playbooks/check-system.yaml

greenprint "Remove $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e platform="$PLATFORM" \
    playbooks/remove.yaml

greenprint "Clean up"
rm -rf "$TEMPDIR" auth.json rhel-9-4.repo
unset ANSIBLE_CONFIG

greenprint "🎉 All tests passed."
exit 0
