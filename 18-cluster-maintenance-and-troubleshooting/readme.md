# Cluster maintenance
Maintenance and troubleshooting tasks include:
- Node maintenance
- Control plane troubleshooting
- Network troubleshooting
- Application troubleshooting
- Cluster backup and upgrade
- and more

Note: These operations executed by cluster administrators. Maintenance operations may vary depending on how your cluster is setup (cloud or On-prem)

## Preparing node for maintenance
- **cordon node**: Mark the node as unschedulable. Running pods are not evicted.
- **drain node**: Mark the node as unschedulable. Running pods are evicted. Add **--ignore-daemonsets** option if daemonsets are runnig on the node
- **uncordon node**:Mark the node as schedulable after maintenance

### Practice: drain a node without dropping traffic (PodDisruptionBudget)

A **PodDisruptionBudget (PDB)** tells Kubernetes how many pods of an app must stay available during **voluntary** disruptions (drain, node upgrade, autoscaler scale-down). `kubectl drain` respects it: it evicts pods one by one and waits when an eviction would break the budget.

`01-app-with-pdb.yaml` creates a Deployment `web` with 4 replicas spread over the nodes, and a PDB `web-pdb` with `minAvailable: 3`.
```bash
kubectl apply -f 01-app-with-pdb.yaml
kubectl rollout status deployment/web
kubectl get pdb web-pdb
# ALLOWED DISRUPTIONS = 1 (4 running - 3 minimum)
kubectl get pods -l app=web -o wide
```
Pick a node that runs **2** of the `web` pods, and drain it:
```bash
NODE=<node-name>
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
```
Read the output:
```
evicting pod default/web-...-dqnxk
evicting pod default/web-...-4qhfg
error when evicting pods/"web-...-dqnxk" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/web-...-4qhfg evicted
pod/web-...-dqnxk evicted
node/<node-name> drained
```
The second eviction is **refused** until the replacement of the first pod is Ready on another node: there are never fewer than 3 pods serving traffic.
```bash
kubectl get nodes                       # the drained node shows SchedulingDisabled
kubectl get pods -l app=web -o wide     # 4 pods, none on the drained node
kubectl uncordon $NODE                  # maintenance done
kubectl delete -f 01-app-with-pdb.yaml
```
**Note:** on EKS, managed node group upgrades (`eksctl upgrade nodegroup`) and the Cluster Autoscaler / Karpenter (chapter 20) drain nodes the same way and also respect PDBs. A PDB with `minAvailable` equal to the replica count blocks every drain: don't do that.

### Real-world scenario: replace a broken worker node

Symptom seen while testing this course: every `kubectl exec` / `kubectl logs` to the pods of **one** node failed with `error: unable to upgrade connection: Unauthorized`, while the other nodes worked. Cause: a container with the `SYS_TIME` capability had changed the clock of the node to 2020 (see chapter 16), so the node TLS certificates were "not yet valid".

On EKS, nodes are **cattle, not pets**: don't repair a broken node, replace it. The managed node group (an Auto Scaling group) creates a new identical node automatically:
```bash
NODE=<broken-node-name>
kubectl cordon $NODE
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --force
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$NODE" --query "Reservations[0].Instances[0].InstanceId" --output text)
aws autoscaling terminate-instance-in-auto-scaling-group --instance-id $INSTANCE_ID --no-should-decrement-desired-capacity
kubectl get nodes -w     # a new node joins and becomes Ready after 2 to 3 minutes
```

## Cluster High availability

In production environments, it is recommended to have many nodes in the control plane (odd numbers: 3, 5 ..) running for high availability.

## Backing up a cluster
**Note:** on EKS (and every managed Kubernetes) AWS runs and backs up the control plane, including etcd: you have no access to etcd. You back up **your** objects and volumes instead (Velero, AWS Backup, and Git with ArgoCD in chapter 21). The `etcdctl` commands below apply to self-managed clusters (kubeadm, Killercoda).

For disaster recovery, it is important to backup cluster state periodically. This can be done by taking a snapshot of the etcd (`etcdctl snapshot save` with necessary parameters). To restore the state of the cluster, use `etcdctl snapshot restore` with necessary options.
It is also useful to save cluster certificates.

See official documentation for more

## Upgrading kubeadm clusters

As kubernetes versions evolve, you might need to upgrade your cluster to a recent version.
See official documentation for more

## Some EKS Cluster Maintenance Scenarios

Here are few common **Amazon EKS maintenance scenarios**

### **1. Rolling Upgrade of Worker Nodes**

#### **Scenario**
Your EKS cluster is running on outdated worker nodes with an older instance type, OS version, or AMI, and you need to upgrade them to ensure security, performance, and compliance without downtime.

#### **Tools to Use**
- **`kubectl cordon` and `kubectl drain`** – To safely migrate workloads off old nodes.
- **AWS EKS Managed Node Groups** – To create a new node group with updated configurations.
- **AWS Auto Scaling** – To dynamically adjust the number of nodes.
- **`kubectl get nodes`** – To monitor node status.

---

### **2. Kubernetes Version Upgrade**
#### **Scenario**
Your EKS cluster is running an older Kubernetes version that is reaching its **end of support**, and you need to upgrade to a newer version to take advantage of performance improvements, security patches, and new features.

#### **Tools to Use**
- **AWS CLI (`aws eks update-cluster-version`)** – To update the EKS control plane.
- **eksctl** – To upgrade worker nodes in managed or self-managed node groups.
- **`kubectl version`** – To check compatibility between cluster and client versions.
- **`kubectl apply`** – To upgrade critical components like CoreDNS and kube-proxy.

