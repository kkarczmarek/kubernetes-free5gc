#!/usr/bin/env bash
set -euo pipefail

# Używamy zawsze microk8s kubectl
KUBECTL=(microk8s kubectl)

ITERATIONS="${1:-5}"
REPLICAS="${2:-10}"

BASE_NS="perf-scale-no-webhook"   # namespace BEZ webhooka
WEBHOOK_NS="free5gc"              # namespace Z webhookiem (tam działa admission webhook)
DEPLOY_NAME="perf-scale"

echo "==[PERF-2] Skalowanie Deploymentu: bez webhooka vs z webhookiem (w free5gc) =="
echo "  ITERATIONS = ${ITERATIONS}, REPLICAS = ${REPLICAS}"
echo

echo "==[PERF-2] Przygotowanie namespace'ów i czyszczenie starych zasobów =="

# Namespace baseline (bez webhooka) – jeśli nie istnieje, utwórz
if ! "${KUBECTL[@]}" get namespace "${BASE_NS}" >/dev/null 2>&1; then
  "${KUBECTL[@]}" create namespace "${BASE_NS}"
fi

# free5gc zakładamy, że istnieje (nie dotykamy go poza naszymi zasobami perf-scale)

# Czyścimy stare Deploymenty + Pody perf-scale w obu namespace'ach
for NS in "${BASE_NS}" "${WEBHOOK_NS}"; do
  "${KUBECTL[@]}" -n "${NS}" delete deploy "${DEPLOY_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  "${KUBECTL[@]}" -n "${NS}" delete pod -l app=perf-scale --ignore-not-found >/dev/null 2>&1 || true
done

echo "  -> namespaces gotowe: ${BASE_NS} (bez webhooka), ${WEBHOOK_NS} (z webhookiem)"
echo

# ---------------- BASELINE: namespace bez webhooka ----------------

echo "==[PERF-2] Scenariusz: baseline-no-webhook (namespace=${BASE_NS}) =="

# Deployment w namespace bez webhooka – prosty busybox, bez resources/securityContext
cat <<EOF_DEP_NO_WEBHOOK | "${KUBECTL[@]}" -n "${BASE_NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
spec:
  replicas: 0
  selector:
    matchLabels:
      app: perf-scale
  template:
    metadata:
      labels:
        app: perf-scale
        project: perf-test
        app.kubernetes.io/part-of: perf-test
    spec:
      containers:
      - name: main
        image: docker.io/library/busybox:1.36
        command: ["sh","-c","sleep 3600"]
        # BEZ resources / securityContext – nic nie wstrzykujemy
EOF_DEP_NO_WEBHOOK

sum_base=0

for i in $(seq 1 "${ITERATIONS}"); do
  echo
  echo "  -> [baseline-no-webhook #${i}] skaluję ${DEPLOY_NAME} do ${REPLICAS} replik"

  # skaluj do 0, poczekaj aż znikną Pody z app=perf-scale
  "${KUBECTL[@]}" -n "${BASE_NS}" scale deploy/"${DEPLOY_NAME}" --replicas=0 >/dev/null
  "${KUBECTL[@]}" -n "${BASE_NS}" wait --for=delete pod -l app=perf-scale --timeout=120s >/dev/null 2>&1 || true

  start_ms=$(date +%s%3N)
  "${KUBECTL[@]}" -n "${BASE_NS}" scale deploy/"${DEPLOY_NAME}" --replicas="${REPLICAS}" >/dev/null
  "${KUBECTL[@]}" -n "${BASE_NS}" rollout status deploy/"${DEPLOY_NAME}" --timeout=180s >/dev/null
  end_ms=$(date +%s%3N)

  dur=$((end_ms - start_ms))
  echo "     czas skalowania (0 -> ${REPLICAS}) w ns=${BASE_NS}: ${dur} ms"
  sum_base=$((sum_base + dur))
done

avg_base=$((sum_base / ITERATIONS))

echo
echo "==[PERF-2] Średni czas (baseline-no-webhook, ns=${BASE_NS}) z ${ITERATIONS} prób: ${avg_base} ms =="
echo

# ---------------- WEBHOOK: namespace free5gc ----------------

echo "==[PERF-2] Scenariusz: webhook-enabled (namespace=${WEBHOOK_NS}) =="

# Deployment w namespace free5gc – tutaj zadziała mutating+validating webhook
cat <<EOF_DEP_WEBHOOK | "${KUBECTL[@]}" -n "${WEBHOOK_NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
spec:
  replicas: 0
  selector:
    matchLabels:
      app: perf-scale
  template:
    metadata:
      labels:
        app: perf-scale
        project: free5gc
        app.kubernetes.io/part-of: free5gc
    spec:
      containers:
      - name: main
        image: docker.io/library/busybox:1.36
        command: ["sh","-c","sleep 3600"]
        # BEZ resources / securityContext – te pola wstrzyknie webhook
EOF_DEP_WEBHOOK

sum_webhook=0

for i in $(seq 1 "${ITERATIONS}"); do
  echo
  echo "  -> [webhook-enabled #${i}] skaluję ${DEPLOY_NAME} do ${REPLICAS} replik"

  "${KUBECTL[@]}" -n "${WEBHOOK_NS}" scale deploy/"${DEPLOY_NAME}" --replicas=0 >/dev/null
  "${KUBECTL[@]}" -n "${WEBHOOK_NS}" wait --for=delete pod -l app=perf-scale --timeout=180s >/dev/null 2>&1 || true

  start_ms=$(date +%s%3N)
  "${KUBECTL[@]}" -n "${WEBHOOK_NS}" scale deploy/"${DEPLOY_NAME}" --replicas="${REPLICAS}" >/dev/null
  "${KUBECTL[@]}" -n "${WEBHOOK_NS}" rollout status deploy/"${DEPLOY_NAME}" --timeout=240s >/dev/null
  end_ms=$(date +%s%3N)

  dur=$((end_ms - start_ms))
  echo "     czas skalowania (0 -> ${REPLICAS}) w ns=${WEBHOOK_NS}: ${dur} ms"
  sum_webhook=$((sum_webhook + dur))
done

avg_webhook=$((sum_webhook / ITERATIONS))

echo
echo "==[PERF-2] Średni czas (webhook-enabled, ns=${WEBHOOK_NS}) z ${ITERATIONS} prób: ${avg_webhook} ms =="
echo

echo "==[PERF-2] PODSUMOWANIE =="
echo "  Średni czas bez webhooka  : ${avg_base} ms"
echo "  Średni czas z webhookiem  : ${avg_webhook} ms"
echo "  Różnica (webhook - base)  : $((avg_webhook - avg_base)) ms"
echo

echo "==[PERF-2] Przykładowy Pod w ${WEBHOOK_NS} (mutacja przez webhook) =="

POD_WEBHOOK=$("${KUBECTL[@]}" -n "${WEBHOOK_NS}" get pod -l app=perf-scale -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "${POD_WEBHOOK}" ]]; then
  echo "  -> Pod: ${POD_WEBHOOK}"
  echo "  -> resources kontenera:"
  "${KUBECTL[@]}" -n "${WEBHOOK_NS}" get pod "${POD_WEBHOOK}" \
    -o jsonpath='{.spec.containers[0].resources}'; echo
  echo "  -> securityContext kontenera:"
  "${KUBECTL[@]}" -n "${WEBHOOK_NS}" get pod "${POD_WEBHOOK}" \
    -o jsonpath='{.spec.containers[0].securityContext}'; echo
else
  echo "  (brak Podów app=perf-scale w ${WEBHOOK_NS})"
fi

echo
echo "==[PERF-2] KONIEC TESTU =="
