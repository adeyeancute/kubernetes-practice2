**Note**: This practice can be done on **Killercoda kubernetes playgrounds**

## Resource Quota in a cluster

When a cluster is shared by multiple teams, it becomes necessary to limit the amount of resources that can be used by each team. Resource Quota allows you to limit resource usage in the cluster.
- We can create resource quotas per namespace on compute resources such as memory, cpu etc.
- We can also create resource limits based on the number of objects of a certain type created in a namespace.

## Practice
1. Create a resource quota in the dev namespace (cpu: request = 1, limits =2, Memory: request=1Gi, limits=2Gi) an verify.
- Create the namespace dev
```bash
kubectl create ns dev
```
- Create the resource quota using the content in the manifest `01-dev-quota.yaml`
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-dev
  namespace: dev
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
```
- Apply and verify the object created
```bash
kubectl apply -f 01-dev-quota.yaml
kubectl get quota -A
```
- Create pods in the cluster and verify if the quota applies:

Create the pods using the content in the manifest `02-pods-quota-dev.yaml`. The first two pods will be created but the 3rd pod won't be created due to resource requests and limits

```yaml
# pod 1 in dev namespace
apiVersion: v1
kind: Pod
metadata:
  name: pod1-dev
  namespace: dev
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    resources:
      limits:
        memory: "800Mi"
        cpu: "1000m"
      requests:
        memory: "600Mi"
        cpu: "350m"
---
# pod 2 in dev namespace
apiVersion: v1
kind: Pod
metadata:
  name: pod2-dev
  namespace: dev
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    resources:
      limits:
        memory: "300Mi"
        cpu: "500m"
      requests:
        memory: "200Mi"
        cpu: "350m"
---
# Pod 3 in the dev namespace. This pod won't be created
apiVersion: v1
kind: Pod
metadata:
  name: pod-quota3-dev
  namespace: dev
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    resources:
      limits:
        memory: "800Mi"
        cpu: "1000m"
      requests:
        memory: "600Mi"
        cpu: "350m"
```
- Apply and verify the object created
```bash
kubectl apply -f 02-pods-quota-dev.yaml
# you will have and error at the creation of pod 3
```

2. Create a resource quota in the test namespace (cpu: request = 1, limits =2, Memory: request=1Gi, limits=2Gi) but also limit the number of pods to 1.

- Create the resource quota using the content in the manifest `03-test-quota.yaml`
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-test
  namespace: test
spec:
  hard:
    pods: "1"
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
```
- Apply and verify the object created
```bash
kubectl create ns test
kubectl apply -f 03-test-quota.yaml
kubectl get quota -A
```
- Create pods in the cluster and verify if the quota applies:

Create the pods using the content in the manifest `04-pods-quota-test.yaml`. The first pod will be created but the second pod won't be created due to the number of pods limit.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod1-test
  namespace: test
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    resources:
      limits:
        memory: "800Mi"
        cpu: "1000m"
      requests:
        memory: "600Mi"
        cpu: "350m"
---
# this pod won't be created
apiVersion: v1
kind: Pod
metadata:
  name: pod2-test
  namespace: test
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    resources:
      limits:
        memory: "300Mi"
        cpu: "500m"
      requests:
        memory: "200Mi"
        cpu: "350m"
```
- Apply and verify the object created
```bash
kubectl apply -f 04-pods-quota-test.yaml
# you will get an error at the creation of the second pod
```

- Delete the objects

```bash
kubectl delete -f 01-dev-quota.yaml
kubectl delete -f 02-pods-quota-dev.yaml
kubectl delete -f 03-test-quota.yaml
kubectl delete -f 04-pods-quota-test.yaml
```

## LimitRange

A ResourceQuota caps the **total** for a namespace. A **LimitRange** works **per container** (or per pod / per PVC):
- It sets **default** requests and limits for containers that do not specify any.
- It enforces a **min** and **max** for each container.

This matters with quotas: once a namespace has a CPU/memory ResourceQuota, every pod **must** declare requests and limits or it is rejected. A LimitRange with defaults fixes that automatically.

**Example**: In the namespace `limits-demo`, default containers to 100m/128Mi requests and 300m/256Mi limits, and allow at most 1 CPU / 512Mi per container. The manifest is `05-limitrange-dev.yaml`
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: container-limits
  namespace: limits-demo
spec:
  limits:
  - type: Container
    default:
      cpu: 300m
      memory: 256Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    max:
      cpu: "1"
      memory: 512Mi
    min:
      cpu: 50m
      memory: 32Mi
```
```bash
kubectl apply -f 05-limitrange-dev.yaml
kubectl describe limitrange container-limits -n limits-demo
```
Now create two pods with `06-pods-limitrange.yaml`: `pod-defaults` sets no resources, `pod-too-big` asks for a 1Gi memory limit.
```bash
kubectl apply -f 06-pods-limitrange.yaml
# pod-too-big is rejected: "maximum memory usage per Container is 512Mi, but limit is 1Gi"
kubectl get pod pod-defaults -n limits-demo -o jsonpath='{.spec.containers[0].resources}'; echo
# the defaults were injected: requests 100m/128Mi, limits 300m/256Mi
```

## Cleanup

```bash
kubectl delete ns limits-demo --ignore-not-found
kubectl delete -f 02-pods-quota-dev.yaml --ignore-not-found
kubectl delete -f 04-pods-quota-test.yaml --ignore-not-found
kubectl delete -f 01-dev-quota.yaml --ignore-not-found
kubectl delete -f 03-test-quota.yaml --ignore-not-found
kubectl delete ns dev --ignore-not-found
kubectl delete ns test --ignore-not-found
```
