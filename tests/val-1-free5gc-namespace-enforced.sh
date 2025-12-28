#!/usr/bin/env bash
set -euo pipefail

echo "==[VAL-1] Walidacja: free5gc tylko w namespace free5gc=="
echo "  -> próbuję utworzyć Pod z app.kubernetes.io/part-of=free5gc w namespace playground"

if microk8s kubectl apply -f tests/val-1-free5gc-namespace-enforced.yaml; then
  echo "ERROR: Pod został stworzony w playground, a powinien zostać ODRZUCONY" >&2
  exit 1
else
  echo "OK: tworzenie Poda zostało odrzucone (namespace != free5gc) – zgodnie z oczekiwaniem"
fi

echo
echo "==[VAL-1] KONIEC TESTU=="
