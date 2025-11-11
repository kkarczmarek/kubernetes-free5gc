#!/usr/bin/env bash
set -euo pipefail

# ---------- kolory i format ----------
bold() { printf "\033[1m%s\033[0m" "$*"; }
green() { printf "\033[32m%s\033[0m" "$*"; }
yellow(){ printf "\033[33m%s\033[0m" "$*"; }
red()   { printf "\033[31m%s\033[0m" "$*"; }
cyan()  { printf "\033[36m%s\033[0m" "$*"; }
sep()   { printf "\n\033[90m%s\033[0m\n" "────────────────────────────────────────────────────────"; }
title() { sep; echo -e "$(bold "$1")\n"; }
info()  { echo -e "[i] $*"; }
ok()    { echo -e "$(green "✔") $*"; }
warn()  { echo -e "$(yellow "⚠") $*"; }
err()   { echo -e "$(red "✖") $*"; }

# ---------- konfiguracja ----------
NS=admission-system
IMAGE="${IMAGE:-localhost:32000/admission-webhook:0.2.4}"
REPO_DIR="${REPO_DIR:-$HOME/kubernetes-free5gc}"

# Wybór MicroK8s i kubectl z auto-fallbackiem na sudo
MK8S="${MK8S:-microk8s}"
if ! $MK8S status >/dev/null 2>&1; then
  MK8S="sudo microk8s"
fi
KCTL="${KCTL:-$MK8S kubectl}"
export MK8S KCTL

# Upewnij się, że ~/.kube istnieje (nie szkodzi MicroK8s, a eliminuje ostrzeżenia)
mkdir -p "$HOME/.kube" 2>/dev/null || true

# ---------- 1) Sprawdzenie węzłów ----------
title "Sprawdzam węzły"
info "Czekam na min. 2 węzły Ready…"
for _ in $(seq 1 120); do
  ready="$($KCTL get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
  [ "${ready}" -ge 2 ] && break || sleep 2
done
$KCTL get nodes -o wide || true

# ---------- 2) Addony (idempotentnie) ----------
title "Włączam addony (idempotentnie)"
$MK8S enable community || true
$MK8S enable registry || true

# Hostpath storage (nie zawsze włączony domyślnie)
$MK8S enable hostpath-storage || true

# Multus z lekkim retry (czasem trafia się „Text file busy”)
info "Włączam Multus…"
for try in $(seq 1 5); do
  if $MK8S enable multus; then ok "Multus włączony"; break; fi
  warn "multus enable nie powiódł się (próba $try) – retry za 5s…"
  sleep 5
done
# Niech daemonset wystartuje, ale nie blokujemy na siłę
$KCTL -n kube-system rollout status ds/kube-multus-ds --timeout=180s || true

# cert-manager (jeśli jeszcze nie jest)
$MK8S enable cert-manager || true

title "Czekam na cert-manager"
$KCTL -n cert-manager rollout status deploy/cert-manager --timeout=300s
$KCTL -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
$KCTL -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s
ok "cert-manager gotowy"

# ---------- 3) Namespace free5gc + PSA ----------
title "Namespace free5gc + PSA baseline"
$KCTL create ns free5gc --dry-run=client -o yaml | $KCTL apply -f -
$KCTL label ns free5gc pod-security.kubernetes.io/enforce=baseline --overwrite
ok "free5gc gotowy"

# ---------- 4) Repo (bezpieczny checkout – pomija jeśli masz lokalne zmiany) ----------
title "Repo + gałąź z webhookami"
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone https://github.com/kkarczmarek/kubernetes-free5gc.git "$REPO_DIR"
fi
cd "$REPO_DIR"

if git diff --quiet && git diff --cached --quiet; then
  git fetch origin feat/webhooks-advanced || true
  git checkout -B feat/webhooks-advanced origin/feat/webhooks-advanced || git checkout feat/webhooks-advanced || true
  ok "Gałąź feat/webhooks-advanced"
else
  warn "Wykryto lokalne zmiany – pomijam fetch/checkout i zostawiam bieżącą gałąź."
fi

# Podmień DATA_CIDR w manifeście jeśli trzeba (Twoja sieć)
sed -i 's/value: "10\.100\.50\.0\/24"/value: "192.168.50.0\/24"/' k8s/30-webhook-deploy-svc.yaml || true

# ---------- 5) Build & push obrazu ----------
title "Buduję i wypycham obraz webhooka"
if ! command -v docker >/dev/null 2>&1; then
  info "Instaluję docker.io"
  sudo apt-get update -y
  sudo apt-get install -y docker.io
