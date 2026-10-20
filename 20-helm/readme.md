## What is Helm?

Helm is a package manager for kuberetes. See it as apt for ubuntu or yum for redhat

With Helm, users can install, upgrade and uninstall applications on a Kubernetes cluster using few commands

### Helm 3 architecture and terminology

- **Helm client**: command-line tool used to manage Kubernetes applications with Helm
- **Helm Chart:** A package of Kubernetes resources (templates & configs) used to deploy an app.
- **Repository:** A storage location for Helm charts (local or remote, public or private).
- **Release:** A running instance of a chart in a Kubernetes cluster.
- **Release Namespace:** The Kubernetes namespace where a release is deployed.
- **Values:** Configurable parameters used to customize a chart’s deployment.
- **Template:** Dynamic YAML files that generate Kubernetes resources using provided values.
- **Tiller**: Deprecated server component in Helm 2 (removed in Helm 3).
- **Dependency**: A chart that another chart relies on for deployment.
- **Upgrade**: Updating an existing release with new chart versions or configs.
- **Rollback:** Reverting a release to a previous working version.

### Helm chart structure

```
helm-chart-name/           # Root directory of the Helm chart
├── charts/                # Directory for dependencies (empty by default)
├── templates/             # Kubernetes resource templates
│   ├── _helpers.tpl       # Template helpers (labels, functions, etc.)
│   ├── deployment.yaml    # Kubernetes Deployment manifest
│   ├── hpa.yaml           # Horizontal Pod Autoscaler (optional)
│   ├── ingress.yaml       # Ingress manifest (optional)
│   ├── NOTES.txt          # Instructions after chart installation
│   ├── service.yaml       # Kubernetes Service manifest
│   ├── serviceaccount.yaml # ServiceAccount (optional)
│   ├── tests/             # Test templates
│   │   ├── test-connection.yaml  # Example test template
├── .helmignore            # Files to ignore when packaging the chart
├── Chart.yaml             # Metadata about the Helm chart (name, version, description)
├── values.yaml            # Default configuration values for the chart
├── values.schema.json     # JSON schema for values validation (optional)
├── README.md              # Documentation for the Helm chart
```


### Helm installation

