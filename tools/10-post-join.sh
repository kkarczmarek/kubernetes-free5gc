#!/usr/bin/env bash
set -euo pipefail

# Ten skrypt zakłada, że:
#  - microk8s jest już zainstalowany i skonfigurowany na controlplane
#  - użytkownik należy do grupy 'microk8s'
#  - klaster (controlplane + workernode) jest już połączony

if [[ "$EUID" -eq 0 ]]; then
  echo "[00] Ten skrypt nie powinien być uruchamiany jako root. Zaloguj się jako zwykły użytkownik (w grupie microk8s) i uruchom ./tools/10-post-join.sh." >&2
  exit 1
fi

ROOT_DIR="${ROOT_DIR:-$(pwd)}"
KUBECTL="${KUBECTL:-/snap/bin/microk8s.kubectl}"
WEBHOOK_IMG_DEFAULT="localhost:32000/admission-webhook:0.1.0"
WEBHOOK_IMG="${WEBHOOK_IMG:-$WEBHOOK_IMG_DEFAULT}"

echo "[09] Upewniam się, że kubeconfig dla kubectl/Helm jest dostępny…"
if [[ ! -f "$HOME/.kube/config" ]]; then
  mkdir -p "$HOME/.kube"
  # używamy sudo, bo microk8s config często wymaga uprawnień roota
  sudo microk8s config > "$HOME/.kube/config"
fi

echo "[10] Sprawdzam węzły…"
"$KUBECTL" get nodes -o wide

# ====== NAMESPACES PROJEKTU ======
echo "[11] Tworzę namespace 'admission-system' (dla webhooka)…"
"$KUBECTL" get ns admission-system >/dev/null 2>&1 || "$KUBECTL" create ns admission-system

echo "[12] (Opcjonalnie) Tworzę namespacy testowe…"
"$KUBECTL" get ns playground >/dev/null 2>&1 || "$KUBECTL" create ns playground
"$KUBECTL" label ns playground pod-security.kubernetes.io/enforce=restricted --overwrite || echo "namespace/playground not labeled"

"$KUBECTL" get ns free5gc >/dev/null 2>&1 || "$KUBECTL" create ns free5gc
"$KUBECTL" label ns free5gc pod-security.kubernetes.io/enforce=restricted --overwrite || echo "namespace/free5gc not labeled"

# ====== LOKALNY REGISTRY + OBRAZ WEBHOOKA (opcjonalne, ale zalecane) ======
echo "[15] (Opcjonalnie) Włączam lokalny registry MicroK8s i buduję obraz webhooka…"

if ! "$KUBECTL" -n container-registry get deploy registry >/dev/null 2>&1; then
  echo "[15] Włączam addon 'registry' w microk8s (jeśli jeszcze nie był włączony)…"
  microk8s enable registry || echo "[15] WARN: nie udało się włączyć registry microk8s (kontynuuję bez lokalnego registry)."
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[15] Instaluję docker.io (do zbudowania obrazu webhooka)…"
  sudo apt-get update -y
  sudo apt-get install -y docker.io
fi

if command -v docker >/dev/null 2>&1; then
  echo "[15] Buduję i wypycham obraz webhooka: $WEBHOOK_IMG…"
  sudo docker build -t "$WEBHOOK_IMG" "$ROOT_DIR/admission-controller" || echo "[15] WARN: build obrazu webhooka nie powiódł się."
  sudo docker push "$WEBHOOK_IMG" || echo "[15] WARN: push obrazu webhooka do registry nie powiódł się."
else
  echo "[15] WARN: Docker nadal nie jest dostępny, pomijam build/push obrazu webhooka."
fi

# ====== CERT-MANAGER (z Helm) ======
echo "[20] Instalacja cert-manager (CRD + controller)…"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.19.1 \
  --set crds.enabled=true

echo "[21] Czekam na gotowość cert-manager…"
"$KUBECTL" -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s || true
"$KUBECTL" -n cert-manager get pods -o wide

# ====== KYVERNO (z Helm) ======
echo "[30] Instalacja Kyverno…"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace

echo "[31] Czekam na gotowość Kyverno…"
"$KUBECTL" -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s || true
"$KUBECTL" -n kyverno get pods -o wide

# ====== ISSUER + CERT DLA WEBHOOKA ======
echo "[40] Wdrażam Issuer i Certificate (repo: k8s/20-certmanager-issuer.yaml, 25-certificate.yaml)…"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/20-certmanager-issuer.yaml"

# Zapewnij istnienie Issuera 'admission-selfsigned-issuer' używanego przez Certificate z 25-certificate.yaml
cat <<'EOF' | "$KUBECTL" apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: admission-selfsigned-issuer
  namespace: admission-system
spec:
  selfSigned: {}
EOF

"$KUBECTL" apply -f "$ROOT_DIR/k8s/25-certificate.yaml"

echo "[41] Wdrażam RBAC, Deployment i Service webhooka…"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/15-rbac-admission.yaml"
"$KUBECTL" apply -f "$ROOT_DIR/k8s/30-webhook-deploy-svc.yaml"

# Jeśli zbudowaliśmy lokalny obraz, spróbujmy go podstawić w deploymencie
if "$KUBECTL" -n admission-system get deploy admission-webhook >/dev/null 2>&1; then
  echo "[41] Ustawiam obraz webhooka na $WEBHOOK_IMG (jeśli dostępny)…"
  "$KUBECTL" -n admission-system set image deploy/admission-webhook webhook="$WEBHOOK_IMG" || true
fi

# Patch dla runAsUser, aby uniknąć błędu 'runAsNonRoot' z distroless:nonroot
echo "[41] Patchuję securityContext kontenera webhook (runAsUser=65532)…"
"$KUBECTL" -n admission-system patch deploy admission-webhook \
  -p '{
    "spec": {
      "template": {
        "spec": {
          "containers": [
            {
              "name": "webhook",
              "securityContext": {
                "runAsNonRoot": true,
                "runAsUser": 65532,
                "allowPrivilegeEscalation": false,
                "capabilities": {"drop":["ALL"]},
                "seccompProfile": {"type":"RuntimeDefault"}
              }
            }
          ]
        }
      }
    }
  }' || true

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
