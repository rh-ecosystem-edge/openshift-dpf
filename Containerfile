FROM quay.io/openshift/origin-cli:4.20 as oc-cli
FROM registry.access.redhat.com/ubi9/ubi:latest

LABEL org.opencontainers.image.authors="Red Hat Ecosystem Engineering"

USER root

# Copying oc binary
COPY --from=oc-cli /usr/bin/oc /usr/bin/oc
RUN ln -s /usr/bin/oc /usr/bin/kubectl

RUN dnf install -y make git jq findutils openssh-clients rsync python3.11 python3.11-pip python3.11-devel && dnf clean all

# Get the source code in there
WORKDIR /root/dpf-ci

COPY . .

# Make workspace writable for OpenShift's arbitrary user IDs
# Note: SSH keys should NOT be in the image - they're mounted at runtime from secrets
RUN chmod 777 /root/dpf-ci -R

ENTRYPOINT ["bash"]
