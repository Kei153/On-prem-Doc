#!/bin/bash

# 네임스페이스 추가
# kubectl create namespace argocd

# helm 저장소 추가
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# helm 차트 설치
helm upgrade --install argocd argo/argo-cd \
    -n test \
    -f values-argocd.yaml \
    --version 7.6.5
