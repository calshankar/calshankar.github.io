#!/usr/bin/env bash
# Compare CRDs between two Git tags/versions (OLD_VER → NEW_VER) using crdify,
# with optional Pluto and kubeconform validation gates on fixtures. This script assumes all the tools used are installed and available in PATH.
#
# Examples:
#   OLD_VER=0.15.1 NEW_VER=0.16.1 src/content/scripts/crd-compat.sh
#   src/content/scripts/crd-compat.sh --old 0.15.1 --new 0.16.1
#   src/content/scripts/crd-compat.sh --old 0.15.1 --new 0.16.1 --run-pluto --run-kubeconform
#   src/content/scripts/crd-compat.sh --repo https://github.com/my-org/my-repo.git --crd-dir config/crd/bases --old v1.0.0 --new v1.1.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO_URL="${REPO_URL:-https://github.com/external-secrets/external-secrets.git}"
CRD_DIR="${CRD_DIR:-config/crds/bases}"
TAG_PREFIX="${TAG_PREFIX:-helm-chart-}"
OLD_VER="${OLD_VER:-}"
NEW_VER="${NEW_VER:-}"
WORKDIR="${WORKDIR:-${CONTENT_ROOT}/.crd-compat/work}"
FIXTURE_DIR="${FIXTURE_DIR:-${CONTENT_ROOT}/manifests/eso}"
SCHEMA_DIR="${SCHEMA_DIR:-}"
RUN_PLUTO="${RUN_PLUTO:-false}"
RUN_KUBECONFORM="${RUN_KUBECONFORM:-false}"
OPENAPI2JSONSCHEMA="${OPENAPI2JSONSCHEMA:-}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.6.7}"

OLD_CRDS_IDX="${WORKDIR}/old_crds"
NEW_CRDS_IDX="${WORKDIR}/new_crds"

print_usage() {
  cat << 'EOF'
Usage: crd-compat.sh [OPTIONS] [OLD_VER] [NEW_VER]

Compares Kubernetes CRD schemas between two release tags/versions using shallow git clone and crdify.
Optionally runs Pluto deprecation and kubeconform instance schema gates on test fixtures.

Options:
  --repo <url>            Git repository URL hosting CRD source (default: https://github.com/external-secrets/external-secrets.git)
  --crd-dir <path>        Relative path to directory hosting rendered CRD YAMLs (default: config/crds/bases)
  --tag-prefix <pfx>      Prefix for version tags (default: helm-chart-)
  --old, --old-ver        Old version or Git tag (e.g. 0.15.1 or helm-chart-0.15.1)
  --new, --new-ver        New version or Git tag (e.g. 0.16.1 or helm-chart-0.16.1)
  --workdir <dir>         Working directory for temporary clones (default: src/content/.crd-compat/work)
  --fixture-dir <dir>     Path to fixtures directory for Pluto/kubeconform (default: src/content/manifests/eso)
  --schema-dir <dir>      Path to JSON schema directory for kubeconform (default: <fixture-dir>/schemas)
  --openapi2jsonschema <path> Path to openapi2jsonschema.py script (default: discovered in PATH, or downloaded)
  --pluto, --run-pluto    Run Pluto deprecation checks on fixtures (default: disabled)
  --skip-pluto, --no-pluto Explicitly disable Pluto checks
  --kubeconform,          Run kubeconform schema validation on fixtures (default: disabled)
    --run-kubeconform
  --skip-kubeconform,     Explicitly disable kubeconform checks
    --no-kubeconform
  --all-gates             Enable both Pluto and kubeconform gates
  -h, --help              Show this help message

Environment variables (fallback):
  REPO_URL, CRD_DIR, TAG_PREFIX, OLD_VER, NEW_VER, WORKDIR, FIXTURE_DIR, SCHEMA_DIR,
  RUN_PLUTO, RUN_KUBECONFORM, OPENAPI2JSONSCHEMA, KUBECONFORM_VERSION

Examples:
  # Schema diff only (crdify):
  OLD_VER=0.15.1 NEW_VER=0.16.1 ./crd-compat.sh
  ./crd-compat.sh --old 0.15.1 --new 0.16.1

  # Schema diff + Pluto deprecation scan on fixtures:
  ./crd-compat.sh --old 0.15.1 --new 0.16.1 --run-pluto

  # Schema diff + all fixture gates (Pluto + kubeconform):
  ./crd-compat.sh --old 0.15.1 --new 0.16.1 --all-gates

  # Compare custom repository:
  ./crd-compat.sh --repo https://github.com/org/repo.git --crd-dir crds --old v1.0.0 --new v1.1.0
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_URL="$2"
      shift 2
      ;;
    --crd-dir)
      CRD_DIR="$2"
      shift 2
      ;;
    --tag-prefix)
      TAG_PREFIX="$2"
      shift 2
      ;;
    --old|--old-ver)
      OLD_VER="$2"
      shift 2
      ;;
    --new|--new-ver)
      NEW_VER="$2"
      shift 2
      ;;
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --fixture-dir)
      FIXTURE_DIR="$2"
      shift 2
      ;;
    --schema-dir)
      SCHEMA_DIR="$2"
      shift 2
      ;;
    --openapi2jsonschema)
      OPENAPI2JSONSCHEMA="$2"
      shift 2
      ;;
    --pluto|--run-pluto)
      RUN_PLUTO="true"
      shift
      ;;
    --no-pluto|--skip-pluto)
      RUN_PLUTO="false"
      shift
      ;;
    --kubeconform|--run-kubeconform)
      RUN_KUBECONFORM="true"
      shift
      ;;
    --no-kubeconform|--skip-kubeconform)
      RUN_KUBECONFORM="false"
      shift
      ;;
    --all-gates)
      RUN_PLUTO="true"
      RUN_KUBECONFORM="true"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      if [[ -z "${OLD_VER}" ]]; then
        OLD_VER="$1"
        shift
      elif [[ -z "${NEW_VER}" ]]; then
        NEW_VER="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        print_usage
        exit 2
      fi
      ;;
  esac
