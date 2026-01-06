#!/usr/bin/env bash
set -euo pipefail

# Używamy microk8s kubectl
KUBECTL=(microk8s kubectl)
NS="free5gc"

log() {
  echo "$@"
}

log "==[TC-SVC-1] Walidacja anotacji required-ports na Service =="

log
log "==[TC-SVC-1] Sprzątanie starych Service'ów =="
"${KUBECTL[@]}" -n "$NS" delete svc svc-web-ok svc-web-missing-port svc-web-bad-ports --ignore-not-found=true

###############################################################################
# KROK 1 – poprawny Service:
#  - anotacja required-ports: "80,443"
#  - w spec.ports są zarówno 80, jak i 443
#  -> OCZEKUJĘ: ALLOW
###############################################################################
log
log "==[TC-SVC-1] Krok 1: poprawny Service (komplet portów) – oczekuję ALLOW =="

cat <<EOF | "${KUBECTL[@]}" -n "$NS" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: svc-web-ok
  labels:
    app: web
    app.kubernetes.io/part-of: free5gc
    project: free5gc
  annotations:
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
EOF

log "  -> Service został STWORZONY (oczekiwane ALLOW):"
"${KUBECTL[@]}" -n "$NS" get svc svc-web-ok -o wide

###############################################################################
# KROK 2 – brak jednego z wymaganych portów:
#  - required-ports: "80,443"
#  - w spec.ports jest tylko 80
#  -> OCZEKUJĘ: DENY od naszego webhooka
###############################################################################
log
log "==[TC-SVC-1] Krok 2: brak wymaganego portu 443 – oczekuję DENY =="

if "${KUBECTL[@]}" -n "$NS" apply -f - 2>svc-missing-port.err <<EOF; then
apiVersion: v1
kind: Service
metadata:
  name: svc-web-missing-port
  labels:
    app: web
    app.kubernetes.io/part-of: free5gc
    project: free5gc
  annotations:
    5g.kkarczmarek.dev/required-ports: "80,443"
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
    # brak portu 443 – webhook powinien się przyczepić
EOF
  log "[BŁĄD] svc-web-missing-port został UTWORZONY, a powinien być ODRZUCONY przez webhook!"
  "${KUBECTL[@]}" -n "$NS" get svc svc-web-missing-port -o yaml | sed -n '1,80p' || true
else
  log "[OK] svc-web-missing-port został ODRZUCONY przez webhook – brak wymaganego portu 443."
  log "  -> komunikat z API:"
  cat svc-missing-port.err
fi
rm -f svc-missing-port.err

###############################################################################
# KROK 3 – błędny format required-ports:
#  - required-ports: "80,foo" (foo nie jest liczbą)
#  -> OCZEKUJĘ: DENY z komunikatem o niepoprawnej liście portów
###############################################################################
log
log "==[TC-SVC-1] Krok 3: błędna anotacja required-ports – oczekuję DENY =="

if "${KUBECTL[@]}" -n "$NS" apply -f - 2>svc-bad-ports.err <<EOF; then
apiVersion: v1
kind: Service
metadata:
  name: svc-web-bad-ports
  labels:
    app: web
    app.kubernetes.io/part-of: free5gc
    project: free5gc
  annotations:
    5g.kkarczmarek.dev/required-ports: "80,foo"
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF
  log "[BŁĄD] svc-web-bad-ports został UTWORZONY, a powinien być ODRZUCONY (zły format required-ports)!"
  "${KUBECTL[@]}" -n "$NS" get svc svc-web-bad-ports -o yaml | sed -n '1,80p' || true
else
  log "[OK] svc-web-bad-ports został ODRZUCONY przez webhook – błędny format required-ports."
  log "  -> komunikat z API:"
  cat svc-bad-ports.err
fi
rm -f svc-bad-ports.err

log
log "------------------------------------------------------------------"
log "==[TC-SVC-1] KONIEC TESTU – powyżej: ALLOW dla poprawnego Service"
log "             oraz dwa DENY: brak portu 443 i błędna anotacja required-ports =="
