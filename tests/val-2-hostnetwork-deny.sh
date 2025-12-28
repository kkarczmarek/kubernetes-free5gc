#!/usr/bin/env bash
set -euo pipefail

echo "==[VAL-2] Walidacja: hostNetwork: true ma być zabronione=="
echo "  -> próbuję utworzyć Pod z hostNetwork=true w namespace free5gc"

if microk8s kubectl apply -f tests/val-2-hostnetwork-deny.yaml; then
  echo "ERROR: Pod z hostNetwork=true został stworzony, a powinien być ODRZUCONY" >&2
  exit 1
else
  echo "OK: tworzenie Poda zostało odrzucone (hostNetwork not allowed) – zgodnie z oczekiwaniem"
fi

echo
echo "==[VAL-2] KONIEC TESTU=="