The official documentation for [installing Helm](https://helm.sh/docs/intro/install/) shows how to install the Helm CLI on various systems.
You can use `choco install kubernetes-helm` on Windows and `brew install helm` on MAC

### Basic Helm commands
| Command | Syntax | Example |
|---------|--------|---------|
| **Search for a chart in artifact Hub** | `helm search hub <chart-name>` | `helm search hub nginx` |
| **Install a chart** | `helm install <release-name> <chart>` | `helm install my-release nginx` |
| **Upgrade a release** | `helm upgrade <release-name> <chart>` | `helm upgrade my-release nginx` |
| **List releases** | `helm list` | `helm list` |
| **Search for a chart** | `helm search repo <keyword>` | `helm search repo nginx` |
| **Add a chart repository** | `helm repo add <repo-name> <repo-url>` | `helm repo add bitnami https://charts.bitnami.com/bitnami` |
| **Update chart repositories** | `helm repo update` | `helm repo update` |
| **Show values of a chart** | `helm show values <chart>` | `helm show values nginx` |
| **Get the status of a release** | `helm status <release-name>` | `helm status my-release` |
| **Rollback a release** | `helm rollback <release-name> <revision>` | `helm rollback my-release 1` |
| **Get the history of a release** | `helm history <release-name>` | `helm history my-release` |
| **Fetch chart information** | `helm show chart <chart>` | `helm show chart nginx` |
| **Get manifest of a release** | `helm get manifest <release-name>` | `helm get manifest my-release` |
| **Uninstall a release** | `helm uninstall <release-name>` | `helm uninstall my-release` |
| **Remove chart repositories** | `helm repo remove` | `helm repo remove` |

You could get all these commands and more from the Helm cheat sheet: [Link here](https://helm.sh/docs/intro/cheatsheet/)

**Note: Before getting to the Lab, make sure your EKS cluster is up and accessible.**



### Practice 1 : Use helm to install prometheus and grafana in your cluster for monitoring:

1. Add the prometheus helm repository
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

2. Create the namespace and install the app
```bash
kubectl create ns monitoring
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring   -f prometheus-values.yaml --wait --timeout 10m
```
`prometheus-values.yaml` overrides only a few chart values: the Grafana admin password, an HTTPS Ingress for Grafana at `grafana.afriqhome.com` (ALB + ACM certificate + ExternalDNS record, see chapter 08; replace the domain with yours), a smaller Prometheus, and no Alertmanager. This is the **values file pattern**: never edit the chart, override its values.

See every value you could override:
```bash
helm show values prometheus-community/kube-prometheus-stack | less
```

3. Use the prometheus grafana stack for monitoring kubernetes cluster live
```bash
kubectl get pods -n monitoring
# grafana, prometheus, the prometheus operator, kube-state-metrics, one node-exporter per node
kubectl get ingress -n monitoring
kubectl logs -n external-dns deploy/external-dns | grep grafana
# wait for "CREATE grafana.afriqhome.com", then about 1 minute
```
Open **https://grafana.afriqhome.com**, log in as `admin` with the password from `prometheus-values.yaml`, and open **Dashboards > Kubernetes / Compute Resources / Cluster**: live CPU and memory of your cluster.

No domain? Use a port-forward instead: `kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80` and open http://localhost:3000.

```bash
helm list -n monitoring        # the release, its chart version and revision
```

**Official gihub repo for prometheus and grafana**
https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

### Lab 3: Create a Helm chart for a simple nginx app and deploy it in a cluster

#### Steps
1. Create the Chart

```bash
helm create myapp
```

This generates a folder structure:
```
myapp/                    # Root directory of the Helm chart
├── charts/               # Directory for dependencies (empty by default)
├── templates/            # Kubernetes resource templates
│   ├── _helpers.tpl      # Template helpers for labels and annotations
│   ├── deployment.yaml   # Kubernetes Deployment manifest template
│   ├── hpa.yaml          # HorizontalPodAutoscaler template (optional)
│   ├── ingress.yaml      # Ingress template (optional)
│   ├── service.yaml      # Service template
│   ├── serviceaccount.yaml # ServiceAccount template (optional)
│   ├── NOTES.txt         # Instructions after chart installation
│   ├── tests/            # Test templates (contains test-connection.yaml)
├── .helmignore           # Files to ignore when packaging the chart
├── Chart.yaml            # Metadata about the Helm chart (name, version, description)
├── values.yaml           # Default configuration values for the chart
├── README.md             # Documentation for the Helm chart
```
2. Modify the values.yaml

Edit myapp/values.yaml and add or modify the following parameters

```yaml
replicaCount: 1

image:
  repository: nginx
  tag: "1.27"          # pin a version, never "latest"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80
```

3. Modify templates/deployment.yaml

Open and go through the templates/deployment.yaml. You will get something like the following

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-deployment
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: myapp
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 80
```
4. Modify templates/service.yaml

Open and go through templates/service.yaml. You will get something like the following

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-service
spec:
  selector:
    app: {{ .Release.Name }}
  ports:
    - protocol: TCP
      port: {{ .Values.service.port }}
      targetPort: 80
  type: {{ .Values.service.type }}
```
5. Install the Chart
```bash
helm install my-release myapp
```
6. Verify the deployment:

```bash
kubectl get pods
kubectl get svc
```
7. Upgrade the Release

Modify values.yaml (e.g., change replicaCount to 3).

Run:
```bash
helm upgrade my-release myapp
kubectl get pods
kubectl get svc
```
You can also override a value from the command line, without editing the file:
```bash
helm upgrade my-release myapp --set replicaCount=2
helm history my-release      # one revision per install / upgrade / rollback
```

8. Rollback the Release

To roll back to a previous version:

```bash
helm rollback my-release 1
kubectl get pods
kubectl get svc
```

9. Uninstall the Release
```bash
helm uninstall my-release
kubectl get pods
kubectl get svc
```

## Cleanup

```bash
helm uninstall my-release --ignore-not-found
# the monitoring stack (also deletes the Grafana ALB; ExternalDNS removes the DNS record)
helm uninstall prometheus -n monitoring --ignore-not-found
kubectl delete ns monitoring --ignore-not-found
# the chart installs CRDs (Prometheus, ServiceMonitor...) that helm uninstall keeps. Remove them if you are done:
kubectl get crd -o name | grep monitoring.coreos.com | xargs -r kubectl delete
# If you added any helm repos for the practice, you can remove them with:
# helm repo remove <repo-name>
```
