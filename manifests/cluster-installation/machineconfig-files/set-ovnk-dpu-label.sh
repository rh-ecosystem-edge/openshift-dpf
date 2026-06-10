#!/bin/bash
set -euo pipefail

# Sets the OVN-K DPU host label on this node via a kubelet systemd drop-in.
# Merges with any CUSTOM_KUBELET_LABELS already set by baremetal-runtimecfg
# (20-nodenet.conf) so neither source clobbers the other.

DPF_LABEL="k8s.ovn.org/dpu-host="
NODENET_DROPIN="/etc/systemd/system/kubelet.service.d/20-nodenet.conf"
DPF_DROPIN="/etc/systemd/system/kubelet.service.d/30-dpf-labels.conf"

existing_labels=""

if [[ -f "$NODENET_DROPIN" ]]; then
    existing_labels=$(grep -oP 'CUSTOM_KUBELET_LABELS=\K[^"]*' "$NODENET_DROPIN" 2>/dev/null || true)
fi

# Merge: deduplicate labels from all sources
declare -A label_map
IFS=',' read -ra ALL_LABELS <<< "${existing_labels:+${existing_labels},}${DPF_LABEL}"
for label in "${ALL_LABELS[@]}"; do
    label=$(echo "$label" | xargs)
    [[ -z "$label" ]] && continue
    key="${label%%=*}"
    label_map["$key"]="$label"
done

merged=""
for label in "${label_map[@]}"; do
    merged="${merged:+${merged},}${label}"
done

echo "set-ovnk-dpu-label: nodenet labels='${existing_labels}', merged='${merged}'" >&2

mkdir -p "$(dirname "$DPF_DROPIN")"
cat > "$DPF_DROPIN" <<EOF
[Service]
Environment="CUSTOM_KUBELET_LABELS=${merged}"
EOF

systemctl daemon-reload
