**Note**: This practice can be done on **Killercoda kubernetes playgrounds** except for the **autoscaling** part.

## The Deployment

A **deployment** is a higher level object that creates and manages ReplicaSets which then ensures that the desired number of pods are running. More than a simple replicaset, the deployment allows you to handle **rolling updates (rollout), rollbacks and version management** of applications.

**Example:** Create a deployment that will run three Nginx pods, each listening on port 80.

1. Create and verify the deployment
Create a manifest called `01-nginx-deployment.yaml`. Its content should look like the following:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.26
        ports:
        - containerPort: 80
```

2. Apply the manifest in the cluster and verify the objects created
```bash
# create and apply the manifest
kubectl apply -f 01-nginx-deployment.yaml
#
# Verify the deployment, rs, pods
kubectl get deployment
kubectl get pods
kubectl get rs
kubectl describe deployment nginx-deployment
#
# delete a pod and verify it is replaces
kubectl delete pod <pod-name>
kubectl get pods -o wide
```

3. Update the deployment (rollout)

- Update the nginx image from 1.26 to 1.27

Let's update the nginx Pods to use the `nginx:1.27` image instead of the `nginx:1.26` image
```bash
kubectl set image deployment/nginx-deployment nginx=nginx:1.27
```
To see the rollout status, run:
```bash
kubectl rollout status deployment/nginx-deployment
```
Verify that the image was updated:
```bash
kubectl get deployments
kubectl get rs
kubectl get pods
kubectl describe deployment nginx-deployment
```
NB: you can also use the `kubectl edit` command to update the manifest

- Update the image including and error: instead of 1.27 use 1.27nf
```bash
kubectl set image deployment/nginx-deployment nginx=nginx:1.27nf
```
To see the rollout status, run:
```bash
kubectl rollout status deployment/nginx-deployment
```
Verify:
```bash
kubectl get deployments
kubectl get rs
kubectl get pods
kubectl describe deployment nginx-deployment
```
Note:
The Deployment controller stops the bad rollout automatically.

4. Check the rollout history of a deployment
```bash
kubectl rollout history deployment/nginx-deployment
# Example see the details of revision 2
kubectl rollout history deployment/nginx-deployment --revision=2
```

5. Rolling back to a previous revision
```bash
# undo the current rollout and rollback to the previous revision
kubectl rollout undo deployment/nginx-deployment
kubectl get deployment nginx-deployment
kubectl describe deployment nginx-deployment
```
6. Scale the deployment up and down
```bash
kubectl scale deployment/nginx-deployment --replicas=5
kubectl get pods
kubectl get rs
kubectl scale deployment/nginx-deployment --replicas=2
kubectl get pods
kubectl get rs
```
7. Delete the deployment
```bash
kubectl delete deployment nginx-deployment
```


### The Deployment strategy type
The Strategy type in the deployment specification defined how the update process takes place. It can take two values:  
- **RollingUpdate (default value):** Here the pods are replaced gradually, reducing downtime. In this type, we have two key parameters that we can specify:
    - **maxUnavailable:** Number of pods that can be unavailable during update
    - **maxSurge:** Number of extra pods (above the specified number of replicas) allowed during update.
- **Recreate:** Deletes all old pods at once, then creates new ones.This is to be used when the app can handle downtime

Example: check the `02-deployment-rolling-update.yaml` and `03-deployment-recreate.yaml`
- Deployment with rolling update strategy
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.26
        ports:
        - containerPort: 80
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
```

- Deployment with recreate strategy
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.26
        ports:
        - containerPort: 80
  strategy:
    type: Recreate
```

**Compare the two strategies.** Open a second terminal and watch the pods while you update the image:
```bash
# terminal 2
kubectl get pods -l app=nginx -w
```
```bash
# terminal 1: RollingUpdate. Old and new pods overlap: never more than 1 pod down (maxUnavailable: 1)
kubectl apply -f 02-deployment-rolling-update.yaml
kubectl rollout status deployment/nginx-deployment
kubectl set image deployment/nginx-deployment nginx=nginx:1.27
kubectl rollout status deployment/nginx-deployment

# terminal 1: Recreate. ALL old pods go to Terminating first, and only then the new pods are created
kubectl apply -f 03-deployment-recreate.yaml
kubectl rollout status deployment/nginx-deployment
kubectl set image deployment/nginx-deployment nginx=nginx:1.26
kubectl rollout status deployment/nginx-deployment
```
With Recreate there is a moment where **0 pods are Running**: that is the downtime. Use it only when two versions of the app must never run at the same time (for example a database schema change).

```bash
kubectl delete -f 03-deployment-recreate.yaml
```

### Autoscaling a deployment (HPA)
To enable autoscaling for a deployment, we need a specific object called **HPA (Horizontal Pod Autoscaler)** that will automatically scale the application up or down based on the load.

**Note:** The HPA setup is generally done by the kubernetes administrators. When the HPA is enabled in your cluster, you can use the `kubectl autoscale` command to autoscale a deployment.

#### Steps to get started with HPA

- Install the metrics server in the cluster
- Deploy an application (Deployment)
- Create the Horizontal Pod Autoscaler for the deployment And monitor the HPA events 
- Create the load and check how the HPA is working (it should scale up)
- Reduce the load (the HPA should scale down the pods)
- Clean up (optional)

The full hands-on practice is in chapter 20 ([Autoscaling](../20-autoscaling-hpa-ca-karpenter-keda/readme.md)).

## Cleanup

```bash
kubectl delete -f 01-nginx-deployment.yaml --ignore-not-found
kubectl delete -f 02-deployment-rolling-update.yaml --ignore-not-found
kubectl delete -f 03-deployment-recreate.yaml --ignore-not-found
kubectl delete -f beta-deployment.yaml --ignore-not-found
```
