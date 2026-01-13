# KubeVirt CSI Driver Helm Chart

This Helm chart deploys the [KubeVirt CSI Driver](https://github.com/kubevirt/csi-driver) on **KubeVirt VM-based OpenShift nested clusters without Hosted Control Planes (HCP)**.

The KubeVirt CSI Driver enables nested clusters running as VMs on an infrastructure (infra) cluster to dynamically provision persistent storage. The driver creates DataVolumes/PVCs on the infra cluster and hot-plugs them as disks into the VM nodes of the nested cluster.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Infrastructure Cluster                         │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Namespace: <infra.namespace>                               │    │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                      │    │
│  │  │ VM      │  │ VM      │  │ VM      │  (Nested Cluster     │    │
│  │  │ master-0│  │ worker-0│  │ worker-1│   Nodes as VMs)      │    │
│  │  └────┬────┘  └────┬────┘  └────┬────┘                      │    │
│  │       │            │            │                           │    │
│  │       └────────────┴────────────┘                           │    │
│  │             │                                               │    │
│  │  ┌──────────┴──────────┐                                    │    │
│  │  │ DataVolumes / PVCs  │  ← Created by CSI Driver           │    │
│  │  │ (Hot-plugged disks) │                                    │    │
│  │  └─────────────────────┘                                    │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                              ▲
                              │ kubeconfig (Service Account Token)
                              │
┌─────────────────────────────┴───────────────────────────────────────┐
│                        Nested Cluster                               │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Namespace: kubevirt-csi-driver                             │    │
│  │  ┌────────────────────┐  ┌────────────────────────────────┐ │    │
│  │  │ CSI Controller     │  │ CSI Node DaemonSet             │ │    │
│  │  │ (Deployment)       │  │ (runs on each node)            │ │    │
│  │  └────────────────────┘  └────────────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  Workloads use StorageClass: kubevirt-csi                           │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Infrastructure Cluster**: OpenShift cluster with KubeVirt/OpenShift Virtualization installed
- **Nested Cluster**: OpenShift cluster running as VMs on the infra cluster
- **CLI Tools**: `oc` configured for both clusters, `helm` v3+
- **Access**: project-admin on the infra cluster (VMs namespace), cluster-admin on the nested cluster

---

## Deployment Steps

### Step 1: Prepare the Infrastructure Cluster RBAC

Before deploying the CSI driver in the nested cluster, you must create the required RBAC resources on the **infrastructure cluster**. These allow the CSI driver to manage DataVolumes, PVCs, and VM disk operations.

#### 1.1 Set the Namespace

The RBAC resources must be created in the namespace where your nested cluster VMs reside. By default, this is `nested-cluster`.

**Option A: Use the default namespace**

```bash
# Connect to the infrastructure cluster
oc login <infra-cluster-api-url>

# Create RBAC in the default namespace (nested-cluster)
oc apply -f infra-cluster-rbac/infra-cluster-rbac.yaml -n nested-cluster
```

**Option B: Use a custom namespace**

If your VMs are in a different namespace, first update the RoleBinding subject:

```bash
# Set your namespace
export INFRA_NAMESPACE="your-vm-namespace"

# Update the namespace reference in the RoleBinding and apply
sed "s/namespace: nested-cluster/namespace: ${INFRA_NAMESPACE}/g" \
    infra-cluster-rbac/infra-cluster-rbac.yaml | \
    oc apply -n ${INFRA_NAMESPACE} -f -
```

#### 1.2 Verify RBAC Creation

```bash
# Verify the resources were created
oc get serviceaccount kubevirt-csi-infra-sa -n ${INFRA_NAMESPACE:-nested-cluster}
oc get secret kubevirt-csi-infra-token -n ${INFRA_NAMESPACE:-nested-cluster}
oc get role kubevirt-csi-infra-role -n ${INFRA_NAMESPACE:-nested-cluster}
oc get rolebinding kubevirt-csi-infra-binding -n ${INFRA_NAMESPACE:-nested-cluster}
```

The RBAC configuration grants the following permissions:
| Resource | Permissions | Purpose |
|----------|-------------|---------|
| `datavolumes` | get, list, watch, create, delete, update, patch | Create/manage storage volumes |
| `virtualmachines` | get, list, watch, update, patch | Access VM metadata |
| `virtualmachineinstances` | get, list, watch, update, patch | Access running VM info |
| `persistentvolumeclaims` | get, list, watch, create, delete, update, patch | Manage underlying PVCs |
| `virtualmachines/addvolume` | get, list, watch, update, patch | Hot-plug disks to VMs |
| `virtualmachines/removevolume` | get, list, watch, update, patch | Hot-unplug disks from VMs |

---

### Step 2: Generate the Infrastructure Cluster Kubeconfig

The CSI driver running in the nested cluster needs credentials to access the infrastructure cluster. Use the provided script to generate a kubeconfig from the service account token.

```bash
# Ensure you're logged into the infrastructure cluster
oc login <infra-cluster-api-url>

# Navigate to the infra-cluster-rbac directory
cd infra-cluster-rbac

# Set namespace if not using the default (nested-cluster)
export NAMESPACE="nested-cluster"  # or your custom namespace

# Run the script to generate the kubeconfig
./create-infra-kubeconfig.sh

# The kubeconfig is saved to: infra-kubeconfig
cat infra-kubeconfig
```

The script extracts:
- The API server URL from your current context
- The CA certificate from the service account secret
- The authentication token from the service account secret

---

### Step 3: Add Kubeconfig to secrets.yaml

Copy the generated kubeconfig contents into `secrets.yaml`:

```bash
cd ..  # Return to repository root

# View the generated kubeconfig
cat infra-cluster-rbac/infra-kubeconfig
```

Edit `secrets.yaml` and replace the placeholder with your kubeconfig:

```yaml
infra:
  kubeconfig: |
    apiVersion: v1
    kind: Config
    clusters:
    - name: infra-cluster
      cluster:
        certificate-authority-data: <BASE64_CA_CERT>
        server: https://api.infra-cluster.example.com:6443
    contexts:
    - name: infra-context
      context:
        cluster: infra-cluster
        namespace: nested-cluster
        user: csi-driver-user
    current-context: infra-context
    users:
    - name: csi-driver-user
      user:
        token: <SERVICE_ACCOUNT_TOKEN>
```

> ⚠️ **Security Note**: The `secrets.yaml` file contains sensitive credentials. **Do not commit this file to version control.** Add it to `.gitignore`:
> ```bash
> echo "secrets.yaml" >> .gitignore
> ```

---

### Step 4: Configure values.yaml

Edit `kubevirt-csi-driver-helm-chart/values.yaml` to match your environment:

```yaml
# ------------------------------------------------------------------
# Infrastructure Cluster Settings
# ------------------------------------------------------------------
infra:
  # Namespace in the infra cluster where the nested cluster VMs reside
  # Must match the namespace used in Step 1
  namespace: "nested-cluster"

  # StorageClass on the infra cluster to use for creating DataVolumes
  # This should be a block-mode capable storage class
  storageClassName: "ocs-storagecluster-ceph-rbd-virtualization"

  # Labels applied to DataVolumes created on the infra cluster
  # Useful for identifying resources belonging to specific tenant clusters
  labels: "csi-driver/cluster=tenant"

  # Kubeconfig for infra cluster access (leave empty, provided via secrets.yaml)
  kubeconfig: ""

# ------------------------------------------------------------------
# Node <-> VM Mapping
# ------------------------------------------------------------------
# Maps nested cluster node names to their corresponding VM names on the infra cluster.
# This is used by a Job to annotate nodes with their VM identity,
# enabling the CSI driver to attach disks to the correct VM.
#
# Format: "Nested Cluster Node Name": "Infra Cluster VM Name"
nodeMapping:
  "worker-0": "worker-0"
  "worker-1": "worker-1"
  "worker-2": "worker-2"
  "master-0": "master-0"
  "master-1": "master-1"
  "master-2": "master-2"

# ------------------------------------------------------------------
# Images
# ------------------------------------------------------------------
images:
  # KubeVirt CSI Driver image
  driver:
    repository: quay.io/kubevirt/kubevirt-csi-driver
    tag: latest                    # Consider pinning to a specific version for production
    pullPolicy: Always

  # kubectl image used by the node annotation job
  kubectl:
    repository: bitnami/kubectl
    tag: latest

  # CSI Sidecar containers
  provisioner:
    repository: quay.io/openshift/origin-csi-external-provisioner
    tag: latest
  attacher:
    repository: quay.io/openshift/origin-csi-external-attacher
    tag: latest
  snapshotter:
    repository: k8s.gcr.io/sig-storage/csi-snapshotter
    tag: v4.2.1
  resizer:
    repository: registry.k8s.io/sig-storage/csi-resizer
    tag: v1.13.1
  nodeDriverRegistrar:
    repository: registry.k8s.io/sig-storage/csi-node-driver-registrar
    tag: v2.8.0

# ------------------------------------------------------------------
# Storage Class
# ------------------------------------------------------------------
storageClass:
  # Whether to create a StorageClass in the nested cluster
  create: true

  # Name of the StorageClass
  name: kubevirt-csi

  # Set as the default StorageClass in the nested cluster
  isDefault: true

  # When to bind PVs to PVCs:
  # - Immediate: Bind as soon as PVC is created
  # - WaitForFirstConsumer: Bind when a Pod using the PVC is scheduled
  volumeBindingMode: Immediate
```

#### Configuration Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `infra.namespace` | Namespace on infra cluster containing the VMs | `nested-cluster` |
| `infra.storageClassName` | StorageClass on infra cluster for DataVolumes | `ocs-storagecluster-ceph-rbd-virtualization` |
| `infra.labels` | Labels for DataVolumes on infra cluster | `csi-driver/cluster=tenant` |
| `nodeMapping` | Map of nested node names to infra VM names | See values.yaml |
| `images.driver.repository` | CSI driver image repository | `quay.io/kubevirt/kubevirt-csi-driver` |
| `images.driver.tag` | CSI driver image tag | `latest` |
| `storageClass.create` | Create StorageClass resource | `true` |
| `storageClass.name` | Name of the StorageClass | `kubevirt-csi` |
| `storageClass.isDefault` | Set as default StorageClass | `true` |
| `storageClass.volumeBindingMode` | Volume binding mode | `Immediate` |

#### Finding Your Node-to-VM Mapping

To find the correct mapping between nested cluster nodes and infra cluster VMs:

```bash
# On the nested cluster - list node names
oc get nodes -o name

# On the infra cluster - list VM names in the namespace
oc get vm -n <infra-namespace> -o name
```

---

### Step 5: Deploy the Helm Chart

Now deploy the CSI driver to your **nested cluster**:

```bash
# Ensure you're logged into the nested cluster
oc login <nested-cluster-api-url>

# Deploy the Helm chart
helm upgrade --install kubevirt-csi ./kubevirt-csi-driver-helm-chart \
  --namespace kubevirt-csi-driver \
  --create-namespace \
  -f kubevirt-csi-driver-helm-chart/values.yaml \
  -f secrets.yaml
```

#### Verify the Deployment

```bash
# Check all pods are running
oc get pods -n kubevirt-csi-driver

# Expected output:
# NAME                                      READY   STATUS      RESTARTS   AGE
# kubevirt-csi-controller-xxxxxxxxx-xxxxx   6/6     Running     0          1m
# kubevirt-csi-node-xxxxx                   3/3     Running     0          1m
# kubevirt-csi-node-xxxxx                   3/3     Running     0          1m
# kubevirt-csi-node-annotator-xxxxx         0/1     Completed   0          1m

# Verify the StorageClass was created
oc get storageclass kubevirt-csi

# Check CSI driver registration
oc get csidrivers
```

---

## Usage

Once deployed, you can create PVCs using the `kubevirt-csi` StorageClass:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: kubevirt-csi
  resources:
    requests:
      storage: 10Gi
```

The CSI driver will:
1. Create a DataVolume on the infra cluster
2. Wait for the DataVolume to be ready
3. Hot-plug the disk to the appropriate VM node
4. Present the disk as a PersistentVolume in the nested cluster

---

## Troubleshooting

### Check CSI Controller Logs
```bash
oc logs -n kubevirt-csi-driver deployment/kubevirt-csi-controller -c csi-driver
```

### Check CSI Node Logs
```bash
oc logs -n kubevirt-csi-driver daemonset/kubevirt-csi-node -c csi-driver
```

### Verify Node Annotations
The CSI driver requires nodes to be annotated with their corresponding VM name:
```bash
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.csi\.kubevirt\.io/infraClusterVMName}{"\n"}{end}'
```

### Check Infra Cluster Resources
```bash
# Connect to infra cluster
oc login <infra-cluster-api-url>

# Check DataVolumes created by the CSI driver
oc get datavolumes -n <infra-namespace> -l csi-driver/cluster=tenant
```

---

## Uninstallation

```bash
# Connect to nested cluster
oc login <nested-cluster-api-url>

# Uninstall the Helm release
helm uninstall kubevirt-csi -n kubevirt-csi-driver

# Optionally delete the namespace
oc delete namespace kubevirt-csi-driver
```

To clean up infra cluster resources:
```bash
# Connect to infra cluster
oc login <infra-cluster-api-url>

# Remove RBAC resources
oc delete -f infra-cluster-rbac/infra-cluster-rbac.yaml -n <infra-namespace>
```

---

## License

See [LICENSE](LICENSE) for details.
