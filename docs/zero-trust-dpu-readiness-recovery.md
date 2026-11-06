# Zero Trust DPU readiness recovery

This runbook records the lab recovery used when a DPU timed out in `Node Effect Removal`. The recovery was performed on live custom resources; it did not reinstall the DPU or replace its operating system.

## Check the blocker first

```bash
NS=dpf-operator-system
DPU="replace-with-dpu-object-name"
oc get dpu "$DPU" -n "$NS" -o yaml
oc get dpunodemaintenance -n "$NS" -o wide
oc get dpunode -n "$NS" -o wide
```

Compare `DPU.spec.dpuNodeName` with the maintenance object's `spec.dpuNodeName` and the actual `DPUNode.metadata.name`. The maintenance reference must name the DPUNode; it must not name the x86 Kubernetes node. Check the `NodeEffectApplied` condition and requestors, and confirm the relevant DPU services and service chain are ready before changing anything.

## Lab-only recovery used

In the recovered lab incident, the maintenance object referenced the x86 host instead of the DPUNode. After confirming the actual DPUNode, the live maintenance spec was corrected:

```bash
MAINT="replace-with-dpunodemaintenance-object-name"
DPUNODE="replace-with-actual-dpunode-name"
oc patch dpunodemaintenance "$MAINT" -n "$NS" --type=merge \
  -p "{\"spec\":{\"dpuNodeName\":\"$DPUNODE\"}}"
```

After DPF applied the node effect and the maintenance requestors cleared, the DPU still remained in `Error` with `previousPhase: Node Effect Removal`. The lab recovery moved only that phase back to the pending node-effect-removal step:

```bash
oc patch dpu "$DPU" -n "$NS" --subresource=status --type=merge \
  -p '{"status":{"phase":"Node Effect Removal"}}'
```

Then verify the DPU reaches `phase: Ready`, `OperationalReady=True`, the hosted-cluster DPU worker is `Ready`, and the DPUDeployment is successful. Do not use the phase reset for an error from BFB transfer, OS installation, firmware, Redfish, or another phase; diagnose that failure instead.

These edits are a lab recovery procedure, not a normal deployment step. Companion DPF controller changes are required to reconcile maintenance completion and resume only this specific timed-out phase automatically once its requestors are gone. Keep the automation's readiness gate enabled so deployment fails with DPU conditions when those prerequisites do not complete.
