**Note**: Parts 1 and 2 can be done on **Killercoda kubernetes playgrounds** or any cluster. Part 3 needs a default StorageClass (`kubectl get storageclass` must show one marked `(default)`). On EKS, do it after chapter 14 (Persistent storage), which installs the EBS CSI driver and the `gp3` StorageClass.

## The StatefulSet

A **StatefulSet** runs pods that each have their **own identity**: a fixed name, a fixed DNS name and, usually, their own disk. It is made for applications that keep data or need to know "who is who": databases (PostgreSQL, MySQL), message brokers (Kafka, RabbitMQ), search engines (Elasticsearch), coordination services (ZooKeeper, etcd).

A **Deployment** (chapter 04) treats its pods as **interchangeable**: any pod can be killed and replaced by a new one with a new random name, on any node. That is perfect for a web app or an API that keeps its data elsewhere (stateless). It is wrong for a database: replica 2 of a database is not "any pod", it is the pod that owns a specific copy of the data.

## Deployment vs StatefulSet

| | Deployment | StatefulSet |
|---|---|---|
| Pod names | random: `web-deploy-7d9f8c6b5-x2k4p` | fixed, numbered: `web-0`, `web-1`, `web-2` |
| Pod replaced after a deletion | new name, new random identity | **same name**, same DNS name, same volume |
| Start order | all pods at the same time | one by one: `web-0` must be Ready before `web-1` is created |
| Scale down | random pods are removed | highest number first (`web-2`, then `web-1`) |
| Rolling update | new pods created, old ones removed (maxSurge / maxUnavailable) | one pod at a time, from the highest number down |
| Network identity | one Service IP in front of all pods | a **headless Service**: one DNS name per pod (`web-0.web`) |
| Storage | all pods share the same volume (or none) | `volumeClaimTemplates`: **one PVC per pod** (`data-db-0`, `data-db-1`), kept when the pod moves |
| PVCs when you delete or scale down | n/a | **kept** (your data is not deleted by accident, but you pay for it until you delete it) |
| Typical use | web apps, APIs, workers (stateless) | databases, Kafka, ZooKeeper, Elasticsearch (stateful) |

**In one sentence:** a Deployment manages a herd of identical pods; a StatefulSet manages a list of named pods, each with its own identity and its own data.

### The headless Service

A normal Service (chapter 07) has one virtual IP that load-balances across all pods. A **headless Service** (`clusterIP: None`) has no virtual IP: its DNS name returns the IPs of the pods, and **each pod gets its own DNS name**:
```
<pod-name>.<service-name>.<namespace>.svc.cluster.local
web-0.web.default.svc.cluster.local
```
This is how database replicas find each other ("the leader is `db-0.db`") and how a client can talk to one specific replica. A StatefulSet must point to its headless Service with `serviceName`.

## Part 1: stable names and ordered start

1. Create the headless Service and the StatefulSet (`01-headless-service.yaml`, `02-statefulset-web.yaml`). Open a second terminal to watch the pods:
```bash
# terminal 2
kubectl get pods -l app=web -w
```
```bash
# terminal 1
kubectl apply -f 01-headless-service.yaml
kubectl apply -f 02-statefulset-web.yaml
```
In terminal 2, the pods appear **one after the other**: `web-0` is created, becomes Ready, then `web-1`, then `web-2`.

(The warning `spec.SessionAffinity is ignored for headless services` is harmless: a headless Service has no virtual IP, so it cannot pin clients to a pod.)

2. Compare with a Deployment (`04-deployment-for-comparison.yaml`):
```bash
kubectl apply -f 04-deployment-for-comparison.yaml
kubectl get pods -l app=web-deploy       # 3 pods created at the same time, random names
kubectl get pods -l app=web              # web-0, web-1, web-2
```

3. Delete one pod of each:
```bash
kubectl delete pod web-1
kubectl delete pod -l app=web-deploy --wait=false
kubectl get pods
```
`web-1` comes back as **`web-1`**. The Deployment pods come back with **new random names**.

4. Scale down and up:
```bash
kubectl scale statefulset web --replicas=1   # web-2 goes first, then web-1
kubectl scale statefulset web --replicas=3   # web-1 comes back, then web-2
```

## Part 2: one DNS name per pod

Start a temporary pod and resolve the names:
```bash
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- sh
```
```sh
nslookup web.default.svc.cluster.local         # the headless Service: the IPs of the 3 pods
nslookup web-0.web.default.svc.cluster.local   # exactly one IP: the pod web-0
nslookup web-2.web.default.svc.cluster.local
exit
```
Compare with `kubectl get pods -l app=web -o wide`: same IPs. Then delete `web-0` and resolve its name again: the **IP changed** (new pod), the **name did not**. Clients use the name, so they keep working.

**Note:** inside a pod, the short form `web-0.web` also works for most apps. With busybox `nslookup`, use the full name: `.web` is a real internet domain, and busybox may ask the internet first (the answer `127.0.53.53` means "name collision").

## Part 3: one volume per pod

`03-statefulset-with-storage.yaml` creates a StatefulSet `db` with `volumeClaimTemplates`. Each pod writes a line to `/data/history.log` every time it starts.

