#!/usr/bin/env bash
set -euo pipefail

# Tests for environment values handling in kustomize-edit
#
# Run: bash kustomize-edit/test_environment_values.sh

PASS=0
FAIL=0
TESTS=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/tests/environment-values"

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

assert_file_exists() {
  local label="$1" path="$2"
  TESTS=$((TESTS + 1))
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label"
    echo "    file not found: $path"
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  TESTS=$((TESTS + 1))
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label"
    echo "    file should not exist: $path"
  fi
}

# Copy a fixture to a temp directory and return the overlay path
setup_fixture() {
  local fixture_name="$1"
  local test_dir="$TMPDIR/${fixture_name}_$$_${TESTS}"
  cp -r "$FIXTURES_DIR/$fixture_name" "$test_dir"
  echo "$test_dir/overlay"
}

# ============================================================
# The function under test — mirrors the "Apply environment values" step
# ============================================================

# Helper: look up a host mapping from a mappings file
lookup_host_mapping() {
  local host="$1" mappings_file="$2"
  grep "^${host}=" "$mappings_file" 2>/dev/null | head -1 | cut -d= -f2-
}

apply_environment_values() {
  local overlay_dir="$1"
  local env_file="${2:-environment-values.env}"
  local prefix="${3:-}"

  # Redirect GITHUB_OUTPUT to a temp file for testing
  local github_output="$TMPDIR/github_output_$$_${TESTS}"
  export GITHUB_OUTPUT="$github_output"
  > "$github_output"

  (
    set -euo pipefail

    OVERLAY_DIR="$overlay_dir"
    ENV_FILE_NAME="$env_file"
    ENV_FILE_PATH="${OVERLAY_DIR}/${ENV_FILE_NAME}"
    PREFIX="$prefix"

    if [ -z "$PREFIX" ]; then
      PREFIX="skyhook-$(openssl rand -hex 4)-"
    fi

    if [ ! -f "$ENV_FILE_PATH" ]; then
      echo "applied_keys=" >> "$GITHUB_OUTPUT"
      echo "skipped_keys=" >> "$GITHUB_OUTPUT"
      exit 0
    fi

    # Parse env file (skip comments, blanks, malformed lines)
    ENV_PARSED=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
      [[ -z "$line" || "$line" == \#* ]] && continue
      # Skip lines without =
      if [[ "$line" != *"="* ]]; then
        continue
      fi
      # Skip lines with empty key
      _key="${line%%=*}"
      if [ -z "$_key" ]; then
        continue
      fi
      echo "$line" >> "$ENV_PARSED"
    done < "$ENV_FILE_PATH"

    ENV_KEY_COUNT=$(wc -l < "$ENV_PARSED" | tr -d ' ')
    if [ "$ENV_KEY_COUNT" = "0" ]; then
      echo "applied_keys=" >> "$GITHUB_OUTPUT"
      echo "skipped_keys=" >> "$GITHUB_OUTPUT"
      rm -f "$ENV_PARSED"
      exit 0
    fi

    # Idempotency cleanup
    cd "$OVERLAY_DIR"
    if [ -z "$PREFIX" ]; then
      echo "ERROR: prefix is empty" >&2
      exit 1
    fi
    rm -f ${PREFIX}*.yaml 2>/dev/null || true
    export YQ_PREFIX="$PREFIX"
    if yq -e '.patches' kustomization.yaml >/dev/null 2>&1; then
      yq -i 'del(.patches[] | select(.path | test("^" + env(YQ_PREFIX))))' kustomization.yaml 2>/dev/null || true
      PATCH_COUNT=$(yq '.patches | length' kustomization.yaml 2>/dev/null || echo "0")
      if [ "$PATCH_COUNT" = "0" ]; then
        yq -i 'del(.patches)' kustomization.yaml 2>/dev/null || true
      fi
    fi

    # Resource discovery
    RESOURCES_FILE=$(mktemp)

    BUILD_OUTPUT=$(kustomize build . 2>/dev/null || echo "")
    if [ -n "$BUILD_OUTPUT" ]; then
      TEMP_DIR=$(mktemp -d)
      echo "$BUILD_OUTPUT" | yq -s "\"${TEMP_DIR}/doc_\" + \$index" 2>/dev/null || true
      for doc_file in "$TEMP_DIR"/doc_*; do
        [ -f "$doc_file" ] || continue
        kind=$(yq '.kind // ""' "$doc_file")
        name=$(yq '.metadata.name // ""' "$doc_file")
        if [ "$kind" = "Ingress" ]; then
          rule_count=$(yq '.spec.rules | length' "$doc_file")
          has_tls=$(yq 'select(.spec.tls) | .spec.tls | length > 0' "$doc_file" 2>/dev/null || echo "false")
          [ -z "$has_tls" ] && has_tls="false"
          hosts=$(yq -r '[.spec.rules[].host] | join(",")' "$doc_file")
          tls_hosts=$(yq -r '[.spec.tls[].hosts[]] | join(",")' "$doc_file" 2>/dev/null || echo "")
          echo "Ingress|${name}|${rule_count}|${has_tls}|${hosts}|${tls_hosts}" >> "$RESOURCES_FILE"
        elif [ "$kind" = "HTTPRoute" ]; then
          hostnames=$(yq -r '[.spec.hostnames[]] | join(",")' "$doc_file")
          hostname_count=$(yq '.spec.hostnames | length' "$doc_file")
          echo "HTTPRoute|${name}|${hostname_count}|false|${hostnames}|" >> "$RESOURCES_FILE"
        fi
      done
      rm -rf "$TEMP_DIR"
    fi

    # File scan fallback
    RESOURCE_COUNT=$(wc -l < "$RESOURCES_FILE" | tr -d ' ')
    if [ "$RESOURCE_COUNT" = "0" ]; then
      scan_yaml_files() {
        local dir="$1"
        local kfile="$dir/kustomization.yaml"
        [ -f "$kfile" ] || return 0
        for field in resources components bases; do
          local paths
          paths=$(yq ".$field // [] | .[]" "$kfile" 2>/dev/null || true)
          while IFS= read -r p; do
            [ -z "$p" ] && continue
            local full_path="$dir/$p"
            if [ -d "$full_path" ]; then
              scan_yaml_files "$full_path"
            elif [ -f "$full_path" ]; then
              local fkind fname
              fkind=$(yq '.kind // ""' "$full_path" 2>/dev/null || echo "")
              fname=$(yq '.metadata.name // ""' "$full_path" 2>/dev/null || echo "")
              if [ "$fkind" = "Ingress" ]; then
                local frule_count fhas_tls fhosts ftls_hosts
                frule_count=$(yq '.spec.rules | length' "$full_path")
                fhas_tls=$(yq 'select(.spec.tls) | .spec.tls | length > 0' "$full_path" 2>/dev/null || echo "false")
                [ -z "$fhas_tls" ] && fhas_tls="false"
                fhosts=$(yq -r '[.spec.rules[].host] | join(",")' "$full_path")
                ftls_hosts=$(yq -r '[.spec.tls[].hosts[]] | join(",")' "$full_path" 2>/dev/null || echo "")
                echo "Ingress|${fname}|${frule_count}|${fhas_tls}|${fhosts}|${ftls_hosts}" >> "$RESOURCES_FILE"
              elif [ "$fkind" = "HTTPRoute" ]; then
                local fhostnames fhostname_count
                fhostnames=$(yq -r '[.spec.hostnames[]] | join(",")' "$full_path")
                fhostname_count=$(yq '.spec.hostnames | length' "$full_path")
                echo "HTTPRoute|${fname}|${fhostname_count}|false|${fhostnames}|" >> "$RESOURCES_FILE"
              fi
            fi
          done <<< "$paths"
        done
      }
      scan_yaml_files "."
    fi

    RESOURCE_COUNT=$(wc -l < "$RESOURCES_FILE" | tr -d ' ')

    # Key handlers
    APPLIED_KEYS=""
    SKIPPED_KEYS=""

    while IFS= read -r env_line || [ -n "$env_line" ]; do
      key="${env_line%%=*}"
      value="${env_line#*=}"

      case "$key" in
        EXTERNAL_HOST)
          MAPPING_MODE=false
          SIMPLE_HOST=""
          MAPPINGS_FILE=""
          if [[ "$value" == *"->"* ]]; then
            MAPPING_MODE=true
            MAPPINGS_FILE=$(mktemp)
            IFS=',' read -ra PAIRS <<< "$value"
            for pair in "${PAIRS[@]}"; do
              old_host="${pair%%->*}"
              new_host="${pair#*->}"
              echo "${old_host}=${new_host}" >> "$MAPPINGS_FILE"
            done
          else
            SIMPLE_HOST="$value"
          fi

          while IFS='|' read -r kind name count has_tls hosts tls_hosts; do
            [ -z "$kind" ] && continue

            if [ "$kind" = "Ingress" ]; then
              PATCH_FILE="${PREFIX}ingress-${name}.yaml"
              OPS="[]"

              IFS=',' read -ra HOST_ARRAY <<< "$hosts"
              idx=0
              for current_host in "${HOST_ARRAY[@]}"; do
                if [ "$MAPPING_MODE" = true ]; then
                  mapped=$(lookup_host_mapping "$current_host" "$MAPPINGS_FILE")
                  if [ -n "$mapped" ]; then
                    OPS=$(echo "$OPS" | jq --arg path "/spec/rules/$idx/host" --arg val "$mapped" '. + [{"op":"replace","path":$path,"value":$val}]')
                  fi
                else
                  OPS=$(echo "$OPS" | jq --arg path "/spec/rules/$idx/host" --arg val "$SIMPLE_HOST" '. + [{"op":"replace","path":$path,"value":$val}]')
                fi
                idx=$((idx + 1))
              done

              if [ "$has_tls" = "true" ] && [ -n "$tls_hosts" ]; then
                IFS=',' read -ra TLS_HOST_ARRAY <<< "$tls_hosts"
                tls_idx=0
                for current_host in "${TLS_HOST_ARRAY[@]}"; do
                  if [ "$MAPPING_MODE" = true ]; then
                    mapped=$(lookup_host_mapping "$current_host" "$MAPPINGS_FILE")
                    if [ -n "$mapped" ]; then
                      OPS=$(echo "$OPS" | jq --arg path "/spec/tls/0/hosts/$tls_idx" --arg val "$mapped" '. + [{"op":"replace","path":$path,"value":$val}]')
                    fi
                  else
                    OPS=$(echo "$OPS" | jq --arg path "/spec/tls/0/hosts/$tls_idx" --arg val "$SIMPLE_HOST" '. + [{"op":"replace","path":$path,"value":$val}]')
                  fi
                  tls_idx=$((tls_idx + 1))
                done
              fi

              if [ "$(echo "$OPS" | jq 'length')" -gt 0 ]; then
                echo "$OPS" | yq -P '.' > "$PATCH_FILE"
                export YQ_PATCH_PATH="$PATCH_FILE"
                export YQ_TARGET_KIND="Ingress"
                export YQ_TARGET_NAME="$name"
                yq -i '.patches += [{"path": env(YQ_PATCH_PATH), "target": {"kind": env(YQ_TARGET_KIND), "name": env(YQ_TARGET_NAME)}}]' kustomization.yaml
              fi

            elif [ "$kind" = "HTTPRoute" ]; then
              PATCH_FILE="${PREFIX}httproute-${name}.yaml"
              if [ "$MAPPING_MODE" = true ]; then
                OPS="[]"
                IFS=',' read -ra HOST_ARRAY <<< "$hosts"
                idx=0
                for current_host in "${HOST_ARRAY[@]}"; do
                  mapped=$(lookup_host_mapping "$current_host" "$MAPPINGS_FILE")
                  if [ -n "$mapped" ]; then
                    OPS=$(echo "$OPS" | jq --arg path "/spec/hostnames/$idx" --arg val "$mapped" '. + [{"op":"replace","path":$path,"value":$val}]')
                  fi
                  idx=$((idx + 1))
                done
                if [ "$(echo "$OPS" | jq 'length')" -gt 0 ]; then
                  echo "$OPS" | yq -P '.' > "$PATCH_FILE"
                  export YQ_PATCH_PATH="$PATCH_FILE"
                  export YQ_TARGET_KIND="HTTPRoute"
                  export YQ_TARGET_NAME="$name"
                  yq -i '.patches += [{"path": env(YQ_PATCH_PATH), "target": {"kind": env(YQ_TARGET_KIND), "name": env(YQ_TARGET_NAME)}}]' kustomization.yaml
                fi
              else
                printf 'apiVersion: gateway.networking.k8s.io/v1\nkind: HTTPRoute\nmetadata:\n  name: %s\nspec:\n  hostnames:\n  - %s\n' "$name" "$SIMPLE_HOST" > "$PATCH_FILE"
                export YQ_PATCH_PATH="$PATCH_FILE"
                export YQ_TARGET_KIND="HTTPRoute"
                export YQ_TARGET_NAME="$name"
                yq -i '.patches += [{"path": env(YQ_PATCH_PATH), "target": {"kind": env(YQ_TARGET_KIND), "name": env(YQ_TARGET_NAME)}}]' kustomization.yaml
              fi
            fi
          done < "$RESOURCES_FILE"

          [ -n "$MAPPINGS_FILE" ] && rm -f "$MAPPINGS_FILE"
          APPLIED_KEYS="${APPLIED_KEYS:+${APPLIED_KEYS},}EXTERNAL_HOST"
          ;;
        *)
          SKIPPED_KEYS="${SKIPPED_KEYS:+${SKIPPED_KEYS},}$key"
          ;;
      esac
    done < "$ENV_PARSED"

    rm -f "$ENV_PARSED" "$RESOURCES_FILE"

    echo "applied_keys=$APPLIED_KEYS" >> "$GITHUB_OUTPUT"
    echo "skipped_keys=$SKIPPED_KEYS" >> "$GITHUB_OUTPUT"
  )
  local exit_code=$?

  if [ -f "$TMPDIR/github_output_$$_${TESTS}" ]; then
    LAST_APPLIED_KEYS=$(grep '^applied_keys=' "$TMPDIR/github_output_$$_${TESTS}" | tail -1 | cut -d= -f2-)
    LAST_SKIPPED_KEYS=$(grep '^skipped_keys=' "$TMPDIR/github_output_$$_${TESTS}" | tail -1 | cut -d= -f2-)
  fi

  return $exit_code
}

