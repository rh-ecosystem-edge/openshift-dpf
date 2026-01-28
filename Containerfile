FROM registry.access.redhat.com/ubi9/ubi:latest
RUN dnf install -y make git jq findutils openssh-clients && dnf clean all
