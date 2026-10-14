FROM docker.io/alpine/helm:3 as helm-cli
FROM quay.io/openshift/origin-cli:4.22 as oc-cli
FROM registry.access.redhat.com/ubi10/ubi:latest

LABEL org.opencontainers.image.authors="Red Hat Ecosystem Engineering"

USER root

# Copying oc binary
COPY --from=oc-cli /usr/bin/oc /usr/bin/oc
RUN ln -s /usr/bin/oc /usr/bin/kubectl

RUN dnf install -y --allowerasing findutils gettext git golang jq make openssh-clients podman python3-devel python3-pip rsync && \
    rpm --import https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official-SHA256 && \
    dnf install -y --repofrompath='cs10-appstream,https://mirror.stream.centos.org/10-stream/AppStream/$basearch/os/' \
      --setopt=cs10-appstream.gpgkey=https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official-SHA256 \
      libvirt-client virt-install && \
    dnf clean all

# Copying helm binary
COPY --from=helm-cli /usr/bin/helm /usr/bin/helm

# Install aicli
RUN pip3 install aicli

# Get the source code in there
WORKDIR /root/dpf-ci

COPY . .

# Make workspace writable for OpenShift's arbitrary user IDs
# Note: SSH keys should NOT be in the image - they're mounted at runtime from secrets
RUN chmod 777 /root/dpf-ci -R
