#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BASE_DOMAIN="${BASE_DOMAIN:-portal.localhost}"
TRAEFIK_CLUSTER_IP="${TRAEFIK_CLUSTER_IP:-10.96.188.4}"
KCP_FRONT_PROXY_CLUSTER_IP="${KCP_FRONT_PROXY_CLUSTER_IP:-10.96.0.100}"
TRAEFIK_NODE_PORT="${TRAEFIK_NODE_PORT:-31000}"

TEMPLATE_DIR="$ROOT_DIR/local-setup2/templates"
GENERATED_DIR="$ROOT_DIR/local-setup2/.generated"
VALUES_OUT_DIR="$GENERATED_DIR/values"
MANIFESTS_OUT_DIR="$GENERATED_DIR/manifests"

mkdir -p "$VALUES_OUT_DIR" "$MANIFESTS_OUT_DIR"

command -v yq >/dev/null 2>&1 || {
  echo "yq is required" >&2
  exit 1
}

render() {
  local input="$1"
  local output="$2"

  sed \
    -e "s|__BASE_DOMAIN__|$BASE_DOMAIN|g" \
    -e "s|__TRAEFIK_CLUSTER_IP__|$TRAEFIK_CLUSTER_IP|g" \
    -e "s|__KCP_FRONT_PROXY_CLUSTER_IP__|$KCP_FRONT_PROXY_CLUSTER_IP|g" \
    -e "s|__TRAEFIK_NODE_PORT__|$TRAEFIK_NODE_PORT|g" \
    "$input" > "$output"
}

render "$TEMPLATE_DIR/helm-values.yaml.tmpl" "$GENERATED_DIR/helm-values.yaml"
render "$TEMPLATE_DIR/platform-mesh.yaml.tmpl" "$MANIFESTS_OUT_DIR/platform-mesh.yaml"
cp "$TEMPLATE_DIR/platform-mesh-profile.yaml" "$MANIFESTS_OUT_DIR/platform-mesh-profile.yaml"

rm -f "$VALUES_OUT_DIR"/*.yaml

while IFS= read -r key; do
  yq eval ".\"$key\"" "$GENERATED_DIR/helm-values.yaml" > "$VALUES_OUT_DIR/$key.yaml"
done < <(yq eval 'keys | .[]' "$GENERATED_DIR/helm-values.yaml")

echo "Rendered values into $VALUES_OUT_DIR"
echo "Rendered manifests into $MANIFESTS_OUT_DIR"
