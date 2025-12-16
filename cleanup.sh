#!/bin/bash
set -e

# Cleanup script for ToolHive demo-in-a-box Kubernetes cluster

# Explicitly delete ngrok Operator resources to avoid leaving orphaned resources in your ngrok account
echo "Uninstalling ngrok Operator to clean up your ngrok account..."
kubectl delete httproutes.gateway.networking.k8s.io --all --all-namespaces || true
kubectl delete -f ngrok-gateway.yaml || true
kubectl delete domains.ingress.k8s.ngrok.com --all --all-namespaces || true
kubectl delete $(kubectl get crd -o name | grep "ngrok") || true
helm uninstall ngrok-operator --namespace ngrok-operator || true

# The rest we can just nuke from orbit. It's the only way to be sure.
echo "Deleting Kind cluster..."
kind delete cluster --name toolhive-demo-in-a-box
rm -f kubeconfig-toolhive-demo.yaml

echo "Cleanup complete!"
