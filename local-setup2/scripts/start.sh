#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-platform-mesh}"
BASE_DOMAIN="${BASE_DOMAIN:-portal.localhost}"
TRAEFIK_CLUSTER_IP="${TRAEFIK_CLUSTER_IP:-10.96.188.4}"
KCP_FRONT_PROXY_CLUSTER_IP="${KCP_FRONT_PROXY_CLUSTER_IP:-10.96.0.100}"
TRAEFIK_NODE_PORT="${TRAEFIK_NODE_PORT:-31000}"
PLATFORM_MESH_NAMESPACE="${PLATFORM_MESH_NAMESPACE:-platform-mesh-system}"
GENERATED_DIR="$ROOT_DIR/local-setup2/.generated"
CERTS_DIR="$GENERATED_DIR/certs"
KUBECONFIG_PATH="$GENERATED_DIR/kubeconfig"

export BASE_DOMAIN TRAEFIK_CLUSTER_IP KCP_FRONT_PROXY_CLUSTER_IP TRAEFIK_NODE_PORT KUBECONFIG_PATH

log() {
  echo "[$(date +%H:%M:%S)] $*"
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

kind_cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"
}

ensure_kind_cluster() {
  mkdir -p "$GENERATED_DIR"

  if kind_cluster_exists; then
    log "Reusing existing kind cluster $KIND_CLUSTER_NAME"
  else
    log "Creating kind cluster $KIND_CLUSTER_NAME"
    kind create cluster --name "$KIND_CLUSTER_NAME" --config "$ROOT_DIR/local-setup2/kind/kind-config.yaml"
  fi

  kind get kubeconfig --name "$KIND_CLUSTER_NAME" > "$KUBECONFIG_PATH"
  export KUBECONFIG="$KUBECONFIG_PATH"
}

ensure_certs() {
  mkdir -p "$CERTS_DIR"

  if [[ -s "$CERTS_DIR/cert.crt" && -s "$CERTS_DIR/cert.key" && -s "$CERTS_DIR/ca.crt" ]]; then
    log "Reusing existing local certificates"
    return
  fi

  log "Generating local certificates with mkcert"
  local caroot
  caroot="$(mkcert -CAROOT)"
  mkcert \
    -cert-file "$CERTS_DIR/cert.crt" \
    -key-file "$CERTS_DIR/cert.key" \
    "$BASE_DOMAIN" \
    "*.$BASE_DOMAIN" \
    "*.services.$BASE_DOMAIN" \
    localhost \
    "*.localhost" >/dev/null

  cp "$caroot/rootCA.pem" "$CERTS_DIR/ca.crt"
}

