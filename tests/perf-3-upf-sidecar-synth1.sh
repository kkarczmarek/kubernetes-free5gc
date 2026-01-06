#!/usr/bin/env bash
set -euo pipefail

# Używamy microk8s kubectl
KUBECTL=(microk8s kubectl)

NS="perf-upf-synth"
DEPLOY_NO="upf-perf-no"
DEPLOY_YES="upf-perf-yes"

ITERATIONS="${1:-5}"
REPLICAS="${2:-10}"

log() {
  # logi idą na STDERR, żeby nie mieszać się z liczbami zwracanymi echo
  echo "$@" >&2
}

now_ms() {
  date +%s%3N
}

ensure_ns() {
  if ! "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
    log "  -> tworzę namespace ${NS} (bez labeli admission.*, webhook wyłączony)"
    "${KUBECTL[@]}" create ns "$NS"
  fi
}

wait_pods_gone() {
  local label="$1"
  local tries=30
  while (( tries > 0 )); do
    local count
    count=$("${KUBECTL[@]}" -n "$NS" get pods -l "$label" --no-headers 2>/dev/null | wc -l || true)
    if [[ "$count" -eq 0 ]]; then
      return 0
    fi
    sleep 1
    ((tries--))
  done
  return 1
}

wait_pods_ready() {
  local label="$1"
  local desired="$2"
  local tries=60

  while (( tries > 0 )); do
    local ready
    ready=$("${KUBECTL[@]}" -n "$NS" get pods -l "$label" \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
      | grep -c '^true$' || true)

    if [[ "$ready" -eq "$desired" ]]; then
      return 0
    fi

    sleep 1
    ((tries--))
  done
  return 1
}

create_deploy_no_sidecar() {
  log "  -> tworzę Deployment ${DEPLOY_NO} (bez sidecara)"
  cat <<EOF | "${KUBECTL[@]}" -n "$NS" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NO}
  namespace: ${NS}
  labels:
    app: ${DEPLOY_NO}
    app.kubernetes.io/part-of: free5gc
    project: free5gc
spec:
  replicas: 0
  selector:
    matchLabels:
      app: ${DEPLOY_NO}
  template:
    metadata:
      labels:
        app: ${DEPLOY_NO}
        app.kubernetes.io/part-of: free5gc
        project: free5gc
        nf: upf
    spec:
      containers:
      - name: main
        image: docker.io/library/busybox:1.36
        command: ["sh","-c","sleep 3600"]
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF
}

create_deploy_with_sidecar() {
  log "  -> tworzę Deployment ${DEPLOY_YES} (z sidecarem tcpdump-sidecar)"
  cat <<EOF | "${KUBECTL[@]}" -n "$NS" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_YES}
  namespace: ${NS}
  labels:
    app: ${DEPLOY_YES}
    app.kubernetes.io/part-of: free5gc
    project: free5gc
spec:
  replicas: 0
  selector:
    matchLabels:
      app: ${DEPLOY_YES}
  template:
    metadata:
      labels:
        app: ${DEPLOY_YES}
        app.kubernetes.io/part-of: free5gc
        project: free5gc
        nf: upf
    spec:
      containers:
      - name: main
        image: docker.io/library/busybox:1.36
        command: ["sh","-c","sleep 3600"]
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
      - name: tcpdump-sidecar
        image: docker.io/corfr/tcpdump:latest
        command: ["sh","-c","sleep 3600"]
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF
}

measure_scenario() {
  local deploy="$1"
  local label="app=${deploy}"
  local scenario_name="$2"

  local sum=0

  for ((i=1; i<=ITERATIONS; i++)); do
    log
    log "    [${scenario_name} #${i}] skaluję ${deploy} do 0"
    "${KUBECTL[@]}" -n "$NS" scale deploy "${deploy}" --replicas=0 >/dev/null
    wait_pods_gone "$label" || log "    -> UWAGA: Pody nie zniknęły w czasie (kontynuuję)"

    log "    [${scenario_name} #${i}] skaluję ${deploy} do ${REPLICAS}"
    local t0 t1 dt
    t0=$(now_ms)
    "${KUBECTL[@]}" -n "$NS" scale deploy "${deploy}" --replicas="${REPLICAS}" >/dev/null
    if ! wait_pods_ready "$label" "${REPLICAS}"; then
      log "    -> UWAGA: nie wszystkie Pody są Ready, ale zapisuję czas"
    fi
    t1=$(now_ms)
    dt=$((t1 - t0))
    log "      czas skalowania (0 -> ${REPLICAS}) dla ${scenario_name}: ${dt} ms"
    sum=$((sum + dt))
  done

  # TYLKO liczba na STDOUT
  echo $((sum / ITERATIONS))
}

#
# MAIN
#
log "==[PERF-3-SYNTH] Czas startu 'syntetycznego UPF' (busybox z nf=upf): bez sidecara tcpdump vs z sidecarem =="
log "==[PERF-3-SYNTH]   ITERATIONS = ${ITERATIONS}, REPLICAS = ${REPLICAS}"

log
log "==[PERF-3-SYNTH] Krok 1: namespace + Deploymenty bazowe =="

ensure_ns

log "  -> sprzątanie starych Deploymentów"
"${KUBECTL[@]}" -n "$NS" delete deploy "${DEPLOY_NO}" "${DEPLOY_YES}" --ignore-not-found=true >/dev/null 2>&1 || true

create_deploy_no_sidecar
create_deploy_with_sidecar

log
log "==[PERF-3-SYNTH] Scenariusz: bez sidecara =="
AVG_NO=$(measure_scenario "${DEPLOY_NO}" "bez-sidecara")

log
log "==[PERF-3-SYNTH] Scenariusz: z sidecarem =="
AVG_YES=$(measure_scenario "${DEPLOY_YES}" "z-sidecarem")

DIFF=$((AVG_YES - AVG_NO))

log
log "==[PERF-3-SYNTH] PODSUMOWANIE =="
log "  Średni czas bez sidecara : ${AVG_NO} ms"
log "  Średni czas z sidecarem  : ${AVG_YES} ms"
log "  Różnica (with - base)    : ${DIFF} ms"

log
log "==[PERF-3-SYNTH] KONIEC TESTU =="

