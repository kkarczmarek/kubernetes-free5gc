#!/usr/bin/env bash
set -euo pipefail

# --- kolory / formatowanie ---
if [ -t 1 ]; then
  RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
  BLUE='\033[1;34m'; CYAN='\033[1;36m'; BOLD='\033[1m'; DIM='\033[2m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi
hr(){ printf "%s\n" "$(printf '%*s' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '─')"; }
title(){ hr; printf "%b%s%b\n" "$BOLD$CYAN" "$1" "$NC"; hr; }
info(){  printf "%b[i]%b %s\n" "$BLUE" "$NC" "$1"; }
ok(){    printf "%b✔ PASS%b %s\n" "$GREEN" "$NC" "$1"; }
warn(){  printf "%b! WARN%b %s\n" "$YELLOW" "$NC" "$1"; }
fail(){  printf "%b✖ FAIL%b %s\n%b%s%b\n" "$RED" "$NC" "$1" "$DIM" "${2:-}" "$NC"; }

# --- zawsze używaj MicroK8s kubectl ---
kubectl(){ command microk8s kubectl "$@"; }

# --- parametry ---
NS=admission-system
IMAGE="${IMAGE:-localhost:32000/admission-webhook:0.2.4}"
REPO_DIR="${REPO_DIR:-$HOME/kubernetes-free5gc}"

title "Sprawdzam węzły"
info "Czekam na min. 2 węzły Ready…"
for _ in $(seq 1 120); do
  ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
  [ "${ready}" -ge 2 ] && break || sleep 2
done
kubectl get nodes -o wide || true

title "Włączam/addony (idempotentnie)"
sudo git config --global --add safe.directory /snap/microk8s/current/addons/community/.git || true
sudo microk8s enable community
sudo microk8s enable registry
sudo microk8s enable multus
sudo microk8s enable cert-manager

title "Czekam na cert-manager"
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s

title "Namespace free5gc + PSA baseline"
kubectl create ns free5gc --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns free5gc pod-security.kubernetes.io/enforce=baseline --overwrite || true

title "Repo + gałąź z webhookami"
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone https://github.com/kkarczmarek/kubernetes-free5gc.git "$REPO_DIR"
fi
cd "$REPO_DIR"
git fetch origin feat/webhooks-advanced
git checkout -B feat/webhooks-advanced origin/feat/webhooks-advanced || git checkout feat/webhooks-advanced

title "Konfiguracja manifestów"
# Dopasuj DATA_CIDR do swojej sieci labowej
sed -i 's/value: "10\.100\.50\.0\/24"/value: "192.168.50.0\/24"/' k8s/30-webhook-deploy-svc.yaml || true

title "Build & push obrazu webhooka"
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get install -y docker.io
fi
sudo docker build -t "$IMAGE" -f admission-controller/Dockerfile admission-controller
sudo docker push "$IMAGE"

title "TLS dla webhooka"
kubectl apply -f k8s/20-certmanager-issuer.yaml
kubectl -n "$NS" wait certificate webhook-cert --for=condition=Ready --timeout=180s

title "Deployment webhooka"
sed -i "s|IMAGE_PLACEHOLDER|$IMAGE|g" k8s/30-webhook-deploy-svc.yaml
kubectl apply -f k8s/30-webhook-deploy-svc.yaml
kubectl -n "$NS" set image deploy/admission-webhook server="$IMAGE" || true
# twarde SC (distroless:nonroot ma user 'nonroot')
kubectl -n "$NS" patch deploy admission-webhook --type='strategic' -p '{
  "spec":{"template":{"spec":{"containers":[{"name":"server","securityContext":{
    "runAsNonRoot": true, "runAsUser": 65532, "runAsGroup": 65532, "allowPrivilegeEscalation": false
  }}]}}}}' || true
kubectl -n "$NS" rollout status deploy/admission-webhook --timeout=180s

title "Rejestracja webhooków"
kubectl apply -f k8s/40-mutatingwebhook.yaml
kubectl apply -f k8s/50-validatingwebhook.yaml