# Global vars set by apply_environment_values
LAST_APPLIED_KEYS=""
LAST_SKIPPED_KEYS=""

# ============================================================
# TESTS
# ============================================================

echo ""
echo "=============================="
echo " ENVIRONMENT VALUES TESTS"
echo "=============================="

# ----------------------------------------------------------
echo ""
echo "=== Test 1: Single-rule Ingress — host replaced ==="
DIR=$(setup_fixture "ingress-single-rule")
apply_environment_values "$DIR" "environment-values.env" "test-"

BUILD=$(cd "$DIR" && kustomize build .)
INGRESS_HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
assert_eq "host replaced" "preview.myorg.dev" "$INGRESS_HOST"
assert_eq "applied keys" "EXTERNAL_HOST" "$LAST_APPLIED_KEYS"
assert_file_exists "patch file created" "$DIR/test-ingress-my-app.yaml"

# ----------------------------------------------------------
echo ""
echo "=== Test 2: Multi-rule Ingress — all rules patched ==="
DIR=$(setup_fixture "ingress-multi-rule")
apply_environment_values "$DIR" "environment-values.env" "test-"

BUILD=$(cd "$DIR" && kustomize build .)
HOST0=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
HOST1=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[1].host')
assert_eq "rule 0 host replaced" "preview.myorg.dev" "$HOST0"
assert_eq "rule 1 host replaced" "preview.myorg.dev" "$HOST1"

