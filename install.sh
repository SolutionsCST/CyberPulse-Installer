#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR/charts/cyberpulse"
SECRETS_DIR="$SCRIPT_DIR/secrets"
SECRETS_BACKUP="$SECRETS_DIR/prod-secrets.yaml"

RELEASE_NAME="${CYBERPULSE_RELEASE_NAME:-cyberpulse}"
IMAGE_PREFIX="${CYBERPULSE_IMAGE_PREFIX:-ghcr.io/solutionscst}"
IMAGE_TAG="${CYBERPULSE_IMAGE_TAG:-}"
IMAGE_PULL_POLICY="${CYBERPULSE_IMAGE_PULL_POLICY:-Always}"
PULL_SECRET_NAME="${CYBERPULSE_PULL_SECRET_NAME:-cyberpulse-ghcr}"
VALUES_FILE="${CYBERPULSE_VALUES_FILE:-}"
ACCESS_MODE="${CYBERPULSE_ACCESS_MODE:-}"
CYBERPULSE_PUBLIC_URL="${CYBERPULSE_PUBLIC_URL:-}"
CYBERPULSE_CORS_ORIGINS="${CYBERPULSE_CORS_ORIGINS:-}"
CYBERPULSE_ENABLE_HSTS="${CYBERPULSE_ENABLE_HSTS:-}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
CLOUDFLARE_TUNNEL_SECRET_NAME="${CLOUDFLARE_TUNNEL_SECRET_NAME:-cloudflare-tunnel-token}"
CLOUDFLARE_TUNNEL_REPLICAS="${CLOUDFLARE_TUNNEL_REPLICAS:-2}"

WEBAPP_NAMESPACE="${CYBERPULSE_WEBAPP_NAMESPACE:-dmz}"
INTERNAL_NAMESPACE="${CYBERPULSE_INTERNAL_NAMESPACE:-internal}"
DATA_NAMESPACE="${CYBERPULSE_DATA_NAMESPACE:-data}"
MODE="install"

mkdir -p "$SECRETS_DIR"

usage() {
  cat <<EOF
Usage: ./install.sh [--dump-credentials] [--help]

Options:
  --dump-credentials  Back up existing application Kubernetes Secrets to $SECRETS_BACKUP and exit.
  --help              Show this help.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

prompt_if_empty() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local secret="${4:-false}"
  local value="${!var_name:-}"

  if [ -n "$value" ]; then
    return
  fi

  if [ "$secret" = "true" ]; then
    read -r -s -p "$prompt: " value
    echo ""
  elif [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt: " value
  fi

  if [ -z "$value" ]; then
    echo "A value is required for $var_name" >&2
    exit 1
  fi

  printf -v "$var_name" '%s' "$value"
}

prompt_optional() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local value="${!var_name:-}"

  if [ -n "$value" ]; then
    return
  fi

  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt: " value
  fi

  printf -v "$var_name" '%s' "$value"
}

helm_set_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//,/\\,}"
  printf '%s' "$value"
}

create_pull_secret() {
  local namespace="$1"

  PULL_SECRET_NAME="$PULL_SECRET_NAME" \
  GHCR_USERNAME="$GHCR_USERNAME" \
  GHCR_TOKEN="$GHCR_TOKEN" \
  python3 - "$namespace" <<'PY' | kubectl apply -f -
import base64
import json
import os
import json
import sys

namespace = sys.argv[1]
name = os.environ["PULL_SECRET_NAME"]
username = os.environ["GHCR_USERNAME"]
token = os.environ["GHCR_TOKEN"]

auth = base64.b64encode(f"{username}:{token}".encode()).decode()
dockerconfig = {
    "auths": {
        "ghcr.io": {
            "username": username,
            "password": token,
            "auth": auth,
        }
    }
}
encoded = base64.b64encode(json.dumps(dockerconfig).encode()).decode()

print(f"""apiVersion: v1
kind: Secret
metadata:
  name: {name}
  namespace: {namespace}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: {encoded}
""")
PY
}

create_cloudflare_tunnel_secret() {
  CLOUDFLARE_TUNNEL_SECRET_NAME="$CLOUDFLARE_TUNNEL_SECRET_NAME" \
  CLOUDFLARE_TUNNEL_TOKEN="$CLOUDFLARE_TUNNEL_TOKEN" \
  python3 - "$WEBAPP_NAMESPACE" <<'PY' | kubectl apply -f -
import os
import json
import sys

namespace = sys.argv[1]
name = os.environ["CLOUDFLARE_TUNNEL_SECRET_NAME"]
token = os.environ["CLOUDFLARE_TUNNEL_TOKEN"]

print(f"""apiVersion: v1
kind: Secret
metadata:
  name: {name}
  namespace: {namespace}
type: Opaque
stringData:
  TUNNEL_TOKEN: {json.dumps(token)}
""")
PY
}

