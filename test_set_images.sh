#!/usr/bin/env bash
set -euo pipefail

# TDD tests for yq-based image setting in kustomize-edit
#
# Tests the function set_images() which will replace the current
# kustomize edit set image approach with pure yq patching.
#
# Run: bash test_set_images.sh

PASS=0
FAIL=0
TESTS=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ============================================================
# Test helpers
# ============================================================

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TESTS=$((TESTS + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  TESTS=$((TESTS + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  TESTS=$((TESTS + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label"
    echo "    expected exit code: $expected"
    echo "    actual exit code:   $actual"
  fi
}

# Read a field from kustomization.yaml images entry by name
read_image_field() {
  local dir="$1" name="$2" field="$3"
  yq ".images[] | select(.name == \"$name\") | .$field // \"\"" "$dir/kustomization.yaml" 2>/dev/null || echo ""
}

# Count image entries
count_images() {
  local dir="$1"
  yq '.images | length' "$dir/kustomization.yaml" 2>/dev/null || echo "0"
}

# ============================================================
# Fixtures
# ============================================================

# Full image entry: name + newName + newTag
setup_with_newname() {
  local dir="$TMPDIR/$1"
  mkdir -p "$dir"
  cat > "$dir/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
images:
- name: mock-registry.example.io/my-api
  newName: 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api
  newTag: my-api_main_2026-03-19_01_01
YAML
  cat > "$dir/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
spec:
  selector:
    matchLabels:
      app: my-api
  template:
    metadata:
      labels:
        app: my-api
    spec:
      containers:
      - name: my-api
        image: mock-registry.example.io/my-api:latest
YAML
  echo "$dir"
}

# Image entry with digest instead of tag
setup_with_digest() {
  local dir="$TMPDIR/$1"
  mkdir -p "$dir"
  cat > "$dir/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
images:
- name: mock-registry.example.io/my-api
  newName: 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api
  digest: sha256:abc123def456
YAML
  cat > "$dir/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
spec:
  selector:
    matchLabels:
      app: my-api
  template:
    metadata:
      labels:
        app: my-api
    spec:
      containers:
      - name: my-api
        image: mock-registry.example.io/my-api:latest
YAML
  echo "$dir"
}

# Simple entry: name + newTag only
setup_simple() {
  local dir="$TMPDIR/$1"
  mkdir -p "$dir"
  cat > "$dir/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
images:
- name: my-api
  newTag: v1.0.0
YAML
  cat > "$dir/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
spec:
  selector:
    matchLabels:
      app: my-api
  template:
    metadata:
      labels:
        app: my-api
    spec:
      containers:
      - name: my-api
        image: my-api:latest
YAML
  echo "$dir"
}

# No images section at all
setup_no_images() {
  local dir="$TMPDIR/$1"
  mkdir -p "$dir"
  cat > "$dir/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
YAML
  cat > "$dir/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
spec:
  selector:
    matchLabels:
      app: my-api
  template:
    metadata:
      labels:
        app: my-api
    spec:
      containers:
      - name: my-api
        image: my-api:latest
YAML
  echo "$dir"
}

# Multiple images
setup_multi_image() {
  local dir="$TMPDIR/$1"
  mkdir -p "$dir"
  cat > "$dir/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
images:
- name: mock-registry.example.io/frontend
  newName: 111111111111.dkr.ecr.us-east-1.amazonaws.com/frontend
  newTag: v1.0.0
- name: mock-registry.example.io/backend
  newName: 222222222222.dkr.ecr.us-east-1.amazonaws.com/backend
  newTag: v2.0.0
YAML
  cat > "$dir/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: frontend
        image: mock-registry.example.io/frontend:latest
      - name: backend
        image: mock-registry.example.io/backend:latest
YAML
  echo "$dir"
}

# Kustomization with YAML comments
setup_with_comments() {
  local dir="$TMPDIR/$1"
  mkdir -p "$dir"
  cat > "$dir/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
# Image overrides for this environment
images:
# Primary API image
- name: mock-registry.example.io/my-api
  newName: 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api
  newTag: v1.0.0
YAML
  cat > "$dir/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
spec:
  selector:
    matchLabels:
      app: my-api
  template:
    metadata:
      labels:
        app: my-api
    spec:
      containers:
      - name: my-api
        image: mock-registry.example.io/my-api:latest
YAML
  echo "$dir"
}

# ============================================================
# The function under test — mirrors the "Set images" step logic.
# Uses yq-based patching for true PATCH semantics — only the
# fields you set are changed, everything else is preserved.
# ============================================================

yq_set_image() {
  local name="$1" new_tag="$2" new_name="${3:-}"

  export YQ_IMG_NAME="$name"
  export YQ_IMG_TAG="$new_tag"

  if yq -e ".images[] | select(.name == env(YQ_IMG_NAME))" kustomization.yaml >/dev/null 2>&1; then
    # Entry exists — patch only provided fields
    yq -i '(.images[] | select(.name == env(YQ_IMG_NAME))).newTag = env(YQ_IMG_TAG)' kustomization.yaml
    if [ -n "$new_name" ]; then
      export YQ_IMG_NEWNAME="$new_name"
      yq -i '(.images[] | select(.name == env(YQ_IMG_NAME))).newName = env(YQ_IMG_NEWNAME)' kustomization.yaml
    fi
  else
    # Entry doesn't exist — append
    if [ -n "$new_name" ]; then
      export YQ_IMG_NEWNAME="$new_name"
      yq -i '.images += [{"name": env(YQ_IMG_NAME), "newName": env(YQ_IMG_NEWNAME), "newTag": env(YQ_IMG_TAG)}]' kustomization.yaml
    else
      yq -i '.images += [{"name": env(YQ_IMG_NAME), "newTag": env(YQ_IMG_TAG)}]' kustomization.yaml
    fi
  fi
}

set_images() {
  local overlay_dir="$1" images_json="$2" single_image="$3" single_tag="$4"

  pushd "$overlay_dir" > /dev/null || return 1

  if [ -n "$images_json" ]; then
    if ! echo "$images_json" | jq empty 2>/dev/null; then
      echo "::error::Invalid images_json format" >&2
      popd > /dev/null
      return 1
    fi

    local entries
    entries=$(echo "$images_json" | jq -c '.[]')
    if [ -z "$entries" ]; then
      popd > /dev/null
      return 0
    fi
    local img NAME NEW_NAME NEW_TAG
    while IFS= read -r img; do
      NAME=$(echo "$img" | jq -r '.name // empty')
      NEW_NAME=$(echo "$img" | jq -r '.newName // empty')
      NEW_TAG=$(echo "$img" | jq -r '.newTag // empty')

      if [ -z "$NAME" ]; then
        echo "::error::Image entry missing 'name' field: $img" >&2
        popd > /dev/null
        return 1
      fi

      if [ -z "$NEW_TAG" ]; then
        echo "::error::Image entry missing 'newTag' field: $img" >&2
        popd > /dev/null
        return 1
      fi

      yq_set_image "$NAME" "$NEW_TAG" "$NEW_NAME"
    done <<< "$entries"
  elif [ -n "$single_image" ]; then
    yq_set_image "$single_image" "$single_tag"
  fi

  popd > /dev/null
}

# ============================================================
# SUCCESS TESTS
# ============================================================

echo ""
echo "=============================="
echo " SUCCESS CASES"
echo "=============================="

# ----------------------------------------------------------
echo ""
echo "=== Test 1: Single image — update tag, preserve existing newName ==="
DIR=$(setup_with_newname "s1")
set_images "$DIR" "" "mock-registry.example.io/my-api" "v2.0.0"

assert_eq "newName preserved" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "newTag updated" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"

# ----------------------------------------------------------
echo ""
echo "=== Test 2: images_json without newName — must preserve existing newName ==="
DIR=$(setup_with_newname "s2")
set_images "$DIR" '[{"name":"mock-registry.example.io/my-api","newTag":"v2.0.0"}]' "" ""

assert_eq "newName preserved" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "newTag updated" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"

# ----------------------------------------------------------
echo ""
echo "=== Test 3: images_json with newName — uses provided newName ==="
DIR=$(setup_with_newname "s3")
set_images "$DIR" '[{"name":"mock-registry.example.io/my-api","newName":"999999999999.dkr.ecr.us-east-1.amazonaws.com/my-api","newTag":"v2.0.0"}]' "" ""

assert_eq "newName updated to provided value" \
  "999999999999.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "newTag updated" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"

# ----------------------------------------------------------
echo ""
echo "=== Test 4: Single image — update tag, preserve existing digest ==="
DIR=$(setup_with_digest "s4")
set_images "$DIR" "" "mock-registry.example.io/my-api" "v2.0.0"

assert_eq "newName preserved" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "newTag set" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"
assert_eq "digest preserved" "sha256:abc123def456" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "digest")"

# ----------------------------------------------------------
echo ""
echo "=== Test 5: images_json without newName — preserve existing digest ==="
DIR=$(setup_with_digest "s5")
set_images "$DIR" '[{"name":"mock-registry.example.io/my-api","newTag":"v2.0.0"}]' "" ""

assert_eq "newName preserved" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "newTag set" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"
assert_eq "digest preserved" "sha256:abc123def456" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "digest")"

# ----------------------------------------------------------
echo ""
echo "=== Test 6: Simple entry — no newName to preserve, just update tag ==="
DIR=$(setup_simple "s6")
set_images "$DIR" '[{"name":"my-api","newTag":"v2.0.0"}]' "" ""

assert_eq "newTag updated" "v2.0.0" \
  "$(read_image_field "$DIR" "my-api" "newTag")"
assert_eq "no newName added" "" \
  "$(read_image_field "$DIR" "my-api" "newName")"

# ----------------------------------------------------------
echo ""
echo "=== Test 7: No existing images section — creates new entry ==="
DIR=$(setup_no_images "s7")
set_images "$DIR" '[{"name":"my-api","newTag":"v1.0.0"}]' "" ""

assert_eq "entry created with tag" "v1.0.0" \
  "$(read_image_field "$DIR" "my-api" "newTag")"
assert_eq "image count is 1" "1" "$(count_images "$DIR")"

# ----------------------------------------------------------
echo ""
echo "=== Test 8: Multiple images — update one, don't touch the other ==="
DIR=$(setup_multi_image "s8")
set_images "$DIR" '[{"name":"mock-registry.example.io/frontend","newTag":"v1.1.0"}]' "" ""

assert_eq "frontend newTag updated" "v1.1.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/frontend" "newTag")"
assert_eq "frontend newName preserved" \
  "111111111111.dkr.ecr.us-east-1.amazonaws.com/frontend" \
  "$(read_image_field "$DIR" "mock-registry.example.io/frontend" "newName")"
assert_eq "backend newTag untouched" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/backend" "newTag")"
assert_eq "backend newName untouched" \
  "222222222222.dkr.ecr.us-east-1.amazonaws.com/backend" \
  "$(read_image_field "$DIR" "mock-registry.example.io/backend" "newName")"
assert_eq "image count still 2" "2" "$(count_images "$DIR")"

# ----------------------------------------------------------
echo ""
echo "=== Test 9: Multiple images in images_json — update both ==="
DIR=$(setup_multi_image "s9")
set_images "$DIR" '[{"name":"mock-registry.example.io/frontend","newTag":"v1.1.0"},{"name":"mock-registry.example.io/backend","newTag":"v2.1.0"}]' "" ""

assert_eq "frontend newTag updated" "v1.1.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/frontend" "newTag")"
assert_eq "frontend newName preserved" \
  "111111111111.dkr.ecr.us-east-1.amazonaws.com/frontend" \
  "$(read_image_field "$DIR" "mock-registry.example.io/frontend" "newName")"
assert_eq "backend newTag updated" "v2.1.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/backend" "newTag")"
assert_eq "backend newName preserved" \
  "222222222222.dkr.ecr.us-east-1.amazonaws.com/backend" \
  "$(read_image_field "$DIR" "mock-registry.example.io/backend" "newName")"

