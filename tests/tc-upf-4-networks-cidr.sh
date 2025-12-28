#!/usr/bin/env bash
set -euo pipefail

# Używamy microk8s kubectl
KUBECTL=(microk8s kubectl)
NS="free5gc"

log() {
  echo "$@"
}

divider() {
  echo "------------------------------------------------------------------"
}

wait_ready() {
  local pod="$1"
  "${KUBECTL[@]}" -n "$NS" wait pod/"$pod" --for=condition=Ready --timeout=60s >/dev/null
}

log "==[TC-UPF-4] Walidacja anotacji 5g.kkarczmarek.dev/networks dla UPF =="

echo
log "==[TC-UPF-4] Sprzątanie starych Podów (upf-net-*) =="
"${KUBECTL[@]}" -n "$NS" delete pod upf-net-ok upf-net-bad upf-net-control --ignore-not-found=true >/dev/null 2>&1 || true
echo

# -------------------------------------------------------------------
# KROK 1: nf=upf + networks w DATA_CIDR – oczekuję ALLOW
# -------------------------------------------------------------------
log "==[TC-UPF-4] Krok 1: Pod nf=upf z poprawnym networks (w DATA_CIDR) – oczekuję ALLOW =="

if cat <<'YAML' | "${KUBECTL[@]}" -n "$NS" apply -f -; then
apiVersion: v1
kind: Pod
metadata:
  name: upf-net-ok
  labels:
    app.kubernetes.io/part-of: free5gc
    project: free5gc
    nf: upf
  annotations:
    5g.kkarczmarek.dev/networks: "n6-net@10.100.10.5/24"
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
YAML
  log "[OK] upf-net-ok został UTWORZONY – anotacja networks zaakceptowana."
  wait_ready upf-net-ok || true
  divider
  log "  -> Anotacje Poda upf-net-ok:"
  "${KUBECTL[@]}" -n "$NS" get pod upf-net-ok -o jsonpath='{.metadata.annotations}' || true
  echo; echo
else
  log "[BŁĄD] upf-net-ok został ODRZUCONY, a powinien być dozwolony!"
fi

echo

# -------------------------------------------------------------------
# KROK 2: nf=upf + networks z IP poza DATA_CIDR – oczekuję DENY
# -------------------------------------------------------------------
log "==[TC-UPF-4] Krok 2: Pod nf=upf z IP spoza DATA_CIDR w networks – oczekuję DENY =="

if cat <<'YAML' | "${KUBECTL[@]}" -n "$NS" apply -f -; then
apiVersion: v1
kind: Pod
metadata:
  name: upf-net-bad
  labels:
    app.kubernetes.io/part-of: free5gc
    project: free5gc
    nf: upf
  annotations:
    5g.kkarczmarek.dev/networks: "n6-net@192.168.10.5/24"   # poza DATA_CIDR=10.100.0.0/16
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
YAML
  log "[BŁĄD] upf-net-bad został UTWORZONY, a powinien być ODRZUCONY przez webhook!"
  divider
  "${KUBECTL[@]}" -n "$NS" get pod upf-net-bad -o wide || true
  echo
else
  log "[OK] upf-net-bad został ODRZUCONY przez webhook – IP spoza dozwolonego DATA_CIDR."
fi

echo

# -------------------------------------------------------------------
# KROK 3: Pod bez nf=upf, ale z anotacją networks – oczekuję ALLOW
#         (webhook powinien ignorować networks dla nie-UPF)
# -------------------------------------------------------------------
log "==[TC-UPF-4] Krok 3: Pod BEZ nf=upf, ale z anotacją networks – oczekuję ALLOW =="

if cat <<'YAML' | "${KUBECTL[@]}" -n "$NS" apply -f -; then
apiVersion: v1
kind: Pod
metadata:
  name: upf-net-control
  labels:
    app.kubernetes.io/part-of: free5gc
    project: free5gc
    # brak nf=upf
  annotations:
    5g.kkarczmarek.dev/networks: "n6-net@192.168.10.5/24"
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
YAML
  log "[OK] upf-net-control został UTWORZONY – anotacja networks jest ignorowana dla nie-UPF."
  wait_ready upf-net-control || true
  divider
  log "  -> Anotacje Poda upf-net-control:"
  "${KUBECTL[@]}" -n "$NS" get pod upf-net-control -o jsonpath='{.metadata.annotations}' || true
  echo; echo
else
  log "[BŁĄD] upf-net-control został ODRZUCONY, a powinien być dozwolony (nf != upf)!"
fi

echo
divider
log "==[TC-UPF-4] KONIEC TESTU – zobacz ALLOW/DENY dla networks powyżej =="