# ----------------------------------------------------------
echo ""
echo "=== Test 3: Ingress with TLS — both rules and tls patched ==="
DIR=$(setup_fixture "ingress-with-tls")
apply_environment_values "$DIR" "environment-values.env" "test-"

BUILD=$(cd "$DIR" && kustomize build .)
RULE_HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
TLS_HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.tls[0].hosts[0]')
assert_eq "rule host replaced" "preview.myorg.dev" "$RULE_HOST"
assert_eq "tls host replaced" "preview.myorg.dev" "$TLS_HOST"

# ----------------------------------------------------------
echo ""
echo "=== Test 4: HTTPRoute — all hostnames replaced ==="
DIR=$(setup_fixture "httproute")
apply_environment_values "$DIR" "environment-values.env" "test-"

BUILD=$(cd "$DIR" && kustomize build .)
HOSTNAME0=$(echo "$BUILD" | yq 'select(.kind == "HTTPRoute") | .spec.hostnames[0]')
assert_eq "hostname replaced" "preview.myorg.dev" "$HOSTNAME0"
# Strategic merge replaces entire hostnames array with single value
HOSTNAME_COUNT=$(echo "$BUILD" | yq 'select(.kind == "HTTPRoute") | .spec.hostnames | length')
assert_eq "hostname count is 1 (strategic merge)" "1" "$HOSTNAME_COUNT"