# ----------------------------------------------------------
echo ""
echo "=== Test 10: Add new image entry alongside existing ones ==="
DIR=$(setup_with_newname "s10")
set_images "$DIR" '[{"name":"my-sidecar","newTag":"v1.0.0"}]' "" ""

assert_eq "new entry created" "v1.0.0" \
  "$(read_image_field "$DIR" "my-sidecar" "newTag")"
assert_eq "existing entry newName untouched" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "existing entry newTag untouched" \
  "my-api_main_2026-03-19_01_01" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"

# ----------------------------------------------------------
echo ""
echo "=== Test 11: YAML comments preserved after edit ==="
DIR=$(setup_with_comments "s11")
set_images "$DIR" '[{"name":"mock-registry.example.io/my-api","newTag":"v2.0.0"}]' "" ""

CONTENT=$(cat "$DIR/kustomization.yaml")
assert_contains "comment 'Image overrides' preserved" "$CONTENT" "# Image overrides for this environment"
assert_contains "comment 'Primary API' preserved" "$CONTENT" "# Primary API image"
assert_eq "newTag updated" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"
assert_eq "newName preserved" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"

# ----------------------------------------------------------
echo ""
echo "=== Test 12: kustomize build produces correct image after edit ==="
DIR=$(setup_with_newname "s12")
set_images "$DIR" '[{"name":"mock-registry.example.io/my-api","newTag":"v3.0.0"}]' "" ""

