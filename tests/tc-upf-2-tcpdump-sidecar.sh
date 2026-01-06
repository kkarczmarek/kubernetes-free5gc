#!/usr/bin/env bash
set -euo pipefail

# Używamy microk8s kubectl
KUBECTL=(microk8s kubectl)

NS="perf-upf"
DEPLOY_NO="upf-tcpdump-no"
DEPLOY_YES="upf-tcpdump-yes"
LABEL_NO="app=upf-tcpdump-no"
LABEL_YES="app=upf-tcpdump-yes"

log() {
  echo "$@"
}

wait_for_pod_exist() {
  local ns="$1"
  local sel="$2"
  local tries=30

  while [ "$tries" -gt 0 ]; do
    local count
    count=$("${KUBECTL[@]}" -n "$ns" get pods -l "$sel" --no-headers 2>/dev/null | wc -l || true)
    if [ "$count" -gt 0 ]; then
      return 0
    fi
    log "  -> wciąż brak Poda (selector: $sel), czekam 2s..."
    sleep 2
    tries=$((tries - 1))
  done

  return 1
}

log "==[TC-UPF-2] Automatyczne dołączanie sidecara tcpdump do UPF (demo w perf-upf) =="

log
log "==[TC-UPF-2] Krok 0: Namespace + labele dla webhooka i NET_ADMIN =="

# Utwórz namespace perf-upf, jeśli go nie ma
if ! "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
  "${KUBECTL[@]}" create ns "$NS"
fi

# Włącz mutujący/ walidujący webhook w namespace + NET_ADMIN
"${KUBECTL[@]}" label ns "$NS" admission.kkarczmarek.dev/enabled=true --overwrite >/dev/null
"${KUBECTL[@]}" label ns "$NS" allow-netadmin=true --overwrite >/dev/null

log "  -> namespace ${NS} ma labele: admission.kkarczmarek.dev/enabled=true, allow-netadmin=true"

log
log "==[TC-UPF-2] Sprzątanie starych Deploymentów demo =="
"${KUBECTL[@]}" -n "$NS" delete deploy "$DEPLOY_NO" --ignore-not-found=true
"${KUBECTL[@]}" -n "$NS" delete deploy "$DEPLOY_YES" --ignore-not-found=true

log
log "==[TC-UPF-2] Krok 1: Deployment UPF z tcpdump-enabled=false (brak sidecara) =="

cat <<EODEP | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NO}
  namespace: ${NS}
  labels:
    app: upf-tcpdump-no
    app.kubernetes.io/part-of: free5gc
    project: free5gc
spec:
  replicas: 1
  selector:
    matchLabels:
      app: upf-tcpdump-no
  template:
    metadata:
      labels:
        app: upf-tcpdump-no
        app.kubernetes.io/part-of: free5gc
        project: free5gc
        nf: upf
      annotations:
        5g.kkarczmarek.dev/tcpdump-enabled: "false"
        5g.kkarczmarek.dev/networks: "n6-net@10.100.10.5/24"
    spec:
      containers:
      - name: main
        image: docker.io/library/busybox:1.36
        command: ["sh","-c","sleep 3600"]
EODEP

# Czekamy aż pojawi się Pod demo z tcpdump-enabled=false
if ! wait_for_pod_exist "$NS" "$LABEL_NO"; then
  log "[BŁĄD] Nie udało się utworzyć Poda dla ${DEPLOY_NO}"
  "${KUBECTL[@]}" -n "$NS" get pods -o wide || true
  exit 1
fi

POD_NO=$("${KUBECTL[@]}" -n "$NS" get pods -l "$LABEL_NO" -o jsonpath='{.items[0].metadata.name}')

log "  -> Pod bez tcpdump-enabled=true: ${POD_NO}"
log "  -> Kontenery:"
"${KUBECTL[@]}" -n "$NS" get pod "$POD_NO" -o jsonpath='{range .spec.containers[*]}{"\n  - "}{.name}{end}'
echo

log
log "==[TC-UPF-2] Krok 2: Deployment UPF z tcpdump-enabled=true (OCZEKUJĘ sidecara) =="

cat <<EODEP2 | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_YES}
  namespace: ${NS}
  labels:
    app: upf-tcpdump-yes
    app.kubernetes.io/part-of: free5gc
    project: free5gc
spec:
  replicas: 1
  selector:
    matchLabels:
      app: upf-tcpdump-yes
  template:
    metadata:
      labels:
        app: upf-tcpdump-yes
        app.kubernetes.io/part-of: free5gc
        project: free5gc
        nf: upf
      annotations:
        5g.kkarczmarek.dev/tcpdump-enabled: "true"
        5g.kkarczmarek.dev/networks: "n6-net@10.100.10.5/24"
    spec:
      containers:
      - name: main
        image: docker.io/library/busybox:1.36
        command: ["sh","-c","sleep 3600"]
EODEP2

# Czekamy aż pojawi się Pod z tcpdump-enabled=true
if ! wait_for_pod_exist "$NS" "$LABEL_YES"; then
  log "[BŁĄD] Nie udało się utworzyć Poda dla ${DEPLOY_YES} (możliwe odrzucenie przez webhook)"
  "${KUBECTL[@]}" -n "$NS" get pods -o wide || true
  exit 1
fi

POD_YES=$("${KUBECTL[@]}" -n "$NS" get pods -l "$LABEL_YES" -o jsonpath='{.items[0].metadata.name}')

log "  -> Pod z tcpdump-enabled=true: ${POD_YES}"
log "  -> Kontenery:"
"${KUBECTL[@]}" -n "$NS" get pod "$POD_YES" -o jsonpath='{range .spec.containers[*]}{"\n  - "}{.name}{end}'
echo

log
log "------------------------------------------------------------------"
log "==[TC-UPF-2] KONIEC TESTU –"
log "   * Deployment ${DEPLOY_NO}: tylko 'main'"
log "   * Deployment ${DEPLOY_YES}: 'main' + 'tcpdump-sidecar' (mutacja przez webhook) =="
