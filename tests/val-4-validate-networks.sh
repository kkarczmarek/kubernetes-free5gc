#!/usr/bin/env bash
set -euo pipefail

KUBECTL=(microk8s kubectl)
NS="free5gc"

log() {
  echo "$@"
}

log "==[VAL-4] Walidacja CNI networks przy anotacji 5g.kkarczmarek.dev/validate-networks=="

log
log "==[VAL-4] Sprzątanie starych Podów =="
"${KUBECTL[@]}" -n "$NS" delete pod val4-networks-ok val4-networks-bad --ignore-not-found=true

###############################################################################
# KROK 1 – poprawne networks w DATA_CIDR -> OCZEKUJĘ ALLOW
###############################################################################
log
log "==[VAL-4] Krok 1: Pod z validate-networks=true i IP w DATA_CIDR – oczekuję ALLOW =="

cat <<EOF | "${KUBECTL[@]}" -n "$NS" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: val4-networks-ok
  labels:
    app: val4-networks-demo
    app.kubernetes.io/part-of: free5gc
    project: free5gc
  annotations:
    5g.kkarczmarek.dev/validate-networks: "true"
    k8s.v1.cni.cncf.io/networks: |
      [
        {
          "name": "n6network-free5gc-free5gc-upf",
          "interface": "n6",
          "ips": ["10.100.10.5/24"],
          "gateway": ["10.100.10.1"]
        }
      ]
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
EOF

# Pod może nie dojść do Ready, ważne że został przyjęty przez API (ALLOW)
if "${KUBECTL[@]}" -n "$NS" wait pod/val4-networks-ok --for=condition=Ready --timeout=30s; then
  log "OK: Pod val4-networks-ok osiągnął stan Ready (ALLOW)."
else
  log "UWAGA: Pod val4-networks-ok nie osiągnął Ready, ale został przyjęty przez webhook (ALLOW)."
fi

log "  -> Anotacje Poda val4-networks-ok:"
"${KUBECTL[@]}" -n "$NS" get pod val4-networks-ok -o jsonpath='{.metadata.annotations}'
echo

###############################################################################
# KROK 2 – zły networks (IP SPOZA DATA_CIDR) -> OCZEKUJĘ DENY
###############################################################################
log
log "==[VAL-4] Krok 2: Pod z validate-networks=true i IP SPOZA DATA_CIDR – oczekuję DENY =="

# zapisujemy YAML do pliku tymczasowego
TMP_BAD_YAML=$(mktemp)
cat <<EOF > "$TMP_BAD_YAML"
apiVersion: v1
kind: Pod
metadata:
  name: val4-networks-bad
  labels:
    app: val4-networks-demo
    app.kubernetes.io/part-of: free5gc
    project: free5gc
  annotations:
    5g.kkarczmarek.dev/validate-networks: "true"
    k8s.v1.cni.cncf.io/networks: |
      [
        {
          "name": "n6network-free5gc-free5gc-upf",
          "interface": "n6",
          "ips": ["192.168.10.5/24"],
          "gateway": ["192.168.10.1"]
        }
      ]
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
EOF

# próbujemy utworzyć Poda – oczekujemy, że webhook ODRZUCI ten manifest
ERR_FILE=$(mktemp)
if "${KUBECTL[@]}" -n "$NS" apply -f "$TMP_BAD_YAML" 2>"$ERR_FILE"; then
  log "[BŁĄD] Pod val4-networks-bad został UTWORZONY, a powinien być ODRZUCONY przy validate-networks=true!"
  "${KUBECTL[@]}" -n "$NS" get pod val4-networks-bad -o yaml | sed -n '1,80p' || true
else
  log "OK: Pod val4-networks-bad został ODRZUCONY przez webhook (IP spoza DATA_CIDR)."
  log "  -> komunikat z API:"
  cat "$ERR_FILE"
fi

rm -f "$TMP_BAD_YAML" "$ERR_FILE"

log
log "------------------------------------------------------------------"
log "==[VAL-4] KONIEC TESTU – ALLOW dla poprawnych networks i DENY dla złego IP =="
