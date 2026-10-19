**Note: In this lab we will use the EKS cluster `my-cluster` created with eksctl (chapter 00).**

# Lab 2: Deploying WordPress and MySQL with Persistent Volumes

In this Lab, we will deploy WordPress and MySQL in Kubernetes using persistent storage, and prove that the data survives when the pods are deleted.

## Architecture

| Tier | Kubernetes objects | Storage | Why this storage |
|---|---|---|---|
| MySQL | Deployment (1 replica, strategy `Recreate`), headless Service `wordpress-mysql` | PVC `mysql-pv-claim`, **EBS gp3**, `ReadWriteOnce` | a database needs fast block storage, used by one pod at a time |
| WordPress | Deployment, Service `wordpress`, Ingress `wordpress` | PVC `wp-pv-claim`, **EFS**, `ReadWriteMany` | uploads and plugins must be shared if you scale WordPress to several pods |
| Config | Secret `mysql-pass`, ConfigMap `wp-mysql-config` | | password in a Secret, the rest in a ConfigMap |

## Prerequisites
- The EKS cluster and the knowledge of the objects used here (Pods, Deployment, Service, PV, PVC, ConfigMap and Secret).
- **Chapter 13**, dynamic storage:
  - EBS CSI driver add-on + the **`gp3`** StorageClass (`13-persistent-storage/ebs-volume`)
  - EFS file system + EFS CSI driver add-on + the **`efs-sc`** StorageClass (`13-persistent-storage/efs-volume`)
- **Chapter 07**, HTTPS URL: AWS Load Balancer Controller, ExternalDNS and the ACM wildcard certificate. Replace `wordpress.afriqhome.com` with your own subdomain in `04-wordpress-deployment.yaml`.

Check the StorageClasses:
```bash
kubectl get storageclass
# efs-sc, gp2, gp3 (default)
```

## Create and apply the YAML files to deploy the app
```bash
kubectl apply -f 01-secret.yaml
kubectl apply -f 02-configmap.yaml
kubectl apply -f 03-mysql-deployment.yaml
kubectl apply -f 04-wordpress-deployment.yaml
```
## Verify the objects created

```bash
kubectl get secret,cm,deployment,pods,svc,ingress
kubectl get pvc
# mysql-pv-claim   Bound   ...   RWO   gp3
# wp-pv-claim      Bound   ...   RWX   efs-sc
kubectl logs deploy/wordpress-mysql | grep "ready for connections"
```
MySQL needs about 30 seconds to initialize its database the first time.

## Test the app
```bash
kubectl get ingress wordpress
kubectl logs -n external-dns deploy/external-dns | grep wordpress
# wait for "CREATE wordpress.afriqhome.com", then 1 to 3 minutes
```
Open **https://wordpress.afriqhome.com** in your browser, choose a language, then create the site (title, admin user, password).

### Expected result:
![wordpress](wordpress.png)

## Prove the persistence

The data lives on the volumes, not in the pods. Delete both pods and watch Kubernetes recreate them:
```bash
kubectl delete pod -l tier=mysql
kubectl rollout status deployment/wordpress-mysql
kubectl delete pod -l tier=frontend
kubectl rollout status deployment/wordpress
```
Reload the site: it is **still installed**, with your title and your admin user. Without the MySQL PVC, the new MySQL pod would start with an empty database and WordPress would show the installation page again.

## Clean up

Delete all the resources created
```bash
kubectl delete -f 04-wordpress-deployment.yaml   # also deletes the ALB; ExternalDNS removes the DNS record
kubectl delete -f 03-mysql-deployment.yaml       # the PVC is deleted => the EBS volume is deleted
kubectl delete -f 02-configmap.yaml
kubectl delete -f 01-secret.yaml
```
Note: if you created a specific directory to hold all your yaml files, you can delete the corresponding objects created with one command:

```bash
kubectl delete -f .
```