done

SCHEMA_DIR="${SCHEMA_DIR:-${FIXTURE_DIR}/schemas}"

command -v git >/dev/null || { echo "git required" >&2; exit 2; }
command -v crdify >/dev/null || { echo "crdify required: go install sigs.k8s.io/crdify@latest" >&2; exit 2; }

if [[ "${RUN_PLUTO}" == "true" ]]; then
  command -v pluto >/dev/null || { echo "pluto required to run Pluto gate: https://github.com/FairwindsOps/pluto" >&2; exit 2; }
fi

if [[ "${RUN_KUBECONFORM}" == "true" ]]; then
  command -v kubeconform >/dev/null || { echo "kubeconform required to run kubeconform gate: https://github.com/yannh/kubeconform" >&2; exit 2; }
  command -v python3 >/dev/null || { echo "python3 required to run openapi2jsonschema.py for kubeconform" >&2; exit 2; }
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "Python package 'yaml' (PyYAML) is required for openapi2jsonschema.py. Install via: pip install pyyaml" >&2
    exit 2
  fi
fi

if [[ -z "${OLD_VER}" || -z "${NEW_VER}" ]]; then
  echo "Error: OLD_VER and NEW_VER must be specified via flags (--old, --new) or environment variables." >&2
  echo "Run with -h or --help for usage." >&2
  exit 2
fi

resolve_ref() {
  local ver="$1"
  if [[ "${ver}" =~ ^(helm-chart-|v|refs/) ]]; then
    echo "${ver}"
  else
    echo "${TAG_PREFIX}${ver}"
  fi
}

get_crd_name() {
  local file="$1"
  if ! grep -q "^kind: CustomResourceDefinition" "${file}" 2>/dev/null; then
    return 1
  fi
  local name
  name="$(awk '/^metadata:/{in_meta=1; next} in_meta && /^[[:space:]]+name:[[:space:]]*/{sub(/^[[:space:]]+name:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit} in_meta && /^[^[:space:]]/{in_meta=0}' "${file}")"
  name="${name#\"}"
  name="${name%\"}"
  name="${name#\'}"
  name="${name%\'}"
  if [[ -n "${name}" ]]; then
    echo "${name}"
    return 0
  fi
  return 1
}

