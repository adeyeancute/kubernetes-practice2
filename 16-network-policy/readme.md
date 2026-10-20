**Note**: This practice can be done on **Killercoda kubernetes playgrounds** or on the **EKS cluster** (after enabling network policy support, see below).
## The Network policy
By default, **all traffic is allowed** within the cluster: pods can accept traffic from any source within the cluster. 

To enhance security in a cluster, **Network Policy** can be used to restrict traffic to/from a specific Pod.

When defining a network policy, we can specify the:
- **Incoming Traffic - Ingress**
- **Outgoing Traffic - Egress**

## Network policies need a CNI that enforces them

A NetworkPolicy is only a rule stored in the API. The **network plugin (CNI)** is what enforces it. If the CNI does not support policies, `kubectl apply` succeeds and **nothing is blocked**.

- **Killercoda / kubeadm with Calico or Cilium:** enforced out of the box.
- **EKS with the default Amazon VPC CNI:** supported, but **off by default**. Turn it on once per cluster:

```bash
# 1. The VPC CNI add-on uses an IAM role (IRSA) created by eksctl. Get it:
ROLE_ARN=$(aws eks describe-addon --cluster-name my-cluster --region us-east-1 --addon-name vpc-cni --query "addon.serviceAccountRoleArn" --output text)
echo $ROLE_ARN    # arn:aws:iam::<account>:role/eksctl-my-cluster-addon-vpc-cni-Role1-...

# 2. Enable network policies. ALWAYS pass --service-account-role-arn again.
aws eks update-addon --cluster-name my-cluster --region us-east-1 --addon-name vpc-cni \
  --service-account-role-arn $ROLE_ARN \
  --configuration-values '{"enableNetworkPolicy":"true"}' \
  --resolve-conflicts PRESERVE
aws eks wait addon-active --cluster-name my-cluster --region us-east-1 --addon-name vpc-cni
kubectl rollout status daemonset/aws-node -n kube-system
```
🚨 **WARNING:** if you run `update-addon` **without** `--service-account-role-arn`, EKS removes the IAM role from the `aws-node` service account. The restarted `aws-node` pods can then no longer manage pod IPs: they crash-loop (`Checking for IPAM connectivity...`, liveness probe failed) and **new pods get no network**. To repair it, run the command again with `--service-account-role-arn`.

Each `aws-node` pod now has 2 containers (`aws-node` + `aws-eks-nodeagent`, the policy agent): `READY 2/2`.

## Scenario: 

We want to deploy 3 pods in the cluster with the following specifications:

- Deploy two pods (pod-a and pod-b) in a namespace (test-ns).
- Deploy a third pod (pod-c) in a different namespace (dev-ns).
- Apply a Network Policy that allows traffic to pod-a only from pod-b, blocking others.

## Solution
1. Let's create the namespaces, the pods and the services to expose them using the content of the `01-ns-pods-svc.yaml` file

The content should look like the following:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: test-ns
---
apiVersion: v1
kind: Namespace
metadata:
  name: dev-ns
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-a
  namespace: test-ns
  labels:
    app: pod-a
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: pod-a-svc
  namespace: test-ns
spec:
  selector:
    app: pod-a
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-b
  namespace: test-ns
  labels:
    app: pod-b
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: pod-b-svc
  namespace: test-ns
spec:
  selector:
    app: pod-b
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-c
  namespace: dev-ns
  labels:
    app: pod-c
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: pod-c-svc
  namespace: dev-ns
spec:
  selector:
    app: pod-c
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```
2. Apply the file in the cluster and verify the objects created
```bash
kubectl apply -f 01-ns-pods-svc.yaml
kubectl get pods -A
kubectl get svc -A
```

3. Test the network connectivity from the pods
- Test if pod-b can talk to pod-a

```bash
kubectl exec -n test-ns pod-b -- curl -m 3 http://pod-a-svc.test-ns  # Should work 200 OK
```
- Test if pod-c can talk to pod-a

```bash
kubectl exec -n dev-ns pod-c -- curl -m 3 http://pod-a-svc.test-ns  # Should work 200 OK
```

- Test if pod-a can access pod-b
```bash
kubectl exec -n test-ns pod-a -- curl -m 3 http://pod-b-svc.test-ns # Should work 200 OK
```

- Test if pod-a can access external internet
```bash
kubectl exec -n test-ns pod-a -- curl -m 3 http://google.com # Should work 200 OK
```


4. Create the Network policy to control the traffic

Create a file with the content of the manifest `02-network-policy.yaml`

The content should look like the following

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-ingress-egress
  namespace: test-ns
spec:
  podSelector:
    matchLabels:
      app: pod-a
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: pod-b
      ports:
        - protocol: TCP
          port: 80
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: pod-b
      ports:
        - protocol: TCP
          port: 80
    # Allow DNS lookups to CoreDNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```