fi
sudo docker build -t "$IMAGE" -f admission-controller/Dockerfile admission-controller
sudo docker push "$IMAGE"
ok "Obraz: $IMAGE"

# ---------- 6) TLS cert + wdrożenie webhooka ----------
title "Cert i wdrożenie webhooka"
$KCTL apply -f k8s/20-certmanager-issuer.yaml
$KCTL -n "$NS" wait certificate webhook-cert --for=condition=Ready --timeout=300s

# wstrzyknięcie obrazu do manifestu i apply
sed -i "s|IMAGE_PLACEHOLDER|$IMAGE|g" k8s/30-webhook-deploy-svc.yaml
$KCTL apply -f k8s/30-webhook-deploy-svc.yaml

# twardy securityContext, żeby uniknąć błędów z nonroot (distroless:nonroot)
$KCTL -n "$NS" patch deploy admission-webhook --type='strategic' -p '{
  "spec":{"template":{"spec":{"containers":[{"name":"server","securityContext":{
    "runAsNonRoot": true, "runAsUser": 65532, "runAsGroup": 65532, "allowPrivilegeEscalation": false
  }}]}}}}' || true

# dopilnuj, że faktycznie używamy wybranego taga
$KCTL -n "$NS" set image deploy/admission-webhook server="$IMAGE" --record=false || true

$KCTL -n "$NS" rollout status deploy/admission-webhook --timeout=300s
ok "Webhook wystartował"

# ---------- 7) Rejestracja webhooków ----------
title "Rejestracja podWebHooków"
$KCTL apply -f k8s/40-mutatingwebhook.yaml
$KCTL apply -f k8s/50-validatingwebhook.yaml
ok "Mutating + Validating zarejestrowane"

# ---------- Czekanie na cainjector (CA w caBundle) ----------
title "Czekam na wstrzyknięcie CA do webhooków (cainjector)"
for cfg in admission-mutating-webhook admission-validating-webhook; do
  for i in $(seq 1 60); do
    size="$($KCTL get $( [[ $cfg == admission-mutating-webhook ]] && echo mutatingwebhookconfiguration || echo validatingwebhookconfiguration ) \
      $cfg -o jsonpath='{.webhooks[*].clientConfig.caBundle}' 2>/dev/null | wc -c | tr -d ' ')"
    if [ "${size:-0}" -gt 0 ]; then
      ok "$cfg ma CA (caBundle size=${size})"
      break
    fi
    sleep 2
  done
done

# ---------- 8) Smoke-testy ----------
title "Smoke-testy"
set +e
out1="$($KCTL apply -f tests/01-deploy-missing-labels.yaml 2>&1)"; rc1=$?
out2="$($KCTL apply -f tests/02-deploy-no-resources.yaml 2>&1)"; rc2=$?
out3="$($KCTL apply -f tests/03-deploy-bad-image.yaml 2>&1)"; rc3=$?
set -e

echo
sep
echo "$(bold "01-deploy-missing-labels.yaml")"
[ $rc1 -eq 0 ] && ok "Utworzony – powinien zostać ZMUTOWANY (dopisywane label/SC)" || err "Błąd: $out1"
sep
echo "$(bold "02-deploy-no-resources.yaml")"
[ $rc2 -eq 0 ] && ok "Utworzony – powinien zostać ZMUTOWANY (dopisywane requests/limits)" || err "Błąd: $out2"
sep
echo "$(bold "03-deploy-bad-image.yaml") (oczekiwany DENY za ':latest')"
if [ $rc3 -ne 0 ]; then
  if echo "$out3" | grep -qi "image tag ':latest' is forbidden"; then
    ok "Odrzucony (zgodnie z polityką — zakaz :latest)"
  else
    warn "Odrzucony, ale komunikat inny:\n$out3"
  fi
else
  err "Nie został odrzucony, a powinien! Output:\n$out3"
fi
sep

# Podgląd efektu mutacji:
title "Podgląd mutacji (t-no-resources)"
$KCTL -n free5gc get deploy t-no-resources -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}' || true

echo
info "Gotowe. Jeśli chcesz chwilowo wymusić test walidatora hostNetwork (nad PSA):"
echo "  $KCTL label ns free5gc pod-security.kubernetes.io/enforce=privileged --overwrite"
echo "  $KCTL -n free5gc apply -f tests/04-deploy-hostnetwork.yaml"
echo "  $KCTL label ns free5gc pod-security.kubernetes.io/enforce=baseline --overwrite"
