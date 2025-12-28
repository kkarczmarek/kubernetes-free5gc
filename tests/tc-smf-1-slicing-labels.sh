#!/usr/bin/env bash
set -euo pipefail

NS="free5gc"
SMF_DEPLOY="free5gc-free5gc-smf-smf"
KCTL="microk8s kubectl -n ${NS}"

echo "==[TC-SMF-1] Slicing + DNN przeniesione z anotacji SMF na labele Poda=="

echo
echo "==[TC-SMF-1] Krok 1: skaluję SMF do 0 replik (twardy reset)=="
${KCTL} scale deploy "${SMF_DEPLOY}" --replicas=0

echo
echo "==[TC-SMF-1] Krok 2: czekam aż znikną wszystkie Pody nf=smf=="
for i in $(seq 1 30); do
  CNT="$(${KCTL} get pod -l nf=smf --no-headers 2>/dev/null | wc -l || echo 0)"
  if [ "${CNT}" = "0" ]; then
    echo "  -> brak Podów nf=smf"
    break
  fi
  echo "  -> wciąż ${CNT} Pod(ów) nf=smf, czekam 5s..."
  sleep 5
done

echo
echo "==[TC-SMF-1] Krok 3: ustawiam anotacje slicing + DNN na Deployment SMF=="
${KCTL} patch deploy "${SMF_DEPLOY}" \
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
echo "==[TC-SMF-1] Krok 4: skaluję SMF do 1 repliki=="
${KCTL} scale deploy "${SMF_DEPLOY}" --replicas=1

echo
echo "==[TC-SMF-1] Krok 5: czekam aż pojawi się nowy Pod nf=smf=="
SMF_POD=""
for i in $(seq 1 60); do
  SMF_POD="$(${KCTL} get pod -l nf=smf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${SMF_POD}" ]; then
    echo "  -> znalazłem Pod: ${SMF_POD}"
    break
  fi
  echo "  ...brak Podów nf=smf, czekam 5s"
  sleep 5
done

if [ -z "${SMF_POD}" ]; then
  echo "ERROR: nie udało się znaleźć żadnego Pod-a nf=smf" >&2
  exit 1
fi

echo
echo "==[TC-SMF-1] Krok 6: czekam aż Pod ${SMF_POD} będzie Ready=="
${KCTL} wait pod "${SMF_POD}" --for=condition=Ready --timeout=300s

echo
echo "==[TC-SMF-1] Anotacje Poda SMF (${SMF_POD}) dla kluczy 5g.* =="
${KCTL} get pod "${SMF_POD}" -o json | jq '.metadata.annotations | to_entries[] | select(.key | startswith("5g.kkarczmarek.dev/"))'

echo
echo "==[TC-SMF-1] Labele Poda SMF (${SMF_POD}) dla kluczy 5g.* (kolumny)=="
${KCTL} get pod "${SMF_POD}" \
  -L 5g.kkarczmarek.dev/slice-id,5g.kkarczmarek.dev/sst,5g.kkarczmarek.dev/sd,5g.kkarczmarek.dev/dnn

echo
echo "==[TC-SMF-1] KONIEC TESTU – slicing + DNN skopiowane na labele Poda SMF=="