# ----------------------------------------------------------
echo ""
echo "=== Test 5: Both Ingress + HTTPRoute — both patched ==="
DIR=$(setup_fixture "both-ingress-httproute")
apply_environment_values "$DIR" "environment-values.env" "test-"

BUILD=$(cd "$DIR" && kustomize build .)
INGRESS_HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
HTTPROUTE_HOST=$(echo "$BUILD" | yq 'select(.kind == "HTTPRoute") | .spec.hostnames[0]')
assert_eq "ingress host replaced" "preview.myorg.dev" "$INGRESS_HOST"
assert_eq "httproute hostname replaced" "preview.myorg.dev" "$HTTPROUTE_HOST"

# ----------------------------------------------------------
echo ""
echo "=== Test 6: Mapping mode — only matching hosts changed ==="
DIR=$(setup_fixture "mapping-mode")
apply_environment_values "$DIR" "environment-values.env" "test-"

BUILD=$(cd "$DIR" && kustomize build .)
HOST0=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
HOST1=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[1].host')
assert_eq "api host mapped" "api.preview.com" "$HOST0"
assert_eq "web host mapped" "web.preview.com" "$HOST1"

# ----------------------------------------------------------
echo ""
echo "=== Test 7: Multiple Ingress resources — each gets own patch ==="
DIR=$(setup_fixture "multiple-ingress")
apply_environment_values "$DIR" "environment-values.env" "test-"

