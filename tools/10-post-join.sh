#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(pwd)}"

echo "[10] Sprawdzam węzły…"
kubectl get nodes -o wide

# ====== NAMESPACES PROJEKTU (jeśli nie masz własnego pliku 00-namespaces.yaml) ======
echo "[11] Tworzę namespace 'admission-system' (dla webhooka)…"
kubectl get ns admission-system >/dev/null 2>&1 || kubectl create ns admission-system

echo "[12] (Opcjonalnie) Tworzę namespacy testowe…"
kubectl get ns playground >/dev/null 2>&1 || kubectl create ns playground
kubectl label ns playground pod-security.kubernetes.io/enforce=restricted --overwrite

kubectl get ns free5gc >/dev/null 2>&1 || kubectl create ns free5gc
kubectl label ns free5gc pod-security.kubernetes.io/enforce=restricted --overwrite

# ====== CERT-MANAGER (z Helm) ======
echo "[20] Instalacja cert-manager (CRD + controller)…"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.install=true

echo "[21] Czekam na gotowość cert-manager…"
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s || true
kubectl -n cert-manager get pods -o wide

# ====== KYVERNO (z Helm) ======
echo "[30] Instalacja Kyverno…"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace

echo "[31] Czekam na gotowość Kyverno…"
kubectl -n kyverno rollout status deploy/kyverno --timeout=180s || true
kubectl -n kyverno get pods -o wide

# ====== ISSUER + CERT DLA WEBHOOKA ======
echo "[40] Wdrażam Issuer i Certificate (repo: k8s/20-certmanager-issuer.yaml, 25-certificate.yaml)…"
kubectl apply -f "$ROOT_DIR/k8s/20-certmanager-issuer.yaml"
kubectl apply -f "$ROOT_DIR/k8s/25-certificate.yaml"

echo "[41] Wdrażam RBAC, Deployment i Service webhooka…"
kubectl apply -f "$ROOT_DIR/k8s/15-rbac-admission.yaml"
kubectl apply -f "$ROOT_DIR/k8s/30-webhook-deploy-svc.yaml"

echo "[42] Wdrażam konfiguracje webhooków (CA zostanie wstrzyknięte przez cert-manager)…"
kubectl apply -f "$ROOT_DIR/k8s/40-mutatingwebhook.yaml"
kubectl apply -f "$ROOT_DIR/k8s/50-validatingwebhook.yaml"

echo "[43] Czekam na gotowość webhooka…"
kubectl -n admission-system rollout status deploy/admission-webhook --timeout=180s || true
kubectl -n admission-system get pods -o wide

# ====== POLITYKI SIECIOWE I PSA ======
echo "[50] Wdrażam polityki…"
kubectl apply -f "$ROOT_DIR/policies/pod-security-namespace-labels.yaml"
kubectl apply -f "$ROOT_DIR/policies/networkpolicy-default-deny.yaml"
kubectl apply -f "$ROOT_DIR/policies/networkpolicy-allow-controlplane.yaml"
kubectl apply -f "$ROOT_DIR/policies/networkpolicy-admission-allow-apiserver.yaml"

echo "[51] (Opcjonalnie) verify-images Kyverno -> najpierw przygotuj secret z cosign.pub!"
echo "     Gdy secret będzie gotowy: kubectl apply -f $ROOT_DIR/policies/kyverno-verify-images.yaml"

echo "[DONE] Post-join zakończony. Teraz możesz uruchomić testy z katalogu tests/."
