# Storage: Use Ours or Your Own

The automation needs storage for **etcd** (hosted cluster). You can either use the storage the automation deploys (default) or provide your own StorageClass.

---

## Option 1: Use the automation’s storage (default)

**Do nothing special.** Leave `SKIP_DEPLOY_STORAGE` unset or set to `false` in `.env`.

- The automation will deploy a storage operator (LVM or ODF, depending on `STORAGE_TYPE`) and create a StorageClass for you.
- **ETCD_STORAGE_CLASS** is set automatically (`lvms-vg1` for LVM, `ocs-storagecluster-ceph-rbd` for ODF).
- You do **not** create any StorageClass or PV.

---

## Option 2: Use your own StorageClass

Use this when you already have storage in the cluster (e.g. from your storage vendor or your own operator) and want to skip deploying LVM/ODF.

### Step 1: Set .env

In your `.env` file:

```bash
SKIP_DEPLOY_STORAGE=true
ETCD_STORAGE_CLASS=<your-storage-class-name>
```

Replace `<your-storage-class-name>` with the exact name of the StorageClass that already exists in your cluster (e.g. `netapp-sc`). The automation will check that this StorageClass exists after the cluster is installed.

### Step 2: Ensure enough storage for 3 volumes

The automation will create **3** PVCs that all use your StorageClass:

| What for        | How many | Notes |
|-----------------|----------|--------|
| etcd (replicas) | 3        | One per etcd pod; each etcd runs on a different node. |

You must provide **3 volumes** in one of these ways:

- **Dynamic provisioning:** Your StorageClass has a provisioner (e.g. CSI). When each PVC is created, the provisioner creates a PV automatically. No manual PVs needed.
- **Static PVs:** You create **3** PersistentVolumes (or more) that use your StorageClass. Each should have at least **10Gi** capacity (50Gi recommended for etcd) and **ReadWriteOnce** access. If your PVs use `nodeAffinity`, you need **3 PVs on 3 different nodes** for etcd.

### Step 3: Run the automation

Run your usual flow (e.g. `make prepare-manifests`, `make cluster-install`, then `make deploy-dpf`, etc.). After the cluster is installed, the automation verifies that your StorageClass exists; if it does, deployment continues without deploying LVM/ODF.

### Quick checklist (your own storage)

- [ ] `.env` has `SKIP_DEPLOY_STORAGE=true` and `ETCD_STORAGE_CLASS=<name>`.
- [ ] A StorageClass with that name exists in the cluster (before or right after install).
- [ ] Either your StorageClass uses dynamic provisioning, or you created at least 3 static PVs with that StorageClass (one per etcd replica on 3 nodes).

---

## Mock storage for testing

If you want to test “use your own storage” without real external storage, create a StorageClass and 3 hostPath PVs as below.

### Steps

1. **Get your three master node names:** run `oc get nodes` and note the exact **NAME** of each master.

2. **Create directories on each node:**
   - On **NODE1:** `sudo mkdir -p /mnt/mock-storage/pv1`
   - On **NODE2:** `sudo mkdir -p /mnt/mock-storage/pv2`
   - On **NODE3:** `sudo mkdir -p /mnt/mock-storage/pv3`  
   On each node, set permissions so pods can write:  
   `sudo chown -R 1000:1000 /mnt/mock-storage` and `sudo chmod -R 0777 /mnt/mock-storage`.

3. **Create the manifest:** copy the YAML below to a file (e.g. `mock-storage.yaml`). Replace **&lt;NODE1&gt;**, **&lt;NODE2&gt;**, **&lt;NODE3&gt;** with your three master node names.

4. **Apply:** `oc apply -f mock-storage.yaml`

5. **Configure .env:**  
   `SKIP_DEPLOY_STORAGE=true` and `ETCD_STORAGE_CLASS=mock-sc`

6. **Run your flow** (e.g. `make cluster-install`, `make deploy-dpf`).

**Verify:** `oc get pv | grep mock-sc` and `oc get pvc -n clusters-doca` — you should see 3 PVs and 3 PVCs bound.

*Alternative:* create only the StorageClass with `provisioner: kubernetes.io/no-provisioner`, then create 3 PVs yourself (one per node for etcd); see Step 2 under Option 2 for layout.

### Mock storage manifest (StorageClass + 3 PVs)

Replace `<NODE1>`, `<NODE2>`, `<NODE3>` with your master node names before applying.

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mock-sc
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mock-pv-1
spec:
  capacity:
    storage: 50Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: mock-sc
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - <NODE1>
  hostPath:
    path: /mnt/mock-storage/pv1
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mock-pv-2
spec:
  capacity:
    storage: 50Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: mock-sc
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - <NODE2>
  hostPath:
    path: /mnt/mock-storage/pv2
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mock-pv-3
spec:
  capacity:
    storage: 50Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: mock-sc
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - <NODE3>
  hostPath:
    path: /mnt/mock-storage/pv3
    type: DirectoryOrCreate
```

---

## Reference: what uses ETCD_STORAGE_CLASS

| PVC name    | Namespace     | Used by |
|-------------|---------------|---------|
| data-etcd-0 | clusters-doca | etcd-0  |
| data-etcd-1 | clusters-doca | etcd-1  |
| data-etcd-2 | clusters-doca | etcd-2  |

All three use the same StorageClass. With static PVs, binding is per-node and first-come-first-served.
