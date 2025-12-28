#!/usr/bin/env bash
set -euo pipefail

NS="free5gc"
UPF_DEPLOY="free5gc-free5gc-upf-upf"
KCTL="microk8s kubectl -n ${NS}"

echo "==[TC-UPF-1] Ustawianie anotacji slicing + CIDR na Deployment UPF=="

# 1) upewniamy się, że jest jedna replika UPF
$KCTL scale deploy "${UPF_DEPLOY}" --replicas=1

# 2) patch z anotacjami slicing + adresacja
$KCTL patch deploy "${UPF_DEPLOY}" \
  -p '{
    "spec": {
      "template": {
        "metadata": {
          "annotations": {
            "5g.kkarczmarek.dev/slice-id": "1",
            "5g.kkarczmarek.dev/sst": "1",
            "5g.kkarczmarek.dev/sd": "010203",
            "5g.kkarczmarek.dev/dnn": "internet",
            "5g.kkarczmarek.dev/ue-pool-cidr": "10.60.0.0/24",
            "5g.kkarczmarek.dev/n6-cidr": "10.100.100.0/24",
            "5g.kkarczmarek.dev/tcpdump-enabled": "true"
          }
        }
      }
    }
  }'

echo
echo "==[TC-UPF-1] Usuwam aktualne Pody UPF, żeby Deployment utworzył nowe z anotacjami=="
$KCTL delete pod -l nf=upf --ignore-not-found

echo
echo "==[TC-UPF-1] Czekam na pełny rollout Deploymentu UPF=="
$KCTL rollout status deploy "${UPF_DEPLOY}" --timeout=300s

echo
echo "==[TC-UPF-1] Aktualne Pody UPF z labelami slicing/adresacja=="
$KCTL get pods -l nf=upf \
  -o wide \
  -L 5g.kkarczmarek.dev/slice-id,5g.kkarczmarek.dev/sst,5g.kkarczmarek.dev/sd,\
5g.kkarczmarek.dev/dnn,5g.kkarczmarek.dev/ue-pool-cidr,5g.kkarczmarek.dev/n6-cidr

