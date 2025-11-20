#!/usr/bin/env bash
KUBECTL="/snap/bin/microk8s.kubectl"
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(pwd)}"

echo "[10] Sprawdzam węzły…"
"$KUBECTL" get nodes -o wide

# ====== NAMESPACES PROJEKTU (jeśli nie masz własnego pliku 00-namespaces.yaml) ======
echo "[11] Tworzę namespace 'admission-system' (dla webhooka)…"
"$KUBECTL" get ns admission-system >/dev/null 2>&1 || "$KUBECTL" create ns admission-system

echo "[12] (Opcjonalnie) Tworzę namespacy testowe…"
"$KUBECTL" get ns playground >/dev/null 2>&1 || "$KUBECTL" create ns playground
"$KUBECTL" label ns playground pod-security.kubernetes.io/enforce=restricted --overwrite

"$KUBECTL" get ns free5gc >/dev/null 2>&1 || "$KUBECTL" create ns free5gc
"$KUBECTL" label ns free5gc pod-security.kubernetes.io/enforce=restricted --overwrite

# ====== CERT-MANAGER (z Helm) ======
echo "[20] Instalacja cert-manager (CRD + controller)…"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.install=true

echo "[21] Czekam na gotowość cert-manager…"
"$KUBECTL" -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s || true
"$KUBECTL" -n cert-manager get pods -o wide

# ====== KYVERNO (z Helm) ======
echo "[30] Instalacja Kyverno…"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace

echo "[31] Czekam na gotowość Kyverno…"
"$KUBECTL" -n kyverno rollout status deploy/kyverno --timeout=180s || true
"$KUBECTL" -n kyverno get pods -o wide

# ====== ISSUER + CERT DLA WEBHOOKA ======
echo "[40] Wdrażam Issuer i Certificate (repo: k8s/20-certmanager-issuer.yaml, 25-certificate.yaml)…"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/20-certmanager-issuer.yaml"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/25-certificate.yaml"

echo "[41] Wdrażam RBAC, Deployment i Service webhooka…"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/15-rbac-admission.yaml"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/30-webhook-deploy-svc.yaml"

echo "[42] Wdrażam konfiguracje webhooków (CA zostanie wstrzyknięte przez cert-manager)…"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/40-mutatingwebhook.yaml"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/50-validatingwebhook.yaml"

echo "[43] Czekam na gotowość webhooka…"
"$KUBECTL" -n admission-system rollout status deploy/admission-webhook --timeout=180s || true
"$KUBECTL" -n admission-system get pods -o wide

# ====== POLITYKI SIECIOWE I PSA ======
echo "[50] Wdrażam polityki…"
"$KUBECTL" apply -f "$ROOT_DIR/policies/pod-security-namespace-labels.yaml"
"$KUBECTL" apply -f "$ROOT_DIR/policies/networkpolicy-default-deny.yaml"
"$KUBECTL" apply -f "$ROOT_DIR/policies/networkpolicy-allow-controlplane.yaml"
"$KUBECTL" apply -f "$ROOT_DIR/policies/networkpolicy-admission-allow-apiserver.yaml"

echo "[51] (Opcjonalnie) verify-images Kyverno -> najpierw przygotuj secret z cosign.pub!"
echo "     Gdy secret będzie gotowy: kubectl apply -f $ROOT_DIR/policies/kyverno-verify-images.yaml"

echo "[DONE] Post-join zakończony. Teraz możesz uruchomić testy z katalogu tests/."