fetch_crds_for_ref() {
  local ref="$1"
  local dest_dir="$2"

  mkdir -p "${dest_dir}"
  rm -rf "${dest_dir:?}"/* "${dest_dir:?}"/.[!.]* 2>/dev/null || true

  echo "Fetching ${ref} (${CRD_DIR}) from ${REPO_URL}..."
  if ! git -c advice.detachedHead=false clone --depth 1 --filter=blob:none --sparse --branch "${ref}" "${REPO_URL}" "${dest_dir}" -q 2>/dev/null; then
    # Fallback if branch/tag clone fails (e.g. commit SHA or non-standard ref)
    (
      cd "${dest_dir}"
      git init -q
      git remote add origin "${REPO_URL}"
      git fetch --depth 1 origin "${ref}" -q
      git checkout -q FETCH_HEAD
    )
  fi

  (
    cd "${dest_dir}"
    git sparse-checkout set "${CRD_DIR}" >/dev/null 2>&1 || true
  )
}

index_crds() {
  local src_dir="$1"
  local index_dir="$2"

  mkdir -p "${index_dir}"
  rm -rf "${index_dir:?}"/*

  if [[ ! -d "${src_dir}" ]]; then
    echo "0"
    return 0
  fi

  local count=0
  for f in "${src_dir}"/*.yaml "${src_dir}"/*.yml; do
    [[ -f "${f}" ]] || continue
    local crd_name
    if crd_name="$(get_crd_name "${f}")"; then
      cp "${f}" "${index_dir}/${crd_name}.yaml"
      count=$((count + 1))
    fi
  done
  echo "${count}"
}

compare_crds() {
  local old_ref="$1"
  local new_ref="$2"

  local old_clone="${WORKDIR}/old_clone"
  local new_clone="${WORKDIR}/new_clone"

  fetch_crds_for_ref "${old_ref}" "${old_clone}"
  fetch_crds_for_ref "${new_ref}" "${new_clone}"

  local old_src="${old_clone}/${CRD_DIR}"
  local new_src="${new_clone}/${CRD_DIR}"

  local old_count new_count
  old_count="$(index_crds "${old_src}" "${OLD_CRDS_IDX}")"
  new_count="$(index_crds "${new_src}" "${NEW_CRDS_IDX}")"

  echo "Indexed ${old_count} CRDs from ${old_ref}, ${new_count} CRDs from ${new_ref}."

  if [[ "${old_count}" -eq 0 || "${new_count}" -eq 0 ]]; then
    echo "Error: No valid CRDs found in '${CRD_DIR}' for one or both versions (${old_ref}: ${old_count}, ${new_ref}: ${new_count})." >&2
    return 1
  fi

  local compare_failed=0

  # Check for removed CRDs (existed in old, not in new)
  for old_file in "${OLD_CRDS_IDX}"/*.yaml; do
    [[ -f "${old_file}" ]] || continue
    local crd_name
    crd_name="$(basename "${old_file}" .yaml)"
    local new_file="${NEW_CRDS_IDX}/${crd_name}.yaml"
    if [[ ! -f "${new_file}" ]]; then
      echo "❌ CRD REMOVED: ${crd_name} (existed in ${old_ref}, removed in ${new_ref})" >&2
      compare_failed=1
    fi
  done

  # Check for new CRDs and compare paired CRDs
  for new_file in "${NEW_CRDS_IDX}"/*.yaml; do
    [[ -f "${new_file}" ]] || continue
    local crd_name
    crd_name="$(basename "${new_file}" .yaml)"
    local old_file="${OLD_CRDS_IDX}/${crd_name}.yaml"
    if [[ ! -f "${old_file}" ]]; then
      echo "ℹ️  NEW CRD: ${crd_name} (introduced in ${new_ref})"
      continue
    fi

    echo "=== crdify ${crd_name} (${old_ref} -> ${new_ref}) ==="
    if ! crdify "file://${old_file}" "file://${new_file}" -o plaintext; then
      compare_failed=1
    fi
  done

  return "${compare_failed}"
}

resolve_openapi2jsonschema() {
  if [[ -n "${OPENAPI2JSONSCHEMA}" && -f "${OPENAPI2JSONSCHEMA}" ]]; then
    echo "${OPENAPI2JSONSCHEMA}"
    return 0
  fi
  if command -v openapi2jsonschema.py >/dev/null 2>&1; then
    command -v openapi2jsonschema.py
    return 0
  fi
  if command -v openapi2jsonschema >/dev/null 2>&1; then
    command -v openapi2jsonschema
    return 0
  fi

  local tool_dir="${WORKDIR}/tools"
  local script_path="${tool_dir}/openapi2jsonschema.py"
  if [[ -x "${script_path}" ]]; then
    echo "${script_path}"
    return 0
  fi

  echo "openapi2jsonschema.py not found in PATH; downloading to ${script_path}..." >&2
  mkdir -p "${tool_dir}"
  local url="https://raw.githubusercontent.com/yannh/kubeconform/${KUBECONFORM_VERSION}/scripts/openapi2jsonschema.py"
  if curl --location --retry 3 --retry-delay 1 --show-error --silent --output "${script_path}" "${url}" 2>/dev/null; then
    chmod +x "${script_path}"
    echo "${script_path}"
    return 0
  else
    echo "Error: Failed to download openapi2jsonschema.py from ${url}" >&2
    return 1
  fi
}

generate_json_schemas() {
  local crds_dir="$1"
  local target_schema_dir="$2"

  if [[ ! -d "${crds_dir}" ]]; then
    echo "Error: CRD directory not found at ${crds_dir}" >&2
    return 1
  fi

  local crd_files=()
  for f in "${crds_dir}"/*.yaml "${crds_dir}"/*.yml; do
    [[ -f "${f}" ]] && crd_files+=("${f}")
  done

  if [[ ${#crd_files[@]} -eq 0 ]]; then
    echo "Error: No CRD YAML files found in ${crds_dir} to generate schemas." >&2
    return 1
  fi

  local openapi_script
  if ! openapi_script="$(resolve_openapi2jsonschema)"; then
    echo "Error: Failed to resolve openapi2jsonschema.py" >&2
    return 1
  fi

  mkdir -p "${target_schema_dir}"
  echo "=== Generating JSON schemas in ${target_schema_dir} via openapi2jsonschema.py ==="
  (
    cd "${target_schema_dir}"
    python3 "${openapi_script}" "${crd_files[@]}"
  )
}

run_pluto_gate() {
  local failed=0

  if [[ ! -d "${FIXTURE_DIR}" ]]; then
    echo "Warning: FIXTURE_DIR not found (${FIXTURE_DIR}); skipping Pluto" >&2
    return 0
  fi

  echo "=== Pluto fixtures (${FIXTURE_DIR}) ==="
  if ! pluto detect-files -d "${FIXTURE_DIR}" --output wide; then
    failed=1
  fi

  return "${failed}"
}

run_kubeconform_gate() {
  local failed=0

  if [[ ! -d "${FIXTURE_DIR}" ]]; then
    echo "Warning: FIXTURE_DIR not found (${FIXTURE_DIR}); skipping kubeconform" >&2
    return 0
  fi

  local fixture_files=()
  for f in "${FIXTURE_DIR}"/*.yaml "${FIXTURE_DIR}"/*.yml; do
    [[ -f "${f}" ]] && fixture_files+=("${f}")
  done

  if [[ ${#fixture_files[@]} -eq 0 ]]; then
    echo "Warning: No fixture YAML files found in ${FIXTURE_DIR}; skipping kubeconform" >&2
    return 0
  fi

  # Generate schemas from the target/new CRDs
  if ! generate_json_schemas "${NEW_CRDS_IDX}" "${SCHEMA_DIR}"; then
    echo "Error: Failed to generate JSON schemas for kubeconform" >&2
    return 1
  fi

  echo "=== kubeconform fixtures (${FIXTURE_DIR}) ==="
  if ! kubeconform -summary -output text \
    -schema-location "${SCHEMA_DIR}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
    -schema-location "${SCHEMA_DIR}/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
    -schema-location default \
    "${fixture_files[@]}"; then
    failed=1
  fi

  return "${failed}"
}

OLD_REF="$(resolve_ref "${OLD_VER}")"
NEW_REF="$(resolve_ref "${NEW_VER}")"

failed=0

if ! compare_crds "${OLD_REF}" "${NEW_REF}"; then
  failed=1
fi

if [[ "${RUN_PLUTO}" == "true" ]]; then
  if ! run_pluto_gate; then
    failed=1
  fi
fi

if [[ "${RUN_KUBECONFORM}" == "true" ]]; then
  if ! run_kubeconform_gate; then
    failed=1
  fi
fi

exit "${failed}"