wait_for_postgres() {
  local pod=""
  local deadline=$((SECONDS + 180))

  echo "Waiting for PostgreSQL pod..."
  while [ "$SECONDS" -lt "$deadline" ]; do
    pod="$(kubectl get pods -n "$DATA_NAMESPACE" \
      -l app.kubernetes.io/instance=postgres \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [ -n "$pod" ]; then
      kubectl wait --for=condition=ready "pod/$pod" -n "$DATA_NAMESPACE" --timeout=180s
      return
    fi

    sleep 2
  done

  echo "Timed out waiting for PostgreSQL pod to be created." >&2
  kubectl get pods -n "$DATA_NAMESPACE" >&2 || true
  exit 1
}

adopt_resource_if_present() {
  local namespace="$1"
  local kind="$2"
  local name="$3"

  if ! kubectl get "$kind" "$name" -n "$namespace" >/dev/null 2>&1; then
    return
  fi

  kubectl label "$kind" "$name" -n "$namespace" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite >/dev/null
  kubectl annotate "$kind" "$name" -n "$namespace" \
    meta.helm.sh/release-name="$RELEASE_NAME" \
    meta.helm.sh/release-namespace="$INTERNAL_NAMESPACE" \
    --overwrite >/dev/null
}

adopt_existing_cyberpulse_resources() {
  adopt_resource_if_present "$WEBAPP_NAMESPACE" deployment webapp
  adopt_resource_if_present "$WEBAPP_NAMESPACE" service webapp

  adopt_resource_if_present "$INTERNAL_NAMESPACE" deployment fastapi
  adopt_resource_if_present "$INTERNAL_NAMESPACE" service fastapi
  adopt_resource_if_present "$INTERNAL_NAMESPACE" serviceaccount fastapi
  adopt_resource_if_present "$INTERNAL_NAMESPACE" deployment worker
  adopt_resource_if_present "$INTERNAL_NAMESPACE" serviceaccount worker
  adopt_resource_if_present "$INTERNAL_NAMESPACE" deployment redis
  adopt_resource_if_present "$INTERNAL_NAMESPACE" service redis
  adopt_resource_if_present "$INTERNAL_NAMESPACE" persistentvolumeclaim reports-pvc
  adopt_resource_if_present "$INTERNAL_NAMESPACE" networkpolicy internal-default-deny
  adopt_resource_if_present "$INTERNAL_NAMESPACE" networkpolicy fastapi-ingress
  adopt_resource_if_present "$INTERNAL_NAMESPACE" networkpolicy redis-ingress
  adopt_resource_if_present "$INTERNAL_NAMESPACE" networkpolicy app-egress
  adopt_resource_if_present "$INTERNAL_NAMESPACE" networkpolicy worker-vendor-egress
}

read_secret_value() {
  local secret_name="$1"
  local key="$2"

  kubectl get secret "$secret_name" -n "$INTERNAL_NAMESPACE" -o "jsonpath={.data.$key}" | base64 -d
}