BUILD_IMAGE=$(cd "$DIR" && kustomize build . | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image')
assert_eq "build output uses real registry + new tag" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api:v3.0.0" \
  "$BUILD_IMAGE"

# ----------------------------------------------------------
echo ""
echo "=== Test 13: images_json overrides newName when explicitly provided ==="
DIR=$(setup_with_newname "s13")
set_images "$DIR" '[{"name":"mock-registry.example.io/my-api","newName":"new-ecr.example.com/my-api","newTag":"v2.0.0"}]' "" ""

assert_eq "newName changed to provided value" \
  "new-ecr.example.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"

# ----------------------------------------------------------
echo ""
echo "=== Test 14: Single image on simple entry — no newName to preserve ==="
DIR=$(setup_simple "s14")
set_images "$DIR" "" "my-api" "v3.0.0"

assert_eq "newTag updated" "v3.0.0" \
  "$(read_image_field "$DIR" "my-api" "newTag")"
assert_eq "no newName added" "" \
  "$(read_image_field "$DIR" "my-api" "newName")"

# ----------------------------------------------------------
echo ""
echo "=== Test 15: Single image, no existing entry — creates new ==="
DIR=$(setup_no_images "s15")
set_images "$DIR" "" "my-api" "v1.0.0"

assert_eq "entry created with tag" "v1.0.0" \
  "$(read_image_field "$DIR" "my-api" "newTag")"
assert_eq "image count is 1" "1" "$(count_images "$DIR")"

# ----------------------------------------------------------
echo ""
echo "=== Test 16: images_json adds newName to entry that had none ==="
DIR=$(setup_simple "s16")
set_images "$DIR" '[{"name":"my-api","newName":"ecr.example.com/my-api","newTag":"v2.0.0"}]' "" ""

assert_eq "newName set" "ecr.example.com/my-api" \
  "$(read_image_field "$DIR" "my-api" "newName")"
assert_eq "newTag updated" "v2.0.0" \
  "$(read_image_field "$DIR" "my-api" "newTag")"

# ----------------------------------------------------------
echo ""
echo "=== Test 17: images_json adds brand new image with newName ==="
DIR=$(setup_no_images "s17")
set_images "$DIR" '[{"name":"my-api","newName":"ecr.example.com/my-api","newTag":"v1.0.0"}]' "" ""

assert_eq "entry created with newName" "ecr.example.com/my-api" \
  "$(read_image_field "$DIR" "my-api" "newName")"
assert_eq "entry created with newTag" "v1.0.0" \
  "$(read_image_field "$DIR" "my-api" "newTag")"

# ----------------------------------------------------------
echo ""
echo "=== Test 18: images_json mixed — one existing, one new ==="
DIR=$(setup_with_newname "s18")
set_images "$DIR" '[{"name":"mock-registry.example.io/my-api","newTag":"v2.0.0"},{"name":"my-sidecar","newName":"ecr.example.com/sidecar","newTag":"v1.0.0"}]' "" ""

assert_eq "existing newTag updated" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"
assert_eq "existing newName preserved" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "new entry newName set" "ecr.example.com/sidecar" \
  "$(read_image_field "$DIR" "my-sidecar" "newName")"
assert_eq "new entry newTag set" "v1.0.0" \
  "$(read_image_field "$DIR" "my-sidecar" "newTag")"
assert_eq "image count is 2" "2" "$(count_images "$DIR")"

# ----------------------------------------------------------
echo ""
echo "=== Test 19: Empty images_json array — no-op ==="
DIR=$(setup_with_newname "s19")
set_images "$DIR" '[]' "" ""

assert_eq "newName untouched" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "newTag untouched" "my-api_main_2026-03-19_01_01" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"

# ----------------------------------------------------------
echo ""
echo "=== Test 20: Single image — update tag, preserve all fields (newName + digest) ==="
DIR="$TMPDIR/s20"
mkdir -p "$DIR"
cat > "$DIR/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
images:
- name: mock-registry.example.io/my-api
  newName: 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api
  newTag: v1.0.0
  digest: sha256:abc123
YAML
cat > "$DIR/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
spec:
  selector:
    matchLabels:
      app: my-api
  template:
    metadata:
      labels:
        app: my-api
    spec:
      containers:
      - name: my-api
        image: mock-registry.example.io/my-api:latest
YAML
set_images "$DIR" "" "mock-registry.example.io/my-api" "v2.0.0"

assert_eq "newName preserved" \
  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newName")"
assert_eq "newTag updated" "v2.0.0" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "newTag")"
assert_eq "digest preserved" "sha256:abc123" \
  "$(read_image_field "$DIR" "mock-registry.example.io/my-api" "digest")"