BUILD=$(cd "$DIR" && kustomize build .)
API_HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress" and .metadata.name == "api") | .spec.rules[0].host')
WEB_HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress" and .metadata.name == "web") | .spec.rules[0].host')
assert_eq "api ingress host replaced" "preview.myorg.dev" "$API_HOST"
assert_eq "web ingress host replaced" "preview.myorg.dev" "$WEB_HOST"
assert_file_exists "api patch file" "$DIR/test-ingress-api.yaml"
assert_file_exists "web patch file" "$DIR/test-ingress-web.yaml"

# ----------------------------------------------------------
echo ""
echo "=== Test 8: No Ingress/HTTPRoute — warning, no failure, key applied ==="
DIR=$(setup_fixture "no-resources")
apply_environment_values "$DIR" "environment-values.env" "test-"
EXIT=$?

assert_exit_code "exits 0" "0" "$EXIT"
assert_eq "applied keys includes EXTERNAL_HOST" "EXTERNAL_HOST" "$LAST_APPLIED_KEYS"

# ----------------------------------------------------------
echo ""
echo "=== Test 9: Idempotency — run twice, kustomize build identical ==="
DIR=$(setup_fixture "ingress-single-rule")
apply_environment_values "$DIR" "environment-values.env" "test-"
BUILD1=$(cd "$DIR" && kustomize build .)

# Run again with same prefix
apply_environment_values "$DIR" "environment-values.env" "test-"
BUILD2=$(cd "$DIR" && kustomize build .)

assert_eq "builds identical" "$BUILD1" "$BUILD2"
# Check no duplicate patches in kustomization.yaml
PATCH_COUNT=$(cd "$DIR" && yq '.patches | length' kustomization.yaml)
assert_eq "single patch entry (no duplicates)" "1" "$PATCH_COUNT"

# ----------------------------------------------------------
echo ""
echo "=== Test 10: Unrecognized key — in skipped_keys ==="
DIR=$(setup_fixture "ingress-single-rule")
echo "UNKNOWN_KEY=somevalue" >> "$DIR/environment-values.env"
apply_environment_values "$DIR" "environment-values.env" "test-"

assert_contains "applied contains EXTERNAL_HOST" "$LAST_APPLIED_KEYS" "EXTERNAL_HOST"
assert_contains "skipped contains UNKNOWN_KEY" "$LAST_SKIPPED_KEYS" "UNKNOWN_KEY"

# ----------------------------------------------------------
echo ""
echo "=== Test 11: No env file — exits 0, empty outputs ==="
DIR=$(setup_fixture "no-env-file")
apply_environment_values "$DIR" "environment-values.env" "test-"
EXIT=$?

assert_exit_code "exits 0" "0" "$EXIT"
assert_eq "applied keys empty" "" "$LAST_APPLIED_KEYS"
assert_eq "skipped keys empty" "" "$LAST_SKIPPED_KEYS"

# ----------------------------------------------------------
echo ""
echo "=== Test 12: Empty env file — exits 0 ==="
DIR=$(setup_fixture "empty-env-file")
apply_environment_values "$DIR" "environment-values.env" "test-"
EXIT=$?