# --- funkcje testowe (nie przerywają skryptu przy błędach) ---
overall_rc=0
expect_success(){ # desc, cmd...
  local desc="$1"; shift
  set +e; local out; out="$("$@" 2>&1)"; local rc=$?; set -e
  if [ $rc -eq 0 ]; then ok "$desc"
  else overall_rc=1; fail "$desc" "$out"
  fi
}
expect_failure_contains(){ # desc, substring, cmd...
  local desc="$1" needle="$2"; shift 2
  set +e; local out; out="$("$@" 2>&1)"; local rc=$?; set -e
  if [ $rc -ne 0 ] && grep -qi -- "$needle" <<<"$out"; then ok "$desc"
  else overall_rc=1; fail "$desc" "$out"
  fi
}

title "TESTY — mutacje i walidacje"

# 1) Mutacja: brakujące labelki + SC
expect_success "Mutating: t-missing-labels — apply OK" \
  kubectl apply -f tests/01-deploy-missing-labels.yaml
set +e
labels="$(kubectl -n free5gc get deploy t-missing-labels -o jsonpath='{.spec.template.metadata.labels}')"
sc="$(kubectl -n free5gc get deploy t-missing-labels -o jsonpath='{.spec.template.spec.containers[0].securityContext}')"
set -e
if [[ "$labels" == *'"app.kubernetes.io/part-of":"free5gc"'* \
   && "$labels" == *'"project":"free5gc"'* \
   && "$sc" == *'"allowPrivilegeEscalation":false'* \
   && "$sc" == *'"drop":["ALL"]'* \
   && "$sc" == *'"RuntimeDefault"'* ]]; then
  ok "Mutating: t-missing-labels — dodano labelki i SC (drop ALL, seccomp RuntimeDefault)"
else
  overall_rc=1
  fail "Mutating: t-missing-labels — oczekiwane labelki/SC nie widoczne" "labels=$labels; sc=$sc"
fi

hr

# 2) Mutacja: domyślne requests/limits
expect_success "Mutating: t-no-resources — apply OK" \
  kubectl apply -f tests/02-deploy-no-resources.yaml
set +e
res="$(kubectl -n free5gc get deploy t-no-resources -o jsonpath='{.spec.template.spec.containers[0].resources}')"
set -e
if [[ "$res" == *'"cpu":"50m"'* \
   && "$res" == *'"memory":"128Mi"'* \
   && "$res" == *'"cpu":"500m"'* \
   && "$res" == *'"memory":"512Mi"'* ]]; then
  ok "Mutating: t-no-resources — wstrzyknięto requests/limits (50m/128Mi, 500m/512Mi)"
else
  overall_rc=1
  fail "Mutating: t-no-resources — brak oczekiwanych requests/limits" "resources=$res"
fi

hr

# 3) Walidacja: zakaz tagu ':latest'
kubectl delete -f tests/03-deploy-bad-image.yaml --ignore-not-found >/dev/null 2>&1 || true
expect_failure_contains "Validating: odrzucono obraz z tagiem ':latest'" "latest.*forbidden" \
  kubectl apply -f tests/03-deploy-bad-image.yaml

hr
info "Obrazy w podach webhooka:"
kubectl -n "$NS" get pods -o=jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.containers[0].image}{"\n"}{end}'

title "PODSUMOWANIE"
if [ $overall_rc -eq 0 ]; then
  printf "%b🎉 Wszystkie testy zaliczone.%b\n" "$GREEN" "$NC"
else
  printf "%b⚠️  Część testów nie przeszła — przewiń log wyżej po ✖ FAIL.%b\n" "$YELLOW" "$NC"
fi

echo
info "Podgląd mutacji (przykład):"
echo "  microk8s kubectl -n free5gc get deploy t-no-resources -o jsonpath='{.spec.template.spec.containers[0].resources}{\"\\n\"}'"
echo
info "Walidator hostNetwork (opcjonalnie, chwilowe podniesienie PSA do privileged):"
echo "  microk8s kubectl label ns free5gc pod-security.kubernetes.io/enforce=privileged --overwrite"
echo "  microk8s kubectl -n free5gc apply -f tests/04-deploy-hostnetwork.yaml"
echo "  microk8s kubectl label ns free5gc pod-security.kubernetes.io/enforce=baseline --overwrite"
