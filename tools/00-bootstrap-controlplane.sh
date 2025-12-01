#!/usr/bin/env bash
set -euo pipefail

# ====== USTAWIENIA PODSTAWOWE ======
echo "[00] Aktualizacja pakietów i narzędzia ogólne…"
sudo apt-get update -y
sudo apt-get install -y curl wget jq ca-certificates gnupg lsb-release

# ====== MICROK8S ======
if ! snap list | grep -q microk8s; then
  echo "[01] Instalacja MicroK8s…"
  sudo snap install microk8s --classic
fi

echo "[02] Dodanie użytkownika do grupy microk8s…"
if [[ -n "${SUDO_USER:-}" ]]; then
  sudo usermod -a -G microk8s "$SUDO_USER"
  sudo chown -R "$SUDO_USER":"$SUDO_USER" "/home/$SUDO_USER/.kube" 2>/dev/null || true
else
  sudo usermod -a -G microk8s "$(whoami)"
  sudo chown -R "$(whoami)":"$(whoami)" "$HOME/.kube" 2>/dev/null || true
fi

echo "[03] Oczekiwanie na gotowość klastra…"
sudo microk8s status --wait-ready

# (opcjonalnie) podstawowe dodatki MicroK8s do testów
echo "[04] Włączenie DNS i storage (hostpath)…"
sudo microk8s enable dns
sudo microk8s enable hostpath-storage

# ====== KUBECTL ======
echo "[05] Udostępnienie kubectl jako polecenie systemowe…"
sudo ln -sf /snap/bin/microk8s.kubectl /usr/local/bin/kubectl

# ====== HELM ======
if ! command -v helm >/dev/null 2>&1; then
  echo "[06] Instalacja Helm…"
  sudo snap install helm --classic
fi

# ====== COSIGN (do podpisów obrazów) ======
if ! command -v cosign >/dev/null 2>&1; then
  echo "[07] Instalacja Cosign…"
  sudo snap install cosign --classic || true
fi

# ====== SYSCTL / BRIDGE / FORWARD ======
echo "[08] Konfiguracja sysctl dla K8s (bridge, ip_forward)…"
sudo tee /etc/sysctl.d/99-k8s.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sudo modprobe br_netfilter || true
sudo sysctl --system

echo "[DONE] Controlplane gotowy. Jeśli to pierwsze uruchomienie, wyloguj i zaloguj się ponownie, aby zadziałała grupa 'microk8s'. Potem sprawdź: kubectl get nodes"
