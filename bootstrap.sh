#!/bin/sh
set -e

# Bootstrap script for ToolHive demo-in-a-box Kubernetes cluster

## Requirements:
# - kind
# - kubectl
# - helm
# - ToolHive CLI (thv)
# - ngrok account with authtoken and API key stored as ToolHive secrets
# - GitHub token stored as ToolHive secret
# - Okta client secret stored as ToolHive secret

THV_GITHUB_SECRET_REF="github"
THV_OKTA_CLIENT_SECRET_REF="okta-client-secret"
THV_NGROK_AUTHTOKEN_REF="ngrok-authtoken"
THV_NGROK_API_KEY_REF="ngrok-api-key"

read -p "Enter your ngrok domain (hostname only, e.g., example.ngrok-free.dev): " NGROK_DOMAIN

# echo "Creating Kind cluster..."
# kind create cluster --name toolhive-demo-in-a-box
# kind get kubeconfig --name toolhive-demo-in-a-box > kubeconfig-toolhive-demo.yaml
# export KUBECONFIG=$(pwd)/kubeconfig-toolhive-demo.yaml

# # Traefik chart installs Gateway API CRDs automatically, installing them separately breaks things.
# #echo "Installing Gateway API..."
# #kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

# # Add Helm repos and update
# helm repo add traefik https://traefik.github.io/charts
# helm repo add ngrok https://charts.ngrok.com
# helm repo update

# # Reference: https://doc.traefik.io/traefik/getting-started/kubernetes/
# echo "Installing Traefik..."
# helm upgrade --install traefik traefik/traefik --version 37.4.0 --namespace traefik --create-namespace --values traefik-helm-values.yaml --wait

# Reference: https://ngrok.com/docs/getting-started/kubernetes/gateway-api
echo "Installing ngrok Operator..."
kubectl create namespace ngrok-operator
kubectl create secret generic ngrok-operator-credentials --namespace ngrok-operator --from-literal=API_KEY=$(thv secret get $THV_NGROK_API_KEY_REF) --from-literal=AUTHTOKEN=$(thv secret get $THV_NGROK_AUTHTOKEN_REF)
helm upgrade --install ngrok-operator ngrok/ngrok-operator --version 0.21.1 --namespace ngrok-operator --create-namespace --set defaultDomainReclaimPolicy=Retain --set credentials.secret.name=ngrok-operator-credentials --wait
envsubst < ngrok-gateway.yaml | kubectl apply -f -

# Reference: https://docs.stacklok.com/toolhive/tutorials/quickstart-k8s
echo "Installing ToolHive Operator..."
helm upgrade --install toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds --version 0.0.85 --wait
helm upgrade --install toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator --version 0.5.13 --namespace toolhive-system --create-namespace --wait

echo "Creating secrets..."
kubectl create secret generic github-token --namespace toolhive-system --from-literal=token=$(thv secret get $THV_GITHUB_SECRET_REF)
# kubectl create secret generic okta-client-secret --namespace toolhive-system --from-literal=token=$(thv secret get $THV_OKTA_CLIENT_SECRET_REF)

echo "Installing Registry Server..."
kubectl apply -f registry-server.yaml

read -p "Now, run 'cloud-provider-kind' in another terminal to assign an IP to the traefik gateway. Press Enter to continue once the IP is assigned..."

TRAEFIK_IP=$(kubectl get gateways --namespace traefik traefik-gateway -o "jsonpath={.status.addresses[0].value}")
TRAEFIK_HOSTNAME="mcp-${TRAEFIK_IP//./-}.traefik.me"

echo "Installing MKP MCP server..."
envsubst < demo-manifests/mcpserver-mkp.yaml | kubectl apply -f -

echo "Installing vMCP demo servers..."
kubectl apply -f demo-manifests/vmcp-mcpservers.yaml
sleep 10 # TODO: replace with proper wait
envsubst < demo-manifests/vmcp-demo-simple.yaml | kubectl apply -f -
# envsubst < demo-manifests/vmcp-demo-auth.yaml | kubectl apply -f -

echo "Bootstrap complete!"
echo "Access the ToolHive Registry Server at https://$NGROK_DOMAIN/registry"
echo "Access the MKP MCP server at http://$TRAEFIK_HOSTNAME/mkp/mcp"
echo "Access the vMCP demo server at http://$TRAEFIK_HOSTNAME/vmcp-demo/mcp"
