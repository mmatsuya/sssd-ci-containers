#!/bin/bash

#                     ==============
#                      IMAGE LAYERS
#                     ==============
#
#                     original image
# |------------------------------------------------------------------------------------------------|
# |                                       base-ground                                              |
# |------------------------------------------------------------------------------------------------|
# |        base-ldap    |  base-client  |  base-samba  |  base-nfs  |  base-keycloak  |  base-kdc  |
# |------------------------------------ |--------------|------------|-----------------|------------|
# |  base-ipa  |        |               |              |            |                 |            |
# |------------|        |               |              |            |                 |            |
# |    ipa     |  ldap  |    client     |     samba    |    nfs     |    keycloak     |     kdc    |
# |            |        |---------------|              |            |                 |            |
# |            |        |  client-dev   |              |            |                 |            |
# |------------|--------|---------------|--------------|------------|-----------------|------------|

trap "cleanup &> /dev/null || :" EXIT
pushd $(realpath `dirname "$0"`) &> /dev/null
source ./tools/get-container-engine.sh

export REGISTRY="localhost/sssd"
export BASE_IMAGE="${BASE_IMAGE:-registry.fedoraproject.org/fedora:latest}"
export TAG="${TAG:-latest}"
export UNAVAILABLE="${UNAVAILABLE:-}"
export RHEL84_COMPOSE="${RHEL84_COMPOSE:-https://download.eng.brq.redhat.com/nightly/rhel-8/updates/RHEL-8/latest-RHEL-8.4.0/compose}"
export ANSIBLE_CONFIG=./ansible/ansible.cfg
export ANSIBLE_OPTS=${ANSIBLE_OPTS:-}
export ANSIBLE_DEBUG=${ANSIBLE_DEBUG:-0}

# Debugging options
export CLEANUP=${CLEANUP:-yes}
export SKIP_BASE=${SKIP_BASE:-no}

echo "Building from: $BASE_IMAGE"
echo "Building with tag: $TAG"
echo "Building in priviledged mode: $PRIVILEDGED"
echo "Storing in: $REGISTRY"

if [ "$CLEANUP" == "no" ]; then
  trap - EXIT
fi

set -xe

function cleanup {
  ${DOCKER} rm sssd-wip-base --force || :
  compose down
}

function compose {
  docker-compose -f "../docker-compose.yml" -f "./docker-compose.build.yml" $@
}

function base_exec {
  ${DOCKER} exec sssd-wip-base /bin/bash -c "$1"
}

function c8s_repo {
    # Update repos to working ones
    ${DOCKER} exec sssd-wip-base /bin/bash -c 'grep -q "CentOS Stream 8" /etc/os-release && sed -i "s/mirrorlist/#mirrorlist/g" /etc/yum.repos.d/CentOS-* || true'
    ${DOCKER} exec sssd-wip-base /bin/bash -c 'grep -q "CentOS Stream 8" /etc/os-release && sed -i "s|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g" /etc/yum.repos.d/CentOS-* || true'
}

function rhel84_repo {
    # Add RHEL 8.4 compose repos when running on a RHEL 8 UBI image (no subscription)
    if ! base_exec 'grep -q "Red Hat" /etc/os-release && grep -q VERSION_ID=\"8 /etc/os-release'; then
        return 0
    fi
    base_exec "cat > /etc/yum.repos.d/rhel84-compose.repo << 'EOF'
[rhel84-baseos]
name=RHEL 8.4 BaseOS
baseurl=${RHEL84_COMPOSE}/BaseOS/x86_64/os/
enabled=1
gpgcheck=0
sslverify=0
priority=1

[rhel84-appstream]
name=RHEL 8.4 AppStream
baseurl=${RHEL84_COMPOSE}/AppStream/x86_64/os/
enabled=1
gpgcheck=0
sslverify=0
priority=1

[rhel84-crb]
name=RHEL 8.4 CRB
baseurl=${RHEL84_COMPOSE}/CRB/x86_64/os/
enabled=1
gpgcheck=0
sslverify=0
priority=1
EOF"
}

