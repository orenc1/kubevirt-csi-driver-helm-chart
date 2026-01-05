#!/bin/bash

# 1. Define Variables
NAMESPACE=${NAMESPACE:-"nested-cluster"}
SECRET_NAME="kubevirt-csi-infra-token"
KUBECONFIG_FILE="infra-kubeconfig"

# 2. Extract Data
# Get the API Server URL
SERVER_URL=$(oc whoami --show-server)

# Get the CA Certificate from the Secret
CA_CERT=$(oc get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.ca\.crt}')

# Get the Token from the Secret and decode it
TOKEN=$(oc get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.token}' | base64 -d)

# 3. Create the Kubeconfig File
cat <<EOF > $KUBECONFIG_FILE
apiVersion: v1
kind: Config
clusters:
- name: infra-cluster
  cluster:
    certificate-authority-data: $CA_CERT
    server: $SERVER_URL
contexts:
- name: infra-context
  context:
    cluster: infra-cluster
    namespace: $NAMESPACE
    user: csi-driver-user
current-context: infra-context
users:
- name: csi-driver-user
  user:
    token: $TOKEN
EOF
