# Enabling UEFI Secure Boot on an NVIDIA BlueField DPU

This document describes how to enable UEFI Secure Boot on a BlueField DPU by talking to the DPU's BMC over the internal **VLAN 4040**. This is useful in host-trusted cases where no OOB cable is attached.

On the BlueField 3 DPU the ipmi is the authorative source of truth for many settings including SecureBoot. Fields set in the UEFI will not persist. Instead users must set these fields using RedFish. In cases where there is no OOB cable this can be done over the internal VLAN.

## Assumptions

- The DPU is booted into its Arm-side OS.
- The DPU BMC is present and running.
- PK / KEK / db are already enrolled (UEFI boot banner reports `PK is configured`, Secure Boot Mode `User Mode`).
- You have SSH access to the DPU Arm OS as a user that can `sudo`.

## Step 1: SSH into the DPU

```bash
ssh core@<dpu-arm-ip>
```


## Step 2:  Identify the OOB management interface

It's usually `enamlnxbf17i0` (a.k.a. `oob_net0`).

```bash
ip -br link show | grep -iE 'oob|bf17'
```

## Step 3: Bring up VLAN 4040 to reach the BMC

VLAN 4040 is the internal Redfish VLAN between UEFI and the DPU BMC.

```bash
sudo ip link add link enamlnxbf17i0 name oob.4040 type vlan id 4040
sudo ip addr add 192.168.240.2/24 dev oob.4040
sudo ip link set oob.4040 up

ping -c2 192.168.240.1
```

## Step 4: Read current Secure Boot state

The default username and password for the BMC is at https://docs.nvidia.com/networking/display/bluefieldbmcv2507/connecting+to+bmc+interfaces#src-4259994369_ConnectingtoBMCInterfaces-ChangingDefaultPassword

Users may be required to change the password on first login.

```bash
curl -sk -u root:'PASSWORD' \
  https://192.168.240.1/redfish/v1/Systems/Bluefield/SecureBoot | jq .
```

Expected values:

| Field                   | Value      |
| ----------------------- | ---------- |
| `SecureBootEnable`      | `false`    |
| `SecureBootMode`        | `UserMode` |
| `SecureBootCurrentBoot` | `Disabled` |

## Step 5: Enable Secure Boot via Redfish

```bash
curl -sk -u root:'PASSWORD' -X PATCH \
  -H "Content-Type: application/json" \
  https://192.168.240.1/redfish/v1/Systems/Bluefield/SecureBoot \
  -d '{"SecureBootEnable": true}' | jq .
```

The response must include `"MessageId": "Base.1.x.x.Success"`. Anything else means the PATCH was rejected.

## Step 6: First reboot (UEFI stages the change)

```bash
sudo reboot
```

SSH back in once it's up. The UEFI banner will still show `Current Secure Boot State: disabled`.

## Step 7: Second reboot (UEFI applies the change)

```bash
sudo reboot
```

SSH back in once it's up.

## Step 8: Verify
 
From the Arm OS:

```bash
mokutil --sb-state
```

Expect `SecureBoot enabled`.
