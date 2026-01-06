#!/usr/bin/env bash
set -euo pipefail

# zawsze microk8s kubectl
KUBECTL=(microk8s kubectl)

NS="free5gc"
DEPLOY="upf-slicing-demo"
LABEL_SELECTOR="app=upf-slicing-demo"

log() {
  echo "$@"
}

log "==[TC-UPF-1] Slicing + DNN na anotacjach UPF i etykietach Poda =="

log
log "==[TC-UPF-1] Sprzątanie starego Deploymentu demo =="
"${KUBECTL[@]}" -n "$NS" delete deploy "$DEPLOY" --ignore-not-found=true

log
log "==[TC-UPF-1] Krok 1: Tworzę demo-UPF z anotacjami 5g.* (BEZ CIDRów) =="

cat <<EODEP | "${KUBECTL[@]}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
  labels:
    app: upf-slicing-demo
    app.kubernetes.io/part-of: free5gc
    project: free5gc
spec:
  replicas: 1
  selector:
    matchLabels:
      app: upf-slicing-demo
  template:
    metadata:
      labels:
        app: upf-slicing-demo
        app.kubernetes.io/part-of: free5gc
        project: free5gc
        nf: upf
      annotations:
        5g.kkarczmarek.dev/slice-id: "1"
        5g.kkarczmarek.dev/sst: "1"
        5g.kkarczmarek.dev/sd: "010203"
        5g.kkarczmarek.dev/dnn: "internet"
    spec:
      containers:
      - name: main
        image: docker.io/library/busybox:1.36
        command: ["sh","-c","sleep 3600"]
EODEP

log
log "==[TC-UPF-1] Krok 2: Czekam na rollout i wybieram Poda =="

"${KUBECTL[@]}" -n "$NS" rollout status deploy/"$DEPLOY"

POD=$("${KUBECTL[@]}" -n "$NS" get pods -l "$LABEL_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}')

log "  -> Pod UPF demo: ${POD}"

log
log "==[TC-UPF-1] Anotacje 5g.* na Podzie =="
ANN=$("${KUBECTL[@]}" -n "$NS" get pod "$POD" -o jsonpath='{.metadata.annotations}')
if echo "$ANN" | grep -q '5g.kkarczmarek.dev'; then
  echo "$ANN" | tr ' ' '\n' | grep '5g.kkarczmarek.dev' | sed 's/^/  /'
else
  echo "  (brak anotacji 5g.*)"
fi

log
log "==[TC-UPF-1] Labele 5g.* na Podzie (zmutowane przez webhook) =="
LBL=$("${KUBECTL[@]}" -n "$NS" get pod "$POD" -o jsonpath='{.metadata.labels}')
if echo "$LBL" | grep -q '5g.kkarczmarek.dev'; then
  echo "$LBL" | tr ' ' '\n' | grep '5g.kkarczmarek.dev' | sed 's/^/  /'
else
  echo "  (brak labeli 5g.*)"
fi

log
log "------------------------------------------------------------------"
log "==[TC-UPF-1] KONIEC TESTU – slicing/DNN są w anotacjach i (opcjonalnie) labelach Poda nf=upf =="
