#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Uruchom jako root: sudo $0"; exit 1
fi

# MicroK8s
if ! snap list | grep -q microk8s; then
  snap install microk8s --channel=1.28/stable --classic
fi

# Grupa i kube dir
usermod -a -G microk8s ${SUDO_USER:-$USER}
chown -f -R ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} /home/${SUDO_USER:-$USER}/.kube || true

# Start i HA (pozwala na join workerów)
microk8s status --wait-ready
microk8s enable ha-cluster || true
microk8s status

echo "----- Komenda do uruchomienia na workerze (jako sudo) -----"
microk8s add-node | sed -n 's/^\s*microk8s join/microk8s join/p' | head -n1
echo "-----------------------------------------------------------"
