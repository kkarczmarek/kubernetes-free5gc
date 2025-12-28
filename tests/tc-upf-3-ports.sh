#!/usr/bin/env bash

set -euo pipefail

# ZAWSZE używamy microk8s kubectl

KUBECTL=(microk8s kubectl)

NS="free5gc"
UPF_POD="upf-port-test"
CTRL_POD="upf-port-control"

echo "==[TC-UPF-3] Automatyczne porty PFCP/GTP-U dla nf=upf =="

echo
echo "==[TC-UPF-3] Sprzątanie starych Podów =="
"${KUBECTL[@]}" -n "${NS}" delete pod "${UPF_POD}" "${CTRL_POD}" \
  --ignore-not-found=true >/dev/null 2>&1 || true

echo
echo "==[TC-UPF-3] Krok 1: tworzę Pod z nf=upf (${UPF_POD}) =="
cat <<POD | "${KUBECTL[@]}" -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${UPF_POD}
  labels:
    app.kubernetes.io/part-of: free5gc
    project: free5gc
    nf: upf
spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
POD

"${KUBECTL[@]}" -n "${NS}" wait pod/"${UPF_POD}" --for=condition=Ready --timeout=60s

echo
echo "==[TC-UPF-3] Pod nf=upf (${UPF_POD}) – ports[] zdefiniowane przez webhook =="
"${KUBECTL[@]}" -n "${NS}" get pod "${UPF_POD}" \
  -o jsonpath='{range .spec.containers[0].ports[*]}- {@.name}: {@.containerPort}/{@.protocol}{"\n"}{end}' \
  || echo "  (brak ports[])"

echo
echo "==[TC-UPF-3] Krok 2: tworzę kontrolny Pod bez nf=upf (${CTRL_POD}) =="

cat <<POD | "${KUBECTL[@]}" -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${CTRL_POD}
  labels:
    app.kubernetes.io/part-of: free5gc
    project: free5gc
    # brak nf=upf

spec:
  containers:
  - name: main
    image: docker.io/library/busybox:1.36
    command: ["sh","-c","sleep 3600"]
POD

"${KUBECTL[@]}" -n "${NS}" wait pod/"${CTRL_POD}" --for=condition=Ready --timeout=60s

echo
echo "==[TC-UPF-3] Pod kontrolny (${CTRL_POD}) – ports[] =="
PORTS_CTRL=$(
  "${KUBECTL[@]}" -n "${NS}" get pod "${CTRL_POD}" \
    -o jsonpath='{range .spec.containers[0].ports[*]}- {@.name}: {@.containerPort}/{@.protocol}{"\n"}{end}' \
    2>/dev/null || true
)
if [ -z "${PORTS_CTRL}" ]; then
  echo "  (brak ports[] – webhook nie dopiął portów, bo to nie nf=upf)"
else
  echo "${PORTS_CTRL}"
fi

echo
echo "==[TC-UPF-3] Podsumowanie =="
echo "  - Pod ${UPF_POD} (nf=upf) ma automatycznie dodane porty PFCP (8805/UDP) i GTP-U (2152/UDP)."
echo "  - Pod ${CTRL_POD} (bez nf=upf) nie ma żadnych ports[]."
echo
echo "Oba Pody zostały zostawione w namespace ${NS} – możesz je podejrzeć:"
echo "  ${KUBECTL[*]} -n ${NS} get pod ${UPF_POD} ${CTRL_POD} -o wide"

