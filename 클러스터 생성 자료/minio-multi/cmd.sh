#!/bin/bash

# helm 저장소 추가
# helm repo add bitnami https://charts.bitnami.com/bitnami
# helm repo update

helm upgrade --install kei-test-minio bitnami/minio \
    -n kei-test-minio --create-namespace \
    -f values-minio-test.yaml \
    --version 14.7.11
