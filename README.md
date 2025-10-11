# Free5GC on Kubernetes with Admission Webhooks

This repo installs free5GC via Helm and enforces consistency/security using custom Admission Webhooks (mutating + validating).

## Prereqs
- Kubernetes cluster (kubeadm on GCP VMs is fine)
- kubectl, Helm 3
- cert-manager installed:
  ```bash
  helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set installCRDs=true
  ```
- Container registry for your webhook image (e.g., GHCR)

## Quickstart
```bash
# 1) Namespaces, RBAC, certs
kubectl apply -f k8s/00-namespaces.yaml
kubectl apply -f k8s/10-rbac-free5gc-installer.yaml
kubectl apply -f k8s/20-certmanager-issuer.yaml

# 2) Build & push webhook image (edit USERNAME)
make docker-build docker-push IMG=ghcr.io/kkarczmarek/admission-webhook:0.1.0

# 3) Deploy webhook server + webhook configs
make deploy-webhooks IMG=ghcr.io/kkarczmarek/admission-webhook:0.1.0

# 4) Run tests (expect some rejects)
make tests

# 5) Install free5GC with Helm (pick one of values files)
make install-free5gc VALUES=helm-values/free5gc/values-upf-gcp.yaml RELEASE=free5gc NAMESPACE=5g-core
```
## What the webhooks enforce
- Mutating: injects missing labels `app.kubernetes.io/part-of=free5gc` and `project=free5gc`.
- Validating: requires namespace `5g-core`, those two labels, resources set on containers, and basic security checks.

## Notes
- Adjust image whitelist / rules in `admission-controller/cmd/server/main.go`.
- UPF scheduling: label your UPF node `upf=enabled` and use `helm-values/free5gc/values-upf-gcp.yaml`.
