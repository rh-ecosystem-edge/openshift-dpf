#!/bin/bash

if [ ! -d /sys/bus/pci/drivers/mlx5_core ]; then
  echo "mlx5_core driver not loaded. Attempting modprobe..."
  if ! modprobe mlx5_core; then
    echo "ERROR: Failed to load mlx5_core driver." >&2
    exit 1
  fi
fi

VENDOR_MELLANOX="0x15b3"

for dev_path in /sys/bus/pci/devices/*; do
  [[ -f "$dev_path/vendor" ]] || continue
  [[ "$(< "$dev_path/vendor")" == "$VENDOR_MELLANOX" ]] || continue
  full_id=$(basename "$dev_path")

  if [ ! -e "$dev_path/driver" ]; then
    echo "Device $full_id has no driver. Attempting to bind mlx5_core..."

    echo "$full_id" >/sys/bus/pci/drivers/mlx5_core/bind

    if [ -e "$dev_path/driver" ] && \
       [ "$(basename "$(readlink "$dev_path/driver")")" = "mlx5_core" ]; then
      echo "Successfully bound $full_id to mlx5_core."
    else
      echo "ERROR: Failed to bind $full_id to mlx5_core." >&2
    fi
  else
    current=$(basename "$(readlink "$dev_path/driver")")
    echo "Device $full_id already bound to: $current"
  fi
done