1. Create it and look at the PVCs:
```bash
kubectl apply -f 03-statefulset-with-storage.yaml
kubectl rollout status statefulset db
kubectl get pvc                     # data-db-0 and data-db-1: one per pod, named <template>-<pod>
kubectl exec db-0 -- cat /data/history.log
```

2. Delete `db-0` and read the file again:
```bash
kubectl delete pod db-0
kubectl wait pod db-0 --for=condition=Ready --timeout=120s
kubectl exec db-0 -- cat /data/history.log
```
Two lines: the new `db-0` got back **the same volume**, so the data written by the old pod is still there. With a Deployment, a replaced pod has no link to any specific volume.

3. Each pod has its own data:
```bash
kubectl exec db-1 -- cat /data/history.log    # only db-1's lines
```

4. Scale down, then delete the StatefulSet. Watch the PVCs:
```bash
kubectl scale statefulset db --replicas=1
kubectl get pvc                     # data-db-1 is still there: scaling down does not delete data
kubectl delete statefulset db
kubectl get pvc                     # both PVCs are still there
```
Kubernetes keeps the PVCs on purpose: deleting a database by mistake must not delete its data. The other side: the disks keep costing money until **you** delete the PVCs (see Cleanup). Since Kubernetes 1.27, `spec.persistentVolumeClaimRetentionPolicy` can change that (`whenDeleted: Delete`, `whenScaled: Delete`).

## Should the database run in the cluster?

**Usually no.** In production on AWS, most teams keep the database **outside** the cluster in a managed service: **Amazon RDS / Aurora** (PostgreSQL, MySQL), **ElastiCache** (Redis), **Amazon MSK** (Kafka), **OpenSearch Service**. The app runs in Kubernetes as a Deployment and connects to the database endpoint, with the password in a Secret. The managed service gives you, without any work:
- automated backups and point-in-time restore,
- Multi-AZ replication and automatic failover,
- engine patching and version upgrades,
- storage that grows by itself, monitoring, encryption.

With a StatefulSet, **all of that is your job**.

**When StatefulSets are used in the cluster:**
- dev, test and CI environments: a throwaway database per environment or per pull request, fast and cheap;
- platforms that must run anywhere (on-premises, several clouds), where no managed service exists;
- systems built to run on Kubernetes with an **Operator** that automates backups, replication and failover: CloudNativePG (PostgreSQL), Strimzi (Kafka), ECK (Elasticsearch), the Prometheus operator (chapter 23 explains operators);
- tools that ship as StatefulSets: Prometheus, Loki, Vault, Redis, RabbitMQ.

## Why a StatefulSet needs care

A Deployment pod can be deleted any time: worst case, a request fails. A StatefulSet holds data, and mistakes lose data or cause downtime:

- **The data lives on a volume tied to one zone.** An EBS volume exists in one availability zone. If `db-0`'s volume is in `us-east-1a` and no node with free capacity is left in that zone, `db-0` stays `Pending` forever. Keep nodes in every zone (or use EFS for shared files).
- **Volumes outlive the pods.** PVCs are kept after a scale down or a delete: good for safety, but forgotten volumes keep billing. And with a reclaim policy `Delete`, deleting the PVC deletes the disk **and the data** for good.
- **Replication and failover are not automatic.** A StatefulSet restarts `db-0`; it does not promote a replica to leader, copy data to a new replica or fix a split brain. That is the job of the application or of an Operator.
- **Updates and node maintenance are one pod at a time.** A rolling update waits for each pod to be Ready. If the new version crashes on `db-2`, the update stops there, and a rollback may need manual action. Draining a node moves a database replica: protect it with a PodDisruptionBudget (chapter 19).
- **Never force-delete a StatefulSet pod** (`kubectl delete pod db-0 --force --grace-period=0`) when its node is unreachable: the old `db-0` may still be running and writing, and two pods with the same identity can corrupt the data.
- **Backups are your job.** A PVC is not a backup. Use volume snapshots, a tool like Velero, or the database's own backup, and test the restore.

## Check yourself

- **Explain it:** What is the difference between a Deployment and a StatefulSet? Give an example of an app for each.
- **What happens when** you delete the pod `db-0`? What is the same afterwards, and what is different?
- **Explain it:** What is a headless Service, and why does a StatefulSet need one?
- **What happens to the data** when you scale a StatefulSet from 3 to 1? And when you delete the StatefulSet?
- **Explain it:** In what order are the pods of a StatefulSet created, deleted when scaling down, and updated?
- **Your choice:** the team wants PostgreSQL for a production app on EKS. StatefulSet or Amazon RDS? Why? When would the other answer be right?

## Cleanup

```bash
kubectl delete -f 02-statefulset-web.yaml --ignore-not-found
kubectl delete -f 01-headless-service.yaml --ignore-not-found
kubectl delete -f 04-deployment-for-comparison.yaml --ignore-not-found
kubectl delete -f 03-statefulset-with-storage.yaml --ignore-not-found
# the PVCs are NOT deleted with the StatefulSet: delete them to delete the volumes
kubectl delete pvc -l app=db
kubectl get pvc
```