This network policy specifies that **pod-a can only accept traffic from pod-b** and also **pod-a can only send traffic to pod-b** (plus DNS).

**Why the DNS rule?** As soon as a pod has an `Egress` policy, **everything** not listed is blocked, including the DNS queries to CoreDNS in `kube-system`. Without that rule, `curl http://pod-b-svc.test-ns` fails because the name cannot be resolved, even though traffic to pod-b is allowed (calling pod-b by its IP would still work). Remember it every time you write an egress policy.

Apply the file to the cluster and verify
```bash
kubectl apply -f 02-network-policy.yaml
kubectl get networkpolicy -A
kubectl describe networkpolicy restrict-ingress-egress -n test-ns
```

5. Test the network connectivity from the pods
- Test if pod-b can talk to pod-a

```bash
kubectl exec -n test-ns pod-b -- curl -m 3 http://pod-a-svc.test-ns  # Should work 200 OK
```
- Test if pod-c can talk to pod-a

```bash
kubectl exec -n dev-ns pod-c -- curl -m 3 http://pod-a-svc.test-ns  # Should Fail
```

- Test if pod-a can access pod-b
```bash
kubectl exec -n test-ns pod-a -- curl -m 3 http://pod-b-svc.test-ns # Should work 200 OK
```

- Test if pod-a can access external internet
```bash
kubectl exec -n test-ns pod-a -- curl -m 3 http://google.com # Should fail
```

- Test if pod-a can access pod-c
```bash
kubectl exec -n test-ns pod-a -- curl -m 3 http://pod-c-svc.dev-ns # Should fail
```
**Note:** if pod-c can still reach pod-a, your CNI is not enforcing policies (on EKS: see "Network policies need a CNI that enforces them" above).

## Practice on denying all traffic

First delete the network policy currently applied on the pods
```bash
kubectl delete -f 02-network-policy.yaml
```
1. Apply a Network Policy that DENIES ALL Ingress and Egress


Create the network policy using the content in the manifest `04-deny-all-ingress-egress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: test-ns      # a NetworkPolicy only applies to pods in its own namespace
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: test-ns
spec:
  podSelector: {}
  policyTypes:
  - Egress
```
Apply the file to the cluster and test
```bash
kubectl apply -f 04-deny-all-ingress-egress.yaml
kubectl get networkpolicy -A
# test pod-b to pod-a Should fail (because all ingress is denied).
kubectl exec -n test-ns pod-b -- curl -m 3 http://pod-a-svc.test-ns
# test pod-c to pod-a Should fail (because all ingress is denied).
kubectl exec -n dev-ns pod-c -- curl -m 3 http://pod-a-svc.test-ns
# test pod-a to pod-b Should fail (because all egress is denied).
kubectl exec -n test-ns pod-a -- curl -m 3 http://pod-b-svc.test-ns
# test pod-a to internet Should fail (because all egress is denied).
kubectl exec -n test-ns pod-a -- curl -m 3 http://google.com
```
2. Policies are **additive** (allow rules are added up, there is no "deny" rule). Keep the deny-all policies and add `03-allow-all-ingress-egress.yaml` (an empty rule `{}` = allow everything): traffic works again.
```bash
kubectl apply -f 03-allow-all-ingress-egress.yaml
kubectl exec -n test-ns pod-b -- curl -m 3 http://pod-a-svc.test-ns   # 200 OK again
kubectl exec -n test-ns pod-a -- curl -m 3 http://google.com           # works again
kubectl delete -f 03-allow-all-ingress-egress.yaml
```
Delete the network policies
```bash
kubectl delete -f 04-deny-all-ingress-egress.yaml
```
The file `05-deny-all-traffic.yaml` does the same as `04-deny-all-ingress-egress.yaml` with one policy instead of two (`policyTypes: [Ingress, Egress]` and no rules). It is the usual "default deny" you apply to every namespace in production, followed by allow policies for each app.

## Clean Up

```bash
kubectl delete -f 05-deny-all-traffic.yaml -f 04-deny-all-ingress-egress.yaml -f 03-allow-all-ingress-egress.yaml -f 02-network-policy.yaml --ignore-not-found
kubectl delete -f 01-ns-pods-svc.yaml
```