---

### **3. Cluster Autoscaler for Cost Optimization**
#### **Scenario**
Your cluster has **fluctuating workloads**, and you need to ensure efficient resource allocation while optimizing costs by automatically scaling the number of worker nodes up or down based on demand.

#### **Tools to Use**
- **Cluster Autoscaler** – Kubernetes component that adjusts the number of worker nodes dynamically.
- **AWS Auto Scaling Groups** – Manages node scaling at the infrastructure level.
- **IAM Policies for Autoscaler** – Ensures Kubernetes has permission to request new nodes.
- **`kubectl logs` for Cluster Autoscaler** – To troubleshoot scaling behavior.

---

### **4. Implementing Pod Disruption Budgets (PDB) for High Availability**
#### **Scenario**
Your cluster runs **critical applications**, and you want to ensure that essential workloads remain available during maintenance activities like node upgrades, autoscaling events, or unexpected failures.

#### **Tools to Use**
- **Pod Disruption Budgets (PDB)** – Defines the minimum number of replicas that must always be available.
- **`kubectl get pdb`** – To verify PDB configurations.
- **Deployment Replica Sets** – Ensures redundancy in application instances.
- **`kubectl drain` with PDB enforcement** – Ensures safe node maintenance without breaking services.

---

### **5. Backup and Disaster Recovery Planning**
#### **Scenario**
You need a **disaster recovery plan** to ensure that in case of accidental data loss, cluster failure, or region outage, you can restore workloads and persistent data with minimal downtime.

#### **Tools to Use**
- **Velero** – Backup and restore tool for Kubernetes resources and persistent volumes.
- **AWS Backup** – Managed backup solution for EBS volumes used by pods.
- **`kubectl get all -o yaml`** – To manually export Kubernetes objects for backup.
- **S3 or EFS** – To store backups securely and enable cross-region recovery.

---


## Troubleshooting in kubernetes clusters

### Kubectl Commands & Their Roles

Some commands that help troubleshoot:

| Command | Role/Purpose | When to Use |
|---------|-------------|-------------|
| `kubectl describe <resource>` | Shows detailed configuration, events, and state of a resource (Pod, Node, Service, etc.) | Debugging why a Pod is stuck, checking Node conditions, or inspecting Service endpoints |
| `kubectl logs <pod>` | Retrieves logs from a running Pod's primary container | Debugging application errors or crashes |
| `kubectl get pod/<pod> -o yaml > file.yaml` | Exports the full Pod manifest (YAML) to a file | Analyzing Pod specs, debugging misconfigurations, or backing up definitions |
| `kubectl exec <pod> -- <command>` | Executes a command inside a Pod's primary container | Running diagnostic tools (`curl`, `ping`, `nslookup`) or checking files |
| `kubectl exec <pod> -c <container> -- <command>` | Executes a command in a specific container (multi-container Pods) | Debugging sidecar containers |
| `kubectl logs --previous <pod> -c <container>` | Shows logs from a previously crashed container | Diagnosing `CrashLoopBackOff` errors |
| `kubectl debug -it <pod> --image=<image> --target=<pod>` | Creates an ephemeral debug container attached to a Pod | Troubleshooting containers or when the Pod lacks shells (`/bin/sh`) |

### Key Log Files & Their Roles

| Log File | Role/Purpose | When to Check |
|----------|-------------|---------------|
| `/var/log/syslog` | System-wide logs (includes `kubelet`, `docker`, `containerd`) | Node-level issues (e.g., `kubelet` crashes, Docker daemon failures) |
| `/var/log/kube-apiserver.log` | API server logs (control plane) | Authentication errors, API throttling, or `kubectl` connectivity issues |
| `/var/log/kube-scheduler.log` | Scheduler decision logs | Debugging Pod scheduling failures (`Pending` state) |
| `/var/log/kube-controller-manager.log` | Controller manager logs (replica sets, deployments) | Issues with scaling or replication |
| `/var/log/pods/` | Logs for all Pods (symlinked to container logs) | Debugging application-specific logs without `kubectl` |
| `/var/lib/docker/containers/` | Raw Docker container logs (if using Docker runtime) | Low-level container runtime issues |
| `/var/log/kubelet.log` | `kubelet` logs (node agent) | Pod startup failures, volume mounting errors |
| `/var/log/kube-proxy.log` | `kube-proxy` logs (network rules) | Service networking issues (e.g., `ClusterIP` not working) |

### Cluster-Wide Debugging Commands

| Command | Role/Purpose | When to Use |
|---------|-------------|-------------|
| `kubectl cluster-info dump` | Dumps full cluster state (Pods, Nodes, Events) to stdout/files | Post-mortem analysis or opening support tickets |
| `journalctl -u kubelet` | Systemd logs for the `kubelet` service | When `kubelet` fails to start or crashes |

### Summary of Use Cases

- **Pod Issues**: Use `kubectl describe`, `logs`, `exec`, and `/var/log/pods/`
- **Node Issues**: Check `kubectl get nodes`, `journalctl -u kubelet`, and `/var/log/syslog`
- **Control Plane Issues**: Inspect `kube-apiserver.log`, `kube-scheduler.log`, and `cluster-info dump`
- **Networking Issues**: Debug with `kube-proxy.log` and `kubectl get endpoints`

## Cleanup

This chapter does not create persistent cluster resources. If you cordoned or drained nodes during practice, uncordon them so the cluster returns to normal:

```bash
kubectl uncordon <node-name>
```
