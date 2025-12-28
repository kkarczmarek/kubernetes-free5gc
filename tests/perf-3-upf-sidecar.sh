#!/usr/bin/env bash
set -euo pipefail

# Używamy microk8s kubectl (ważne!)
KUBECTL=(microk8s kubectl)

NS="free5gc"
DEPLOY="free5gc-free5gc-upf-upf"
LABEL="nf=upf"

ITERATIONS="${1:-5}"

now_ms() {
  date +%s%3N
}

log() {
  echo "$@"
}

# Czekaj aż znikną wszystkie Pody nf=upf (max ~60s)
wait_upf_gone() {
  local tries=30
  while (( tries > 0 )); do
    local count
    count=$("${KUBECTL[@]}" -n "$NS" get pods -l "$LABEL" --no-headers 2>/dev/null | wc -l || true)
    if [[ "$count" -eq 0 ]]; then
      log "  -> brak Podów nf=upf"
      return 0
    fi
    log "  -> wciąż $count Pod(ów) nf=upf, czekam 2s..."
    sleep 2
    ((tries--))
  done
  log "  !! timeout przy czekaniu na zniknięcie Podów nf=upf"
  return 1
}

# Jedna próba: skala 0 -> 1, pomiar czasu do Ready
# Zwraca (echo) czas w ms albo exit 1 przy nieudanym starcie.
measure_upf_once() {
  local label="$1"

  # 1) skaluj do 0 i wyczyść Pody
  "${KUBECTL[@]}" -n "$NS" scale deploy "$DEPLOY" --replicas=0 >/dev/null
  if ! wait_upf_gone; then
    log "  !! [${label}] nie udało się wyczyścić Podów nf=upf – odrzucam próbę"
    return 1
  fi

  # 2) start pomiaru + skalowanie do 1
  local t0 t1
  t0="$(now_ms)"
  "${KUBECTL[@]}" -n "$NS" scale deploy "$DEPLOY" --replicas=1 >/dev/null

  # 3) czekamy aż pojawi się nowy Pod nf=upf (max 30s)
  local pod=""
  local appear_deadline=$((t0 + 30000))
  while :; do
    pod=$("${KUBECTL[@]}" -n "$NS" get pod -l "$LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
      log "  -> pojawił się Pod nf=upf: $pod"
      break
    fi
    if (( "$(now_ms)" > appear_deadline )); then
      log "  !! [${label}] żaden Pod nf=upf nie pojawił się w 30s – odrzucam próbę"
      return 1
    fi
    sleep 1
  done

  # 4) czekamy aż Pod będzie Ready (max 60s)
  local ready_deadline=$((t0 + 90000))
  while :; do
    local cond
    cond=$("${KUBECTL[@]}" -n "$NS" get pod "$pod" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{end}' 2>/dev/null || true)
    if grep -q "Ready=True" <<<"$cond"; then
      t1="$(now_ms)"
      local delta=$((t1 - t0))
      log "       czas startu UPF (0 -> 1) w ns=${NS}: ${delta} ms (Pod=${pod})"
      echo "$delta"
      return 0
    fi
    if (( "$(now_ms)" > ready_deadline )); then
      log "  !! [${label}] Pod ${pod} nie osiągnął Ready w 60s – odrzucam próbę"
      return 1
    fi
    sleep 2
  done
}

run_scenario() {
  local label="$1"   # np. "bez-sidecara" / "z-sidecarem"
  local tcpdump="$2" # "true" / "false"

  log ""
  log "==[PERF-3] Scenariusz: ${label} (tcpdump-enabled=${tcpdump}) =="

  # ustaw anotację na Deploymencie
  "${KUBECTL[@]}" -n "$NS" patch deploy "$DEPLOY" \
    --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"5g.kkarczmarek.dev/tcpdump-enabled\":\"${tcpdump}\"}}}}}" >/dev/null

  local sum_ms=0
  local ok=0

  for i in $(seq 1 "$ITERATIONS"); do
    log ""
    log "    [${label} #${i}] pomiar startu UPF"

    # WAŻNE: measure_upf_once może się nie udać -> nie wliczamy
    local delta
    if delta="$(measure_upf_once "$label")"; then
      sum_ms=$((sum_ms + delta))
      ok=$((ok + 1))
    else
      log "    -> [${label} #${i}] próba nieudana – pomiar odrzucony"
    fi
  done

  if [[ "$ok" -gt 0 ]]; then
    local avg=$((sum_ms / ok))
    log ""
    log "  ==> Średni czas scenariusza '${label}' z ${ok} udanych prób: ${avg} ms"
  else
    log ""
    log "  ==> Brak udanych prób w scenariuszu '${label}' – brak średniej"
  fi

  # Na koniec zostaw UPF z 1 repliką, żeby nie zabić całego labu
  "${KUBECTL[@]}" -n "$NS" scale deploy "$DEPLOY" --replicas=1 >/dev/null
}

echo "==[PERF-3] Czas startu UPF: bez sidecara tcpdump vs z sidecarem =="
echo "  ITERATIONS = ${ITERATIONS}"
echo

# Scenariusz 1: bez sidecara
run_scenario "bez-sidecara" "false"

# Scenariusz 2: z sidecarem
run_scenario "z-sidecarem" "true"

# Kontrola końcowa – jaki UPF został na końcu
echo
echo "==[PERF-3] Kontrola końcowa UPF =="
UPF_POD="$("${KUBECTL[@]}" -n "$NS" get pod -l "$LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$UPF_POD" ]]; then
  echo "  -> UPF Pod: ${UPF_POD}"
  echo "  -> Kontenery w Podzie:"
  "${KUBECTL[@]}" -n "$NS" get pod "$UPF_POD" -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}'
  echo
else
  echo "  -> brak aktywnego Poda nf=upf"
fi

echo
echo "==[PERF-3] KONIEC TESTU =="
