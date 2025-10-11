#!/usr/bin/env bash
set -euo pipefail

helm upgrade --install -n free5gc free5gc-helm ./free5gc/ \
  -f ~/kubernetes-free5gc/helm-values/free5gc/values-upf-gcp.yaml \
  -f ~/kubernetes-free5gc/helm-values/free5gc/values-min-core.yaml \
  -f ~/kubernetes-free5gc/helm-values/free5gc/values-ifnames-fixed.yaml \
  -f ~/kubernetes-free5gc/helm-values/free5gc/values-disable-upfs.yaml \
  --set mongodb.nodeSelector."kubernetes\.io/hostname"=controlplane \
  --set mongodb.architecture=standalone \
  --set mongodb.replicaCount=1 \
  --set mongodb.resources.requests.cpu=20m \
  --set mongodb.resources.requests.memory=96Mi \
  --set mongodb.image.registry=public.ecr.aws \
  --set mongodb.image.repository=bitnami/mongodb \
  --set mongodb.image.tag=6.0

# Po helm: fix NAD + restart AMF/SMF
~/kubernetes-free5gc/scripts/fix-free5gc-nads.sh

# Podgląd statusu
kubectl -n free5gc get pods -o wide
