#!/usr/bin/env bash
set -euo pipefail

NS="free5gc"
KCTL="microk8s kubectl"

echo "==[VAL-3] Walidacja: NET_ADMIN tylko przy allow-netadmin=true na namespace=="

ORIG_LABEL="$(${KCTL} get ns ${NS} -o jsonpath='{.metadata.labels.allow-netadmin}' 2>/dev/null || true)"
echo "  -> oryginalna wartość labela allow-netadmin: '${ORIG_LABEL}'"

cleanup() {
  echo
  echo "==[VAL-3] Przywracam oryginalny label allow-netadmin na namespace ${NS}=="
  if [ -z "${ORIG_LABEL}" ]; then
    ${KCTL} label ns "${NS}" allow-netadmin- || true
  else
    ${KCTL} label ns "${NS}" allow-netadmin="${ORIG_LABEL}" --overwrite || true
  fi
  ${KCTL} -n "${NS}" delete pod val3-netadmin-test --ignore-not-found
}
trap cleanup EXIT

echo
echo "==[VAL-3] Krok 1: ustawiam allow-netadmin=false na namespace ${NS}=="
${KCTL} label ns "${NS}" allow-netadmin="false" --overwrite

echo
echo "==[VAL-3] Krok 2: próbuję utworzyć Pod z NET_ADMIN – POWINNO SIĘ NIE UDAĆ=="
if ${KCTL} apply -f tests/val-3-netadmin-pod.yaml; then
  echo "ERROR: Pod z NET_ADMIN został stworzony przy allow-netadmin=false – BŁĄD" >&2
  exit 1
else
  echo "OK: tworzenie Poda z NET_ADMIN zostało odrzucone (allow-netadmin=false)"
fi

echo
echo "==[VAL-3] Krok 3: ustawiam allow-netadmin=true na namespace ${NS}=="
${KCTL} label ns "${NS}" allow-netadmin="true" --overwrite

echo
echo "==[VAL-3] Krok 4: próbuję utworzyć Pod z NET_ADMIN – TERAZ POWINNO SIĘ UDAĆ=="
${KCTL} apply -f tests/val-3-netadmin-pod.yaml

echo
echo "==[VAL-3] Krok 5: czekam aż Pod będzie Ready=="
${KCTL} -n "${NS}" wait pod val3-netadmin-test --for=condition=Ready --timeout=180s

echo
echo "OK: Pod z NET_ADMIN został poprawnie utworzony przy allow-netadmin=true"
echo "==[VAL-3] KONIEC TESTU=="
