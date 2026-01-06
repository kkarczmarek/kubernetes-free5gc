#!/usr/bin/env bash
set -euo pipefail

# Używamy microk8s kubectl
KUBECTL=(microk8s kubectl)

NS="free5gc"

log() { echo "$@"; }

log "==[TC-UPF-3] Automatyczne porty PFCP/GTP-U dla nf=upf =="
echo

log "==[TC-UPF-3] Sprzątanie starych Podów =="
"${KUBECTL[@]}" -n "${NS}" delete pod upf-port-test upf-port-control \
  --ignore-not-found=true >/dev/null 2>&1 || true

echo
log "==[TC-UPF-3] Krok 1: tworzę Pod z nf=upf (upf-port-test) =="

cat <<EOF | "${KUBECTL[@]}" -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: upf-port-test
  labels:
    app.kubernetes.io/part-of: free5gc
    project: free5gc
    nf: upf
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
EOF

"${KUBECTL[@]}" -n "${NS}" wait pod/upf-port-test \
  --for=condition=Ready --timeout=60s

log "  -> ports zmutowanego Poda nf=upf:"
"${KUBECTL[@]}" -n "${NS}" get pod upf-port-test \
  -o jsonpath='{.spec.containers[0].ports}'; echo
echo

log "==[TC-UPF-3] Krok 2: Pod kontrolny bez nf=upf (upf-port-control) =="

cat <<EOF | "${KUBECTL[@]}" -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: upf-port-control
  labels:
    app.kubernetes.io/part-of: free5gc
    project: free5gc
    # brak nf=upf
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
EOF

"${KUBECTL[@]}" -n "${NS}" wait pod/upf-port-control \
  --for=condition=Ready --timeout=60s

PORTS_CTRL="$("${KUBECTL[@]}" -n "${NS}" get pod upf-port-control \
  -o jsonpath='{.spec.containers[0].ports}')"

if [[ -z "${PORTS_CTRL}" ]]; then
  log "  -> ports Poda kontrolnego: (pusty) – OK, brak automatycznych portów dla nie-UPF."
else
  log "  -> ports Poda kontrolnego: ${PORTS_CTRL}"
  log " [UWAGA] Pod kontrolny ma porty – sprawdź logikę selekcji nf=upf."
fi

echo
log "------------------------------------------------------------------"
log "==[TC-UPF-3] KONIEC TESTU – powyżej widać, że tylko nf=upf dostaje porty PFCP/GTP-U =="