apply_domain_secrets() {
  log "Applying domain certificate secrets"

  kubectl create namespace "$PLATFORM_MESH_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl create secret generic domain-certificate -n default \
    --from-file=tls.crt="$CERTS_DIR/cert.crt" \
    --from-file=tls.key="$CERTS_DIR/cert.key" \
    --from-file=ca.crt="$CERTS_DIR/ca.crt" \
    --type=kubernetes.io/tls --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl create secret generic domain-certificate -n "$PLATFORM_MESH_NAMESPACE" \
    --from-file=tls.crt="$CERTS_DIR/cert.crt" \
    --from-file=tls.key="$CERTS_DIR/cert.key" \
    --from-file=ca.crt="$CERTS_DIR/ca.crt" \
    --type=kubernetes.io/tls --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl create secret generic domain-certificate-ca -n "$PLATFORM_MESH_NAMESPACE" \
    --from-file=tls.crt="$CERTS_DIR/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

apply_ocm_crds() {
  local ocm_crd_dir="$ROOT_DIR/hack/xrstf/ocmcrds/cluster"

  [[ -d "$ocm_crd_dir" ]] || die "OCM CRD directory not found: $ocm_crd_dir"

  log "Applying OCM CRDs"
  kubectl apply -f "$ocm_crd_dir"
}

wait_secret() {
  local namespace="$1"
  local name="$2"
  local timeout_secs="${3:-600}"

  log "Waiting for secret/$name in namespace/$namespace"
  for ((i=0; i<timeout_secs; i++)); do
    if kubectl -n "$namespace" get secret "$name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  die "Timed out waiting for secret/$name in namespace/$namespace"
}

wait_deployments_by_instance() {
  local namespace="$1"
  local instance="$2"
  local timeout_secs="${3:-300}"

  log "Waiting for deployments with app.kubernetes.io/instance=$instance in namespace/$namespace"

  local deployments=""
  for ((i=0; i<timeout_secs; i++)); do
    deployments="$(kubectl -n "$namespace" get deploy -l app.kubernetes.io/instance="$instance" -o name 2>/dev/null || true)"
    if [[ -n "$deployments" ]]; then
      break
    fi
    sleep 1
  done

  [[ -n "$deployments" ]] || die "Timed out waiting for deployments of instance $instance in namespace/$namespace"

  while IFS= read -r deployment; do
    [[ -n "$deployment" ]] || continue
    kubectl -n "$namespace" wait --for=condition=Available "$deployment" --timeout="${timeout_secs}s"
  done <<< "$deployments"
}

wait_opentelemetry_webhook_ready() {
  local namespace="$1"
  local timeout_secs="${2:-300}"

  log "Waiting for OpenTelemetryCollector admission webhook to become usable"

  for ((i=0; i<timeout_secs; i++)); do
    if cat <<EOF | kubectl apply --dry-run=server -f - >/dev/null 2>&1
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: webhook-readiness-probe
  namespace: $namespace
spec:
  mode: deployment
  config:
    receivers:
      otlp:
        protocols:
          grpc: {}
    processors:
      batch: {}
    exporters:
      debug: {}
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
EOF
    then
      return 0
    fi

    sleep 1
  done

  die "Timed out waiting for OpenTelemetryCollector admission webhook readiness"
}

helm_install() {
  local release="$1"
  local namespace="$2"
  local chart="$3"
  local version="$4"
  local values_file="$5"

  local cmd=(helm upgrade --install "$release" "$chart" --namespace "$namespace" --create-namespace --timeout 15m)

  if [[ -n "$version" ]]; then
    cmd+=(--version "$version")
  fi

  if [[ -n "$values_file" && -f "$values_file" ]]; then
    cmd+=(-f "$values_file")
  fi

  if [[ "$chart" != oci://* ]]; then
    cmd+=(--dependency-update)
  fi

  log "Installing $release from $chart"
  "${cmd[@]}"
}

create_kcp_webhook_secret() {
  log "Creating kcp-webhook-secret from rebac webhook serving CA"

  local ca
  ca="$(kubectl -n "$PLATFORM_MESH_NAMESPACE" get secret rebac-authz-webhook-cert -o jsonpath='{.data.ca\.crt}')"
  [[ -n "$ca" ]] || die "rebac-authz-webhook-cert does not contain ca.crt"

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: kcp-webhook-secret
  namespace: $PLATFORM_MESH_NAMESPACE
type: Opaque
stringData:
  kubeconfig: |
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: $ca
        server: https://rebac-authz-webhook.platform-mesh-system.svc.cluster.local:9443/authz
      name: webhook
    contexts:
    - context:
        cluster: webhook
      name: webhook
    current-context: webhook
    kind: Config
EOF
}

apply_platform_mesh_manifests() {
  log "Applying PlatformMesh bootstrap resources"
  kubectl apply -f "$GENERATED_DIR/manifests/platform-mesh-profile.yaml"
  kubectl apply -f "$GENERATED_DIR/manifests/platform-mesh.yaml"
}

install_foundation() {
  local values_dir="$GENERATED_DIR/values"

  helm_install gateway-api-crds default "$ROOT_DIR/charts/gateway-api-crds" "" ""
  helm_install cert-manager default oci://quay.io/jetstack/charts/cert-manager v1.20.1 "$values_dir/cert-manager.yaml"
  helm_install traefik-crds default oci://ghcr.io/platform-mesh/ocm/charts/traefik-crds 1.14.0 ""
  helm_install traefik default oci://ghcr.io/platform-mesh/charts/traefik 41.4.0 "$values_dir/traefik.yaml"
  helm_install cnpg-operator "$PLATFORM_MESH_NAMESPACE" oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg 0.28.0 ""
  helm_install keycloak-operator "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/keycloak-operator" "" ""
  helm_install kcp-operator kcp-operator oci://ghcr.io/platform-mesh/helm-charts/charts/mirrored/kcp-operator 0.7.4 ""
  helm_install etcd-druid etcd-druid-system oci://europe-docker.pkg.dev/gardener-project/releases/charts/gardener/etcd-druid v0.36.4 ""
  helm_install prometheus-operator-crds observability oci://ghcr.io/platform-mesh/ocm/charts/prometheus-operator-crds 29.0.0 ""
  helm_install opentelemetry-operator observability oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-operator 0.114.1 "$values_dir/opentelemetry-operator.yaml"
  wait_deployments_by_instance observability opentelemetry-operator 300
  wait_opentelemetry_webhook_ready observability 300
  helm_install observability observability "$ROOT_DIR/charts/observability" "" "$values_dir/observability.yaml"
  helm_install openfga "$PLATFORM_MESH_NAMESPACE" oci://ghcr.io/platform-mesh/ocm/charts/openfga 0.2.62 "$values_dir/openfga.yaml"
  helm_install rebac-authz-webhook "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/rebac-authz-webhook" "" "$values_dir/rebac-authz-webhook.yaml"
  helm_install infra "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/infra" "" "$values_dir/infra.yaml"
  helm_install platform-mesh-operator "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/platform-mesh-operator" "" "$values_dir/platform-mesh-operator.yaml"

  kubectl wait --for=condition=Established crd/platformmeshes.core.platform-mesh.io --timeout=300s
  wait_secret "$PLATFORM_MESH_NAMESPACE" rebac-authz-webhook-cert 600
  create_kcp_webhook_secret
}

install_platform_components() {
  local values_dir="$GENERATED_DIR/values"

  helm_install account-operator "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/account-operator" "" "$values_dir/account-operator.yaml"
  helm_install extension-manager-operator "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/extension-manager-operator" "" "$values_dir/extension-manager-operator.yaml"
  helm_install iam-service "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/iam-service" "" "$values_dir/iam-service.yaml"
  helm_install iam-ui "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/iam-ui" "" "$values_dir/iam-ui.yaml"
  helm_install init-agent "$PLATFORM_MESH_NAMESPACE" oci://ghcr.io/platform-mesh/ocm/charts/init-agent 0.2.0 "$values_dir/init-agent.yaml"
  helm_install kubernetes-graphql-gateway "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/kubernetes-graphql-gateway" "" "$values_dir/kubernetes-graphql-gateway.yaml"
  helm_install marketplace-ui "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/marketplace-ui" "" "$values_dir/marketplace-ui.yaml"
  helm_install portal "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/portal" "" "$values_dir/portal.yaml"
  helm_install security-operator "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/security-operator" "" "$values_dir/security-operator.yaml"
  helm_install virtual-workspaces "$PLATFORM_MESH_NAMESPACE" "$ROOT_DIR/charts/virtual-workspaces" "" "$values_dir/virtual-workspaces.yaml"
}

main() {
  need kind
  need kubectl
  need helm
  need mkcert
  need yq
  need openssl

  ensure_kind_cluster
  ensure_certs
  apply_domain_secrets
  apply_ocm_crds
  "$ROOT_DIR/local-setup2/scripts/create-secrets.sh"
  "$ROOT_DIR/local-setup2/scripts/render-values.sh"

  install_foundation
  apply_platform_mesh_manifests
  install_platform_components

  log "local-setup2 bootstrap finished"
  echo
  echo "KUBECONFIG=$KUBECONFIG_PATH"
  echo "Portal: https://$BASE_DOMAIN:8443"
  echo
  echo "Useful checks:"
  echo "  kubectl get pods -A"
  echo "  kubectl -n $PLATFORM_MESH_NAMESPACE get platformmesh platform-mesh -o yaml"
}

main "$@"
