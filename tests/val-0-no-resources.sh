#!/usr/bin/env bash
set -euo pipefail

NS="free5gc"
KCTL="microk8s kubectl -n ${NS}"

echo "==[VAL-0] Walidacja: Pod bez resources cpu/memory ma zostać ODRZUCONY=="

if ${KCTL} apply -f tests/03-deny-no-resources.yaml; then
  echo "ERROR: Pod został stworzony, a powinien zostać ODRZUCONY przez webhook" >&2
  exit 1
else
  echo "OK: tworzenie Poda zostało odrzucone (brak resources) – zgodnie z oczekiwaniem"
fi
