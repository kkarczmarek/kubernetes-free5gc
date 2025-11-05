#!/usr/bin/env bash
set -euo pipefail
NS=free5gc

# Nazwy NAD-ów generowanych przez release 'free5gc-helm'
NAD_N2=n2network-free5gc-helm-free5gc-amf
NAD_N4=n4network-free5gc-helm-free5gc-smf

# Funkcja: nadpisuje spec.config tak, aby NIE było default route (routes=[])
patch_nad() {
  local name="$1"
  echo "[INFO] Patching NAD: $name"
  # pobierz aktualny master z istniejącego configu (żeby nie hardkodować)
  cur_cfg=$(kubectl -n "$NS" get net-attach-def "$name" -o jsonpath='{.spec.config}')
  master=$(printf '%s' "$cur_cfg" | sed -n 's/.*"master"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  master=${master:-ens4}

  new_cfg=$(cat <<JSON
{ "cniVersion": "0.3.1",
  "plugins": [
    { "type": "ipvlan",
      "capabilities": { "ips": true },
      "master": "$master",
      "mode": "l2",
      "ipam": { "type": "static", "routes": [] }
    }
  ]
}
JSON
)
  kubectl -n "$NS" patch net-attach-def "$name" --type=json \
    -p="[ {\"op\":\"replace\",\"path\":\"/spec/config\",\"value\":$(printf '%s' "$new_cfg" | jq -c .) } ]"
}

# Wymagane narzędzie jq:
if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] Brak 'jq' na hoście. Zainstaluj: sudo apt-get update && sudo apt-get install -y jq" >&2
  exit 1
fi

patch_nad "$NAD_N2"
patch_nad "$NAD_N4"

echo "[INFO] Restart AMF/SMF po zmianie NAD"
kubectl -n "$NS" rollout restart deploy free5gc-helm-free5gc-amf-amf free5gc-helm-free5gc-smf-smf

echo "[DONE] NAD fixed + restart triggered."
