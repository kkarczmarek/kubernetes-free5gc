#!/usr/bin/env bash
set -euo pipefail

# Używamy microk8s kubectl
KUBECTL=(microk8s kubectl)

NS="perf-upf"
UPF_LABEL="app=upf-perf"

log() {
  echo "$@"
}

log "==[TC-UPF-5] Ruch testowy do UPF z tcpdump-sidecar (perf-upf) =="

log
log "==[TC-UPF-5] Krok 1: Szukam istniejącego UPF z sidecarem (upf-perf) =="

UPF_POD="$(
  "${KUBECTL[@]}" -n "$NS" get pods -l "$UPF_LABEL" \
    -o jsonpath='{.items[0].metadata.name}'
)"
UPF_IP="$(
  "${KUBECTL[@]}" -n "$NS" get pod "$UPF_POD" \
    -o jsonpath='{.status.podIP}'
)"

log "  -> UPF Pod: ${UPF_POD}"
log "  -> UPF IP : ${UPF_IP}"

log
log "==[TC-UPF-5] Krok 2: Tworzę klienta upf-traffic-client w tym samym namespace =="

"${KUBECTL[@]}" -n "$NS" delete pod upf-traffic-client --ignore-not-found=true

cat <<EOF | "${KUBECTL[@]}" -n "$NS" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: upf-traffic-client
  namespace: ${NS}
  labels:
    app: upf-traffic-client
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
EOF

"${KUBECTL[@]}" -n "$NS" wait pod/upf-traffic-client \
  --for=condition=Ready --timeout=60s

log
log "==[TC-UPF-5] Krok 3: Wysyłam ping z klienta do UPF =="

"${KUBECTL[@]}" -n "$NS" exec upf-traffic-client -- \
  ping -c 5 "$UPF_IP" || true

log
log "==[TC-UPF-5] Krok 4: Sprawdzam plik PCAP w kontenerze tcpdump-sidecar =="

"${KUBECTL[@]}" -n "$NS" exec "$UPF_POD" -c tcpdump-sidecar -- \
  sh -c '
    echo "  -> Zawartość katalogu /data:";
    ls -lh /data || true;
    echo;
    echo "  -> Pierwsze kilka pakietów z /data/trace.pcap:";
    tcpdump -nn -r /data/trace.pcap -c 10 || true
  '

log
log "------------------------------------------------------------------"
log "==[TC-UPF-5] KONIEC TESTU – powyżej powinieneś zobaczyć pakiety (np. ICMP ping) =="