assert_exit_code "exits 0" "0" "$EXIT"
assert_eq "applied keys empty" "" "$LAST_APPLIED_KEYS"

# ----------------------------------------------------------
echo ""
echo "=== Test 13: Patch files use correct prefix ==="
DIR=$(setup_fixture "ingress-single-rule")
apply_environment_values "$DIR" "environment-values.env" "myprefix-"

assert_file_exists "patch has correct prefix" "$DIR/myprefix-ingress-my-app.yaml"
assert_file_not_exists "no test- prefix files" "$DIR/test-ingress-my-app.yaml"

# ----------------------------------------------------------
echo ""
echo "=== Test 14: kustomization.yaml patches list correct ==="
DIR=$(setup_fixture "ingress-single-rule")
apply_environment_values "$DIR" "environment-values.env" "test-"

PATCH_PATH=$(cd "$DIR" && yq '.patches[0].path' kustomization.yaml)
PATCH_KIND=$(cd "$DIR" && yq '.patches[0].target.kind' kustomization.yaml)
PATCH_NAME=$(cd "$DIR" && yq '.patches[0].target.name' kustomization.yaml)
assert_eq "patch path" "test-ingress-my-app.yaml" "$PATCH_PATH"
assert_eq "patch target kind" "Ingress" "$PATCH_KIND"
assert_eq "patch target name" "my-app" "$PATCH_NAME"

# ----------------------------------------------------------
echo ""
echo "=== Test 15: End-to-end kustomize build validates ==="
for fixture in ingress-single-rule ingress-multi-rule ingress-with-tls httproute both-ingress-httproute mapping-mode multiple-ingress; do
  DIR=$(setup_fixture "$fixture")
  apply_environment_values "$DIR" "environment-values.env" "test-"
  BUILD_OUTPUT=$(cd "$DIR" && kustomize build . 2>&1)
  BUILD_EXIT=$?
  assert_exit_code "kustomize build succeeds for $fixture" "0" "$BUILD_EXIT"
done

# ============================================================
# BACKWARD COMPATIBILITY TESTS
# ============================================================

echo ""
echo "=============================="
echo " BACKWARD COMPATIBILITY TESTS"
echo "=============================="

# ----------------------------------------------------------
echo ""
echo "=== Test 16: Only unrecognized keys — no patches generated, no failure ==="
DIR=$(setup_fixture "only-unrecognized-keys")
apply_environment_values "$DIR" "environment-values.env" "test-"
EXIT=$?

assert_exit_code "exits 0" "0" "$EXIT"
assert_eq "applied keys empty" "" "$LAST_APPLIED_KEYS"
assert_contains "skipped contains DATABASE_URL" "$LAST_SKIPPED_KEYS" "DATABASE_URL"
assert_contains "skipped contains REDIS_HOST" "$LAST_SKIPPED_KEYS" "REDIS_HOST"
# Kustomize build should still work (no patches added)
BUILD_EXIT=0
cd "$DIR" && kustomize build . >/dev/null 2>&1 || BUILD_EXIT=$?
assert_exit_code "kustomize build still works" "0" "$BUILD_EXIT"
# Original host unchanged
BUILD=$(cd "$DIR" && kustomize build .)
ORIGINAL_HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
assert_eq "original host unchanged" "app.example.com" "$ORIGINAL_HOST"

# ----------------------------------------------------------
echo ""
echo "=== Test 17: Malformed lines — skipped gracefully, valid keys still work ==="
DIR=$(setup_fixture "malformed-lines")
apply_environment_values "$DIR" "environment-values.env" "test-"
EXIT=$?

assert_exit_code "exits 0" "0" "$EXIT"
assert_contains "applied contains EXTERNAL_HOST" "$LAST_APPLIED_KEYS" "EXTERNAL_HOST"
# Verify the host was actually replaced despite malformed lines
BUILD=$(cd "$DIR" && kustomize build .)
HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
assert_eq "host replaced despite malformed lines" "preview.myorg.dev" "$HOST"
# KEY_WITHOUT_VALUE should still be in skipped (empty value but valid format)
assert_contains "skipped contains KEY_WITHOUT_VALUE" "$LAST_SKIPPED_KEYS" "KEY_WITHOUT_VALUE"

