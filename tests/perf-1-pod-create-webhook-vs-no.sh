#!/usr/bin/env bash
set -euo pipefail

ITERATIONS="${1:-5}"   # domyślnie 5 powtórzeń
KCTL="microk8s kubectl"

NS_BASE="perf-no-webhook"
NS_WH="perf-webhook"

echo "==[PERF-1] Pomiar czasu tworzenia Poda: bez webhooka vs z webhookiem=="
echo "  ITERATIONS = ${ITERATIONS}"

echo
echo "==[PERF-1] Przygotowanie namespace'ów=="
${KCTL} create ns "${NS_BASE}" >/dev/null 2>&1 || true
${KCTL} create ns "${NS_WH}" >/dev/null 2>&1 || true

echo "  -> labeluję ${NS_WH} admission.kkarczmarek.dev/enabled=true"
${KCTL} label ns "${NS_WH}" admission.kkarczmarek.dev/enabled="true" --overwrite

measure_ns() {
  local ns="$1"
  local label="$2"

  echo
  echo "==[PERF-1] Scenariusz: ${label} (namespace=${ns})=="

  local total=0
  local i
  for i in $(seq 1 "${ITERATIONS}"); do
    local pod="perf-${label}-${i}-$(date +%s)"
    echo
    echo "  -> [${label} #${i}] Tworzę Poda ${pod}"

    local start_ms
    start_ms=$(date +%s%3N)

    cat <<PODEOF | ${KCTL} -n "${ns}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels:
    app: perf-test
    app.kubernetes.io/part-of: perf-test
    project: perf-test
spec:
  containers:
    - name: main
      image: docker.io/library/nginx:1.27
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi
PODEOF

    ${KCTL} -n "${ns}" wait pod "${pod}" --for=condition=Ready --timeout=180s >/dev/null

    local end_ms
    end_ms=$(date +%s%3N)

    local diff=$((end_ms - start_ms))
    echo "     czas tworzenia Poda ${pod}: ${diff} ms"

    total=$((total + diff))

    # sprzątanie Poda po pomiarze
    ${KCTL} -n "${ns}" delete pod "${pod}" --ignore-not-found >/dev/null
  done

  local avg=$((total / ITERATIONS))
  echo
  echo "==[PERF-1] Średni czas (${label}, ns=${ns}) z ${ITERATIONS} prób: ${avg} ms=="

  # zapisujemy do globalnych zmiennych przez echo, żeby móc użyć w podsumowaniu
  if [ "${label}" = "baseline" ]; then
    echo "${avg}" > /tmp/perf-baseline-ms
  else
    echo "${avg}" > /tmp/perf-webhook-ms
  fi
}

measure_ns "${NS_BASE}" "baseline"
measure_ns "${NS_WH}"   "webhook"

echo
BASE_MS=$(cat /tmp/perf-baseline-ms)
WH_MS=$(cat /tmp/perf-webhook-ms)
DELTA=$((WH_MS - BASE_MS))

echo "==[PERF-1] PODSUMOWANIE =="
echo "  Średni czas bez webhooka  : ${BASE_MS} ms"
echo "  Średni czas z webhookiem  : ${WH_MS} ms"
echo "  Różnica (webhook - base)  : ${DELTA} ms"
echo
echo "==[PERF-1] KONIEC TESTU=="