# Make sure that Ansible dependencies are installed so we can run playbooks
function base_install_python {
  # Install python3 if not available
  if base_exec '[ ! -f /usr/bin/python3 ]'; then
    if base_exec '[ -f /usr/bin/apt ]'; then
      base_exec 'apt update && apt install -y python3 python3-apt && rm -rf /var/lib/apt/lists/*'
    else
      base_exec 'dnf install -y python3 && dnf clean all'
    fi
  fi

  # Ansible requires Python 3.7+. If the system only has Python 3.6 (e.g. RHEL 8.4),
  # install python3.8 and make it the default python3.
  if base_exec 'python3 --version 2>&1 | grep -qE "Python 3\.[0-6]\."'; then
    base_exec 'dnf install -y python38 && alternatives --set python3 /usr/bin/python3.8 && dnf clean all'
  fi

  # Add python3-dnf5 to enable ansible to use it
  if base_exec '[ -f /usr/bin/dnf5 ]'; then
    base_exec 'dnf install -y python3-libdnf5 dnf5-plugins'
  fi
}

# We use commit instead of build so we can provision the images with Ansible.
function build_base_image {
  local from=$1
  local name=$2

  for svc in $UNAVAILABLE; do
    if [ "base-$svc" != $name ]; then
      continue
    fi

    echo "Service $svc is not available in $BASE_IMAGE."
    echo "Using quay.io/sssd/ci-base-$svc:latest instead."
    ${DOCKER} pull "quay.io/sssd/ci-base-$svc:latest"
    ${DOCKER} tag "quay.io/sssd/ci-base-$svc:latest" "${REGISTRY}/ci-$name:${TAG}"
    return 0
  done

  echo "Building $name from $from"
  ${DOCKER} run --security-opt seccomp=unconfined --name sssd-wip-base --detach -i "$from"
  if [ $name == 'base-ground' ]; then
    c8s_repo
    rhel84_repo
    base_install_python
  fi
  ansible-playbook $ANSIBLE_OPTS --limit "`echo $name | sed -r 's/-/_/g'`" ./ansible/playbook_image_base.yml
  ${DOCKER} stop sssd-wip-base
  ${DOCKER} commit                     \
    --change 'CMD ["/sbin/init"]'      \
    --change 'STOPSIGNAL SIGRTMIN+3'   \
    sssd-wip-base "${REGISTRY}/ci-$name:${TAG}"
  ${DOCKER} rm sssd-wip-base --force
}

# We have to use commit because the services require functional systemd.
function build_service_image {
  local from=$1
  local name=$2

  echo "Commiting $from as $name"
  ${DOCKER} commit "$from" "${REGISTRY}/ci-$name:${TAG}"
}

if [ "$SKIP_BASE" == 'no' ]; then
  # Create base images
  ${DOCKER} build --file "Containerfile" --target dns --tag "${REGISTRY}/ci-dns:latest" .
  build_base_image "$BASE_IMAGE" base-ground
  build_base_image "ci-base-ground:${TAG}" base-client
  build_base_image "ci-base-ground:${TAG}" base-ldap
  build_base_image "ci-base-ground:${TAG}" base-samba
  build_base_image "ci-base-ldap:${TAG}"   base-ipa
  build_base_image "ci-base-ground:${TAG}" base-nfs
  build_base_image "ci-base-ground:${TAG}" base-kdc
  build_base_image "ci-base-ground:${TAG}" base-keycloak
fi

# Create services
compose up --detach
SKIP_SAMBA=false
for svc in $UNAVAILABLE; do
  if [ "$svc" == "samba" ]; then
    SKIP_SAMBA=true
    break
  fi
done
if [ "$SKIP_SAMBA" == "true" ]; then
  ansible-playbook $ANSIBLE_OPTS --extra-vars '{"join_samba":false,"trust_ipa_samba":false}' ./ansible/playbook_image_service.yml
else
  ansible-playbook $ANSIBLE_OPTS ./ansible/playbook_image_service.yml
fi
compose stop
build_service_image sssd-wip-client client
build_service_image sssd-wip-ipa ipa
build_service_image sssd-wip-ipa2 ipa2
build_service_image sssd-wip-ldap ldap
build_service_image sssd-wip-samba samba
build_service_image sssd-wip-nfs nfs
build_service_image sssd-wip-kdc kdc
build_service_image sssd-wip-keycloak keycloak
compose down

# Create development images with additional packages
build_base_image "ci-client:${TAG}" client-devel
build_base_image "ci-ipa:${TAG}" ipa-devel