# ----------------------------------------------------------
echo ""
echo "=== Test 18: Existing patches preserved — user patches not removed ==="
DIR=$(setup_fixture "existing-patches")
apply_environment_values "$DIR" "environment-values.env" "test-"
EXIT=$?

assert_exit_code "exits 0" "0" "$EXIT"
# Verify user's custom patch is still in kustomization.yaml
CUSTOM_PATCH=$(cd "$DIR" && yq '.patches[] | select(.path == "custom-patch.yaml") | .path' kustomization.yaml)
assert_eq "custom patch preserved" "custom-patch.yaml" "$CUSTOM_PATCH"
# Verify our patch was also added
OUR_PATCH=$(cd "$DIR" && yq '.patches[] | select(.path == "test-ingress-my-app.yaml") | .path' kustomization.yaml)
assert_eq "our patch added" "test-ingress-my-app.yaml" "$OUR_PATCH"
# Total patches should be 2 (custom + ours)
TOTAL_PATCHES=$(cd "$DIR" && yq '.patches | length' kustomization.yaml)
assert_eq "total patches is 2" "2" "$TOTAL_PATCHES"
# kustomize build should work
BUILD=$(cd "$DIR" && kustomize build .)
HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
assert_eq "host replaced" "preview.myorg.dev" "$HOST"

# ----------------------------------------------------------
echo ""
echo "=== Test 19: Values with equals signs — parsed correctly ==="
DIR=$(setup_fixture "values-with-equals")
apply_environment_values "$DIR" "environment-values.env" "test-"
EXIT=$?

assert_exit_code "exits 0" "0" "$EXIT"
assert_contains "applied contains EXTERNAL_HOST" "$LAST_APPLIED_KEYS" "EXTERNAL_HOST"
# SOME_CONFIG=key=value=extra is unrecognized → skipped
assert_contains "skipped contains SOME_CONFIG" "$LAST_SKIPPED_KEYS" "SOME_CONFIG"
# Host should be replaced
BUILD=$(cd "$DIR" && kustomize build .)
HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
assert_eq "host replaced despite equals in values" "preview.myorg.dev" "$HOST"

# ----------------------------------------------------------
echo ""
echo "=== Test 20: Existing kustomization fields preserved — images, namespace untouched ==="
DIR=$(setup_fixture "existing-kustomization-no-patches")
apply_environment_values "$DIR" "environment-values.env" "test-"
EXIT=$?

assert_exit_code "exits 0" "0" "$EXIT"
# Verify existing fields preserved
NAMESPACE=$(cd "$DIR" && yq '.namespace' kustomization.yaml)
assert_eq "namespace preserved" "production" "$NAMESPACE"
IMAGE_TAG=$(cd "$DIR" && yq '.images[0].newTag' kustomization.yaml)
assert_eq "image tag preserved" "v1.0.0" "$IMAGE_TAG"
# Verify host was replaced
BUILD=$(cd "$DIR" && kustomize build .)
HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
assert_eq "host replaced" "preview.myorg.dev" "$HOST"

# ----------------------------------------------------------
echo ""
echo "=== Test 21: Idempotency with existing patches — user patches survive re-runs ==="
DIR=$(setup_fixture "existing-patches")
apply_environment_values "$DIR" "environment-values.env" "test-"
# Run a second time
apply_environment_values "$DIR" "environment-values.env" "test-"

CUSTOM_PATCH=$(cd "$DIR" && yq '.patches[] | select(.path == "custom-patch.yaml") | .path' kustomization.yaml)
assert_eq "custom patch still there after re-run" "custom-patch.yaml" "$CUSTOM_PATCH"
TOTAL_PATCHES=$(cd "$DIR" && yq '.patches | length' kustomization.yaml)
assert_eq "total patches is 2 after re-run" "2" "$TOTAL_PATCHES"
BUILD=$(cd "$DIR" && kustomize build .)
HOST=$(echo "$BUILD" | yq 'select(.kind == "Ingress") | .spec.rules[0].host')
assert_eq "host correct after re-run" "preview.myorg.dev" "$HOST"

# ----------------------------------------------------------
echo ""
echo "=== Test 22: Default env file name — works when file doesn't exist ==="
DIR=$(setup_fixture "no-env-file")
# Call without explicit env file name (uses default)
apply_environment_values "$DIR"
EXIT=$?

assert_exit_code "exits 0 with default file name" "0" "$EXIT"
assert_eq "applied keys empty" "" "$LAST_APPLIED_KEYS"

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
