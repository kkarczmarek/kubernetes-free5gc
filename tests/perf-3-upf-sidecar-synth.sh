#!/usr/bin/env bash
set -euo pipefail

KUBECTL=(microk8s kubectl)

ITERATIONS="${1:-5}"
REPLICAS="${2:-10}"
NS="perf-upf"
DEPLOY="upf-perf"

log()  { echo "==[PERF-3-SYNTH] $*"; }
log2() { echo "  $*"; }

ns_prepare() {
  log "Krok 1: namespace + Deployment bazowy =="
  # namespace może już istnieć albo nie
  if ! "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
    log2 "-> tworzę namespace ${NS}"
    "${KUBECTL[@]}" create ns "$NS"
  fi

  log2 "-> labeluję namespace ${NS} admission.kkarczmarek.dev/enabled=true, allow-netadmin=true"
  "${KUBECTL[@]}" label ns "$NS" \
    admission.kkarczmarek.dev/enabled=true \
    allow-netadmin=true \
    --overwrite

  log2 "-> apply Deployment ${DEPLOY} w ${NS}"
  cat <<EOD | "${KUBECTL[@]}" -n "$NS" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
spec:
  replicas: 0
  selector:
    matchLabels:
      app: upf-perf
  template:
    metadata:
      labels:
        app: upf-perf
        project: perf-upf
        nf: upf
        app.kubernetes.io/part-of: perf-upf
    spec:
      containers:
      - name: main
        image: docker.io/library/busybox:1.36
        command: ["sh","-c","sleep 3600"]
EOD
}

# czekamy aż nie będzie żadnych Podów z app=upf-perf
wait_zero_pods() {
  echo "    -> oczekuję aż wszystkie Pody app=upf-perf znikną (replicas=0)..." >&2
  local first=1

  for _ in $(seq 1 60); do
    local pods
    pods=$("${KUBECTL[@]}" -n "$NS" get pods -l app=upf-perf --no-headers 2>/dev/null | wc -l || true)

    if [ "$pods" -eq 0 ]; then
      echo "    -> brak Podów app=upf-perf w ns=${NS}" >&2
      return 0
    fi

    # tylko pierwszy raz pokazujemy ile jeszcze jest
    if [ "$first" -eq 1 ]; then
      echo "    -> po skalowaniu nadal ${pods} Pod(ów) app=upf-perf, czekam..." >&2
      first=0
    fi

    sleep 1
  done

  echo "    !! timeout przy oczekiwaniu na 0 Podów app=upf-perf w ns=${NS}" >&2
  return 1
}

# pojedynczy pomiar: ustaw ann, scale->0, potem mierzymy czas 0->REPLICAS
measure_scale_once() {
  local mode="$1"   # "false" albo "true"

  echo "    -> ustawiam 5g.kkarczmarek.dev/tcpdump-enabled=${mode} na ${DEPLOY}" >&2
  "${KUBECTL[@]}" -n "$NS" patch deploy "$DEPLOY" \
    --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"5g.kkarczmarek.dev/tcpdump-enabled\":\"${mode}\"}}}}}" \
    >/dev/null

  echo "    -> skaluję ${DEPLOY} do 0 replik" >&2
  "${KUBECTL[@]}" -n "$NS" scale deploy "$DEPLOY" --replicas=0 >/dev/null
  wait_zero_pods || true

  local start end
  start=$(date +%s%3N)
  echo "    -> skaluję ${DEPLOY} do ${REPLICAS} replik" >&2
  "${KUBECTL[@]}" -n "$NS" scale deploy "$DEPLOY" --replicas="${REPLICAS}" >/dev/null
  "${KUBECTL[@]}" -n "$NS" rollout status deploy "$DEPLOY" --timeout=120s >/dev/null
  end=$(date +%s%3N)

  local dur_ms=$((end - start))
  echo "$dur_ms"
}

### MAIN ###

log "Czas startu 'syntetycznego UPF' (busybox z nf=upf): bez sidecara tcpdump vs z sidecarem =="
log "  ITERATIONS = ${ITERATIONS}, REPLICAS = ${REPLICAS}"
echo

ns_prepare
echo

# 1) Scenariusz: bez sidecara
log "Scenariusz: bez-sidecara (tcpdump-enabled=false) =="
base_sum=0
for i in $(seq 1 "$ITERATIONS"); do
  log2 "    [bez-sidecara #${i}] pomiar skalowania"
  dur_ms=$(measure_scale_once "false")
  log2 "       czas skalowania (0 -> ${REPLICAS}) w ns=${NS}: ${dur_ms} ms"
  base_sum=$((base_sum + dur_ms))
done
base_avg=$((base_sum / ITERATIONS))
echo

# 2) Scenariusz: z sidecarem
log "Scenariusz: z-sidecarem (tcpdump-enabled=true) =="
with_sum=0
for i in $(seq 1 "$ITERATIONS"); do
  log2 "    [z-sidecarem #${i}] pomiar skalowania"
  dur_ms=$(measure_scale_once "true")
  log2 "       czas skalowania (0 -> ${REPLICAS}) w ns=${NS}: ${dur_ms} ms"
  with_sum=$((with_sum + dur_ms))
done
with_avg=$((with_sum / ITERATIONS))
echo

# PODSUMOWANIE
log "PODSUMOWANIE =="
log2 "Średni czas bez sidecara : ${base_avg} ms"
log2 "Średni czas z sidecarem  : ${with_avg} ms"
diff=$((with_avg - base_avg))
log2 "Różnica (with - base)    : ${diff} ms"
echo

# kontrolny Pod z sidecarem
log "Kontrola końcowa przykładowego Poda =="
pod=$("${KUBECTL[@]}" -n "$NS" get pods -l app=upf-perf -o jsonpath='{.items[0].metadata.name}')
log2 "  -> Pod: ${pod}"
log2 "  -> Kontenery w Podzie:"
"${KUBECTL[@]}" -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[*].name}'; echo
log2 "  -> resources[0]:"
"${KUBECTL[@]}" -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[0].resources}'; echo

log "KONIEC TESTU =="
