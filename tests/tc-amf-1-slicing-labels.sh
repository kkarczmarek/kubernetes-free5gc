#!/usr/bin/env bash
set -euo pipefail

NS="free5gc"
AMF_DEPLOY="free5gc-free5gc-amf-amf"
KCTL="microk8s kubectl -n ${NS}"

echo "==[TC-AMF-1] Slicing + DNN przeniesione z anotacji AMF na labele Poda=="

echo
echo "==[TC-AMF-1] Krok 1: skaluję AMF do 0 replik (twardy reset)=="
${KCTL} scale deploy "${AMF_DEPLOY}" --replicas=0

echo
echo "==[TC-AMF-1] Krok 2: czekam aż znikną wszystkie Pody nf=amf=="
for i in $(seq 1 30); do
  CNT="$(${KCTL} get pod -l nf=amf --no-headers 2>/dev/null | wc -l || echo 0)"
  if [ "${CNT}" = "0" ]; then
    echo "  -> brak Podów nf=amf"
    break
  fi
  echo "  -> wciąż ${CNT} Pod(ów) nf=amf, czekam 5s..."
  sleep 5
done

echo
echo "==[TC-AMF-1] Krok 3: ustawiam anotacje slicing + DNN na Deployment AMF=="
${KCTL} patch deploy "${AMF_DEPLOY}" \
  -p '{
    "spec": {
      "template": {
        "metadata": {
          "annotations": {
            "5g.kkarczmarek.dev/slice-id": "1",
            "5g.kkarczmarek.dev/sst": "1",
            "5g.kkarczmarek.dev/sd": "010203",
            "5g.kkarczmarek.dev/dnn": "internet"
          }
        }
      }
    }
  }'

echo
echo "==[TC-AMF-1] Krok 4: skaluję AMF do 1 repliki=="
${KCTL} scale deploy "${AMF_DEPLOY}" --replicas=1

echo
echo "==[TC-AMF-1] Krok 5: czekam aż pojawi się nowy Pod nf=amf=="
AMF_POD=""
for i in $(seq 1 60); do
  AMF_POD="$(${KCTL} get pod -l nf=amf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${AMF_POD}" ]; then
    echo "  -> znalazłem Pod: ${AMF_POD}"
    break
  fi
  echo "  ...brak Podów nf=amf, czekam 5s"
  sleep 5
done

if [ -z "${AMF_POD}" ]; then
  echo "ERROR: nie udało się znaleźć żadnego Pod-a nf=amf" >&2
  exit 1
fi

echo
echo "==[TC-AMF-1] Krok 6: czekam aż Pod ${AMF_POD} będzie Ready=="
${KCTL} wait pod "${AMF_POD}" --for=condition=Ready --timeout=300s

echo
echo "==[TC-AMF-1] Anotacje Poda AMF (${AMF_POD}) dla kluczy 5g.* =="
${KCTL} get pod "${AMF_POD}" -o json | jq '.metadata.annotations | to_entries[] | select(.key | startswith("5g.kkarczmarek.dev/"))'

echo
echo "==[TC-AMF-1] Labele Poda AMF (${AMF_POD}) dla kluczy 5g.* (kolumny)=="
${KCTL} get pod "${AMF_POD}" \
  -L 5g.kkarczmarek.dev/slice-id,5g.kkarczmarek.dev/sst,5g.kkarczmarek.dev/sd,5g.kkarczmarek.dev/dnn

echo
echo "==[TC-AMF-1] KONIEC TESTU – slicing + DNN skopiowane na labele Poda AMF=="
