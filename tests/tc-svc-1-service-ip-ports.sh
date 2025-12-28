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

log "==[TC-SVC-1] Walidacja anotacji service-ip i required-ports na Service =="
echo

log "==[TC-SVC-1] Sprzątanie starych Service'ów =="
"${KUBECTL[@]}" -n "$NS" delete svc svc-web-ok svc-web-bad-ip svc-web-missing-port --ignore-not-found=true >/dev/null 2>&1 || true
echo

# -------------------------------------------------------------------
# KROK 1: Poprawny Service – IP w DATA_CIDR, komplet wymaganych portów
# -------------------------------------------------------------------
log "==[TC-SVC-1] Krok 1: poprawny Service (IP w DATA_CIDR, komplet portów) – oczekuję ALLOW =="

if cat <<'YAML' | "${KUBECTL[@]}" -n "$NS" apply -f -; then
apiVersion: v1
kind: Service
metadata:
  name: svc-web-ok
  labels:
    app: web
    app.kubernetes.io/part-of: free5gc
    project: free5gc
  annotations:
    5g.kkarczmarek.dev/service-ip: "10.100.10.50"
    5g.kkarczmarek.dev/required-ports: "80,443"
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
YAML
  log "[OK] svc-web-ok został UTWORZONY – poprawna konfiguracja."
  log "     Sprawdzam porty i anotacje..."
  divider
  "${KUBECTL[@]}" -n "$NS" get svc svc-web-ok -o wide
  echo
else
  log "[BŁĄD] svc-web-ok został ODRZUCONY, a powinien być dozwolony!"
fi

echo

# -------------------------------------------------------------------
# KROK 2: IP spoza DATA_CIDR – oczekiwany DENY
# -------------------------------------------------------------------
log "==[TC-SVC-1] Krok 2: IP poza DATA_CIDR – oczekuję DENY =="

if cat <<'YAML' | "${KUBECTL[@]}" -n "$NS" apply -f -; then
apiVersion: v1
kind: Service
metadata:
  name: svc-web-bad-ip
  labels:
    app: web
    app.kubernetes.io/part-of: free5gc
    project: free5gc
  annotations:
    5g.kkarczmarek.dev/service-ip: "192.168.10.50"   # poza DATA_CIDR=10.100.0.0/16
    5g.kkarczmarek.dev/required-ports: "80,443"
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
YAML
  log "[BŁĄD] svc-web-bad-ip został UTWORZONY, a powinien być ODRZUCONY przez webhook!"
  divider
  "${KUBECTL[@]}" -n "$NS" get svc svc-web-bad-ip -o wide || true
  echo
else
  log "[OK] svc-web-bad-ip został ODRZUCONY przez webhook – IP poza DATA_CIDR."
fi

echo

# -------------------------------------------------------------------
# KROK 3: Brak wymaganego portu z required-ports – oczekiwany DENY
# -------------------------------------------------------------------
log "==[TC-SVC-1] Krok 3: brak jednego z wymaganych portów – oczekuję DENY =="

if cat <<'YAML' | "${KUBECTL[@]}" -n "$NS" apply -f -; then
apiVersion: v1
kind: Service
metadata:
  name: svc-web-missing-port
  labels:
    app: web
    app.kubernetes.io/part-of: free5gc
    project: free5gc
  annotations:
    5g.kkarczmarek.dev/service-ip: "10.100.20.50"
    5g.kkarczmarek.dev/required-ports: "80,443"
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
    # celowo brak portu 443
YAML
  log "[BŁĄD] svc-web-missing-port został UTWORZONY, a powinien być ODRZUCONY (brak portu 443)!"
  divider
  "${KUBECTL[@]}" -n "$NS" get svc svc-web-missing-port -o wide || true
  echo
else
  log "[OK] svc-web-missing-port został ODRZUCONY przez webhook – brak wymaganego portu 443."
fi

echo
divider
log "==[TC-SVC-1] KONIEC TESTU – zobacz komunikaty ALLOW/DENY powyżej =="