# ============================================================
# ERROR TESTS
# ============================================================

echo ""
echo "=============================="
echo " ERROR CASES"
echo "=============================="

# Disable set -e for error tests so we can capture exit codes
set +e

# ----------------------------------------------------------
echo ""
echo "=== Test 21: Invalid JSON — should fail ==="
DIR=$(setup_simple "e1")
OUTPUT=$(set_images "$DIR" 'not-valid-json' "" "" 2>&1)
EXIT_CODE=$?

assert_exit_code "exits with error" "1" "$EXIT_CODE"

# ----------------------------------------------------------
echo ""
echo "=== Test 22: Missing name field — should fail ==="
DIR=$(setup_simple "e2")
OUTPUT=$(set_images "$DIR" '[{"newTag":"v1.0.0"}]' "" "" 2>&1)
EXIT_CODE=$?

assert_exit_code "exits with error" "1" "$EXIT_CODE"
assert_contains "error mentions name" "$OUTPUT" "name"

# ----------------------------------------------------------
echo ""
echo "=== Test 23: Missing newTag field — should fail ==="
DIR=$(setup_simple "e3")
OUTPUT=$(set_images "$DIR" '[{"name":"my-api"}]' "" "" 2>&1)
EXIT_CODE=$?

assert_exit_code "exits with error" "1" "$EXIT_CODE"
assert_contains "error mentions newTag" "$OUTPUT" "newTag"

# Re-enable
set -e

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed (of $TESTS)"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