dump_application_credentials() {
  echo "Backing up existing application secrets to $SECRETS_BACKUP..."

  POSTGRES_USER=$(read_secret_value postgres-credentials POSTGRES_USER)
  POSTGRES_PASSWORD=$(read_secret_value postgres-credentials POSTGRES_PASSWORD)
  POSTGRES_HOST=$(read_secret_value postgres-credentials POSTGRES_HOST)
  POSTGRES_PORT=$(read_secret_value postgres-credentials POSTGRES_PORT)
  POSTGRES_DB=$(read_secret_value postgres-credentials POSTGRES_DB)
  JWT_SECRET=$(read_secret_value jwt-secret JWT_SECRET)
  MFA_SECRET_KEY=$(read_secret_value mfa-secret MFA_SECRET_KEY)
  ENCRYPTION_PUBLIC_KEY=$(read_secret_value fastapi-encryption ENCRYPTION_PUBLIC_KEY)
  ENCRYPTION_PRIVATE_KEY=$(read_secret_value fetcher-encryption ENCRYPTION_PRIVATE_KEY)
  REDIS_PASSWORD=$(read_secret_value redis-credentials REDIS_PASSWORD)
  REDIS_URL=$(read_secret_value redis-credentials REDIS_URL)

  cat > "$SECRETS_BACKUP" <<EOF
# CyberPulse Prod Secrets - backed up $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# DO NOT commit this file to git
# GHCR credentials are stored only in Kubernetes image pull secrets.

[postgres-credentials]
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_HOST=$POSTGRES_HOST
POSTGRES_PORT=$POSTGRES_PORT
POSTGRES_DB=$POSTGRES_DB

[jwt-secret]
JWT_SECRET=$JWT_SECRET

[mfa-secret]
MFA_SECRET_KEY=$MFA_SECRET_KEY

[fastapi-encryption]
ENCRYPTION_PUBLIC_KEY<<PUBLIC_KEY
$ENCRYPTION_PUBLIC_KEY
PUBLIC_KEY

[fetcher-encryption]
ENCRYPTION_PRIVATE_KEY<<PRIVATE_KEY
$ENCRYPTION_PRIVATE_KEY
PRIVATE_KEY

[redis-credentials]
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_URL=$REDIS_URL
EOF
  chmod 600 "$SECRETS_BACKUP"
  echo "Secrets backed up to $SECRETS_BACKUP"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dump-credentials)
      MODE="dump-credentials"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

require_command kubectl

if [ "$MODE" = "dump-credentials" ]; then
  dump_application_credentials
  exit 0
fi

require_command helm
require_command python3

if [ ! -f "$CHART_DIR/Chart.yaml" ]; then
  echo "Could not find Helm chart at $CHART_DIR" >&2
  exit 1
fi

prompt_if_empty IMAGE_TAG "CyberPulse image tag"
prompt_if_empty GHCR_USERNAME "GitHub/GHCR username"
prompt_if_empty GHCR_TOKEN "GitHub/GHCR access token" "" true

if [ -z "$ACCESS_MODE" ]; then
  echo ""
  echo "Access mode:"
  echo "  traefik    Expose webapp on the server/LAN over HTTP port 80"
  echo "  cloudflare Expose webapp through Cloudflare Tunnel; no inbound ports"
  echo "  none       Do not expose webapp; use kubectl port-forward or custom networking"
  read -r -p "CyberPulse access mode [traefik]: " ACCESS_MODE
  ACCESS_MODE="${ACCESS_MODE:-traefik}"
fi

case "$ACCESS_MODE" in
  traefik|cloudflare|none) ;;
  *)
    echo "Invalid access mode: $ACCESS_MODE" >&2
    echo "Expected one of: traefik, cloudflare, none" >&2
    exit 1
    ;;
esac

if [ "$ACCESS_MODE" = "cloudflare" ]; then
  prompt_if_empty CLOUDFLARE_TUNNEL_TOKEN "Cloudflare Tunnel token" "" true
fi

case "$ACCESS_MODE" in
  cloudflare)
    prompt_if_empty CYBERPULSE_PUBLIC_URL "Public CyberPulse URL, including https://"
    ;;
  traefik)
    prompt_optional CYBERPULSE_PUBLIC_URL "Public/internal CyberPulse URL, including http://"
    ;;
  none)
    prompt_optional CYBERPULSE_PUBLIC_URL "CyberPulse URL for CORS, if any"
    ;;
esac

if [ -z "$CYBERPULSE_CORS_ORIGINS" ]; then
  CYBERPULSE_CORS_ORIGINS="http://localhost:3000,http://localhost:80"
  if [ -n "$CYBERPULSE_PUBLIC_URL" ]; then
    CYBERPULSE_CORS_ORIGINS="$CYBERPULSE_PUBLIC_URL,$CYBERPULSE_CORS_ORIGINS"
  fi
fi

