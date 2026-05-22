#!/bin/bash
set -euo pipefail

RELEASE_NAME="${CYBERPULSE_RELEASE_NAME:-cyberpulse}"
WEBAPP_NAMESPACE="${CYBERPULSE_WEBAPP_NAMESPACE:-dmz}"
INTERNAL_NAMESPACE="${CYBERPULSE_INTERNAL_NAMESPACE:-internal}"
DATA_NAMESPACE="${CYBERPULSE_DATA_NAMESPACE:-data}"
IMAGE_PREFIX="${CYBERPULSE_IMAGE_PREFIX:-ghcr.io/solutionscst}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

confirm_uninstall() {
  if [ "${CYBERPULSE_ASSUME_YES:-false}" = "true" ]; then
    return
  fi

  echo "WARNING: This will uninstall CyberPulse production resources from this cluster."
  echo ""
  echo "It will delete:"
  echo "  - Helm release: $RELEASE_NAME in namespace $INTERNAL_NAMESPACE"
  echo "  - Helm release: postgres in namespace $DATA_NAMESPACE"
  echo "  - Namespaces: $WEBAPP_NAMESPACE, $INTERNAL_NAMESPACE, $DATA_NAMESPACE"
  echo "  - Kubernetes secrets, Postgres data PVCs, and report PVCs in those namespaces"
  echo "  - Local CyberPulse Docker/containerd images where possible"
  echo ""
  read -r -p "Type yes to continue: " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
}

delete_namespace_and_wait() {
  local namespace="$1"

  kubectl delete namespace "$namespace" --ignore-not-found
  kubectl wait --for=delete "namespace/$namespace" --timeout=120s 2>/dev/null || true
}

remove_containerd_image() {
  local image="$1"

  if command -v k3s >/dev/null 2>&1; then
    sudo k3s ctr images rm "$image" 2>/dev/null || true
    return
  fi

  local node=""
  node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$node" ] && command -v docker >/dev/null 2>&1; then
    docker exec "$node" ctr -n k8s.io images rm "$image" 2>/dev/null || true
  fi
}

remove_docker_images() {
  if ! command -v docker >/dev/null 2>&1; then
    return
  fi

  docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E '(^|/)cyberpulse-(webapp|fastapi|worker):' \
    | sort -u \
    | xargs -r docker rmi 2>/dev/null || true

  docker image prune -f 2>/dev/null || true
}

require_command kubectl
require_command helm

confirm_uninstall

echo ""
echo "=== Uninstalling CyberPulse Helm release ==="
helm uninstall "$RELEASE_NAME" -n "$INTERNAL_NAMESPACE" --ignore-not-found

echo ""
echo "=== Uninstalling PostgreSQL Helm release ==="
helm uninstall postgres -n "$DATA_NAMESPACE" --ignore-not-found

echo ""
echo "=== Deleting namespaces ==="
delete_namespace_and_wait "$WEBAPP_NAMESPACE"
delete_namespace_and_wait "$INTERNAL_NAMESPACE"
delete_namespace_and_wait "$DATA_NAMESPACE"

echo ""
echo "=== Cleaning local CyberPulse images ==="
remove_containerd_image "$IMAGE_PREFIX/cyberpulse-webapp:latest"
remove_containerd_image "$IMAGE_PREFIX/cyberpulse-fastapi:latest"
remove_containerd_image "$IMAGE_PREFIX/cyberpulse-worker:latest"
remove_containerd_image "docker.io/library/cyberpulse-webapp:latest"
remove_containerd_image "docker.io/library/cyberpulse-fastapi:latest"
remove_containerd_image "docker.io/library/cyberpulse-worker:latest"
remove_docker_images

echo ""
echo "CyberPulse production resources have been removed."
