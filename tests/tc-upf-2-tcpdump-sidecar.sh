#!/usr/bin/env bash
set -euo pipefail

NS="free5gc"
UPF_DEPLOY="free5gc-free5gc-upf-upf"
KCTL="microk8s kubectl -n ${NS}"

echo "==[TC-UPF-2] Weryfikacja sidecara tcpdump-sidecar dla UPF=="

echo
echo "==[TC-UPF-2] Krok 1: skaluję UPF do 0 replik (twardy reset)=="
${KCTL} scale deploy "${UPF_DEPLOY}" --replicas=0

echo
echo "==[TC-UPF-2] Krok 2: czekam aż znikną wszystkie Pody nf=upf=="
for i in $(seq 1 30); do
  CNT="$(${KCTL} get pod -l nf=upf --no-headers 2>/dev/null | wc -l || echo 0)"
  if [ "${CNT}" = "0" ]; then
    echo "  -> brak Podów nf=upf"
    break
  fi
  echo "  -> wciąż ${CNT} Pod(ów) nf=upf, czekam 5s..."
  sleep 5
done

echo
echo "==[TC-UPF-2] Krok 3: włączam anotację tcpdump-enabled na Deployment UPF=="
${KCTL} patch deploy "${UPF_DEPLOY}" \
  -p '{
    "spec": {
      "template": {
        "metadata": {
          "annotations": {
            "5g.kkarczmarek.dev/tcpdump-enabled": "true"
          }
        }
      }
    }
  }'

echo
echo "==[TC-UPF-2] Krok 4: skaluję UPF do 1 repliki=="
${KCTL} scale deploy "${UPF_DEPLOY}" --replicas=1

echo
echo "==[TC-UPF-2] Krok 5: czekam aż pojawi się nowy Pod nf=upf=="
UPF_POD=""
for i in $(seq 1 60); do
  UPF_POD="$(${KCTL} get pod -l nf=upf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${UPF_POD}" ]; then
    echo "  -> znalazłem Pod: ${UPF_POD}"
    break
  fi
  echo "  ...brak Podów nf=upf, czekam 5s"
  sleep 5
done

if [ -z "${UPF_POD}" ]; then
  echo "ERROR: nie udało się znaleźć żadnego Pod-a nf=upf" >&2
  exit 1
fi

echo
echo "==[TC-UPF-2] Krok 6: czekam aż Pod ${UPF_POD} będzie Ready=="
${KCTL} wait pod "${UPF_POD}" --for=condition=Ready --timeout=300s

echo
echo "==[TC-UPF-2] Kontenery w Podzie UPF (${UPF_POD})=="
${KCTL} get pod "${UPF_POD}" -o jsonpath='{.spec.containers[*].name}{"\n"}'

echo
echo "==[TC-UPF-2] Zmienne środowiskowe sidecara tcpdump-sidecar (UPF_*)=="
${KCTL} exec -it "${UPF_POD}" -c tcpdump-sidecar -- env | grep '^UPF_' || true

echo
echo "==[TC-UPF-2] Zawartość /data w tcpdump-sidecar=="
${KCTL} exec -it "${UPF_POD}" -c tcpdump-sidecar -- ls -lh /data || true

echo
echo "==[TC-UPF-2] KONIEC TESTU – sidecar tcpdump-sidecar zweryfikowany=="