if [ -z "$CYBERPULSE_ENABLE_HSTS" ]; then
  if [[ "$CYBERPULSE_PUBLIC_URL" == https://* ]]; then
    CYBERPULSE_ENABLE_HSTS="true"
  else
    CYBERPULSE_ENABLE_HSTS="false"
  fi
fi

CYBERPULSE_CORS_ORIGINS_HELM="$(helm_set_escape "$CYBERPULSE_CORS_ORIGINS")"

echo "=== CyberPulse production install/update ==="
echo "Release: $RELEASE_NAME"
echo "Image prefix: $IMAGE_PREFIX"
echo "Image tag: $IMAGE_TAG"
echo "Pull policy: $IMAGE_PULL_POLICY"
echo "Access mode: $ACCESS_MODE"
if [ -n "$CYBERPULSE_PUBLIC_URL" ]; then
  echo "Public URL: $CYBERPULSE_PUBLIC_URL"
fi
echo "CORS origins: $CYBERPULSE_CORS_ORIGINS"
echo "HSTS enabled: $CYBERPULSE_ENABLE_HSTS"

echo ""
echo "=== Setting up Helm repos ==="
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update >/dev/null 2>&1

echo ""
echo "=== Creating namespaces ==="
kubectl create namespace "$DATA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$WEBAPP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$INTERNAL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Setting up PostgreSQL ==="
PG_PASSWORD=$(kubectl get secret postgres-postgresql -n "$DATA_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
if [ -z "$PG_PASSWORD" ]; then
  PG_PASSWORD=$(python3 -c "import secrets; print(secrets.token_hex(32))")
fi

helm upgrade --install postgres bitnami/postgresql -n "$DATA_NAMESPACE" \
  --set auth.username=cyberpulse \
  --set auth.password="$PG_PASSWORD" \
  --set auth.database=cyberpulse \
  --set pgpool.enabled=false \
  --set primary.resources.requests.cpu=250m \
  --set primary.resources.requests.memory=256Mi \
  --set primary.resources.limits.cpu=1000m \
  --set primary.resources.limits.memory=1Gi

wait_for_postgres

echo ""
echo "=== Configuring GHCR image pull credentials ==="
create_pull_secret "$WEBAPP_NAMESPACE"
create_pull_secret "$INTERNAL_NAMESPACE"

if [ "$ACCESS_MODE" = "cloudflare" ]; then
  echo ""
  echo "=== Configuring Cloudflare Tunnel credentials ==="
  create_cloudflare_tunnel_secret
fi

echo ""
echo "=== Configuring application secrets ==="
if ! kubectl get secret fastapi-encryption -n "$INTERNAL_NAMESPACE" >/dev/null 2>&1; then
  echo "First run - generating secrets..."

  if ! command -v openssl >/dev/null 2>&1; then
    echo "Missing required command: openssl" >&2
    exit 1
  fi
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/sp_private.pem >/dev/null 2>&1
  openssl rsa -in /tmp/sp_private.pem -pubout -out /tmp/sp_public.pem >/dev/null 2>&1

  JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  MFA_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  REDIS_PASSWORD=$(python3 -c "import secrets; print(secrets.token_hex(16))")

  kubectl create secret generic postgres-credentials \
    --namespace="$INTERNAL_NAMESPACE" \
    --from-literal=POSTGRES_USER=cyberpulse \
    --from-literal=POSTGRES_PASSWORD="$PG_PASSWORD" \
    --from-literal=POSTGRES_HOST=postgres-postgresql."$DATA_NAMESPACE".svc.cluster.local \
    --from-literal=POSTGRES_PORT=5432 \
    --from-literal=POSTGRES_DB=cyberpulse \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic jwt-secret \
    --namespace="$INTERNAL_NAMESPACE" \
    --from-literal=JWT_SECRET="$JWT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic mfa-secret \
    --namespace="$INTERNAL_NAMESPACE" \
    --from-literal=MFA_SECRET_KEY="$MFA_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic fastapi-encryption \
    --namespace="$INTERNAL_NAMESPACE" \
    --from-file=ENCRYPTION_PUBLIC_KEY=/tmp/sp_public.pem \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic fetcher-encryption \
    --namespace="$INTERNAL_NAMESPACE" \
    --from-file=ENCRYPTION_PRIVATE_KEY=/tmp/sp_private.pem \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic redis-credentials \
    --namespace="$INTERNAL_NAMESPACE" \
    --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
    --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@redis.${INTERNAL_NAMESPACE}.svc.cluster.local:6379" \
    --dry-run=client -o yaml | kubectl apply -f -

  ENCRYPTION_PRIVATE_KEY=$(cat /tmp/sp_private.pem)
  ENCRYPTION_PUBLIC_KEY=$(cat /tmp/sp_public.pem)

  rm -f /tmp/sp_private.pem /tmp/sp_public.pem

  echo "Backing up non-registry secrets to $SECRETS_BACKUP..."
  cat > "$SECRETS_BACKUP" <<EOF
# CyberPulse Prod Secrets - generated $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# DO NOT commit this file to git
# GHCR credentials are stored only in Kubernetes image pull secrets.

[postgres-credentials]
POSTGRES_USER=cyberpulse
POSTGRES_PASSWORD=$PG_PASSWORD
POSTGRES_HOST=postgres-postgresql.$DATA_NAMESPACE.svc.cluster.local
POSTGRES_PORT=5432
POSTGRES_DB=cyberpulse

[jwt-secret]
JWT_SECRET=$JWT_SECRET

[mfa-secret]
MFA_SECRET_KEY=$MFA_SECRET_KEY

[fastapi-encryption]
ENCRYPTION_PUBLIC_KEY<<PUBLIC_KEY
$ENCRYPTION_PUBLIC_KEY
PUBLIC_KEY

[fetcher-encryption]
ENCRYPTION_PRIVATE_KEY<<PRIVATE_KEY
$ENCRYPTION_PRIVATE_KEY
PRIVATE_KEY

[redis-credentials]
REDIS_PASSWORD=$REDIS_PASSWORD
REDIS_URL=redis://:${REDIS_PASSWORD}@redis.$INTERNAL_NAMESPACE.svc.cluster.local:6379
EOF
  chmod 600 "$SECRETS_BACKUP"
  echo "Secrets backed up to $SECRETS_BACKUP"
else
  echo "Existing application secrets found; leaving them unchanged."
fi

if ! kubectl get secret mfa-secret -n "$INTERNAL_NAMESPACE" >/dev/null 2>&1; then
  echo "Generating missing MFA secret..."
  MFA_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  kubectl create secret generic mfa-secret \
    --namespace="$INTERNAL_NAMESPACE" \
    --from-literal=MFA_SECRET_KEY="$MFA_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  mkdir -p "$SECRETS_DIR"
  {
    echo ""
    echo "[mfa-secret]"
    echo "MFA_SECRET_KEY=$MFA_SECRET_KEY"
  } >> "$SECRETS_BACKUP"
  chmod 600 "$SECRETS_BACKUP"
fi

echo ""
echo "=== Deploying CyberPulse chart ==="
adopt_existing_cyberpulse_resources

helm_args=(
  upgrade --install "$RELEASE_NAME" "$CHART_DIR"
  --namespace "$INTERNAL_NAMESPACE"
  --set "images.prefix=$IMAGE_PREFIX"
  --set "images.tag=$IMAGE_TAG"
  --set "images.pullPolicy=$IMAGE_PULL_POLICY"
  --set "imagePullSecrets[0].name=$PULL_SECRET_NAME"
  --set "webapp.namespace=$WEBAPP_NAMESPACE"
  --set "fastapi.namespace=$INTERNAL_NAMESPACE"
  --set-string "fastapi.corsOrigins=$CYBERPULSE_CORS_ORIGINS_HELM"
  --set-string "fastapi.enableHsts=$CYBERPULSE_ENABLE_HSTS"
  --set "worker.namespace=$INTERNAL_NAMESPACE"
  --set "redis.namespace=$INTERNAL_NAMESPACE"
  --set "postgres.namespace=$DATA_NAMESPACE"
  --set "cloudflare.tunnel.tokenSecretName=$CLOUDFLARE_TUNNEL_SECRET_NAME"
  --set "cloudflare.tunnel.replicas=$CLOUDFLARE_TUNNEL_REPLICAS"
)

case "$ACCESS_MODE" in
  traefik)
    helm_args+=(--set "ingress.enabled=true" --set "cloudflare.tunnel.enabled=false")
    ;;
  cloudflare)
    helm_args+=(--set "ingress.enabled=false" --set "cloudflare.tunnel.enabled=true")
    ;;
  none)
    helm_args+=(--set "ingress.enabled=false" --set "cloudflare.tunnel.enabled=false")
    ;;
esac

if [ -n "$VALUES_FILE" ]; then
  helm_args+=(--values "$VALUES_FILE")
fi

helm "${helm_args[@]}"

echo ""
echo "=== Waiting for rollout ==="
kubectl rollout status deployment webapp -n "$WEBAPP_NAMESPACE" --timeout=120s
kubectl rollout status deployment fastapi -n "$INTERNAL_NAMESPACE" --timeout=120s
kubectl rollout status deployment worker -n "$INTERNAL_NAMESPACE" --timeout=120s
if [ "$ACCESS_MODE" = "cloudflare" ]; then
  kubectl rollout status deployment cloudflared -n "$WEBAPP_NAMESPACE" --timeout=120s
fi

echo ""
echo "Ready!"
