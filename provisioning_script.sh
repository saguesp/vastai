#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${COMFYUI_DIR:-${WORKSPACE_DIR}/ComfyUI}"
MODELS_DIR="${MODELS_DIR:-${COMFYUI_DIR}/models}"
WORKFLOW_DIR="${WORKFLOW_DIR:-${COMFYUI_DIR}/user/default/workflows}"
CUSTOM_NODES_DIR="${CUSTOM_NODES_DIR:-${COMFYUI_DIR}/custom_nodes}"
API_PAYLOAD_DIR="${API_PAYLOAD_DIR:-/opt/comfyui-api-wrapper/payloads}"
HF_SEMAPHORE_DIR="${WORKSPACE_DIR}/hf_download_sem_$$"
HF_MAX_PARALLEL="${HF_MAX_PARALLEL:-1}"

# Hugging Face token: set it in Vast.ai env vars as HF_TOKEN or HUGGING_FACE_HUB_TOKEN.
# Requested fallback token is read-only; override it with env vars if you rotate it.
# Do not publish this script with the fallback token still embedded.
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-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}}"
HF_HOME="${HF_HOME:-${WORKSPACE_DIR}/.cache/huggingface}"
HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
export HF_TOKEN HF_HOME HF_HUB_ENABLE_HF_TRANSFER HF_XET_HIGH_PERFORMANCE

# Toggle installs/downloads. Defaults are chosen for RTX 5090 quality-first use.
UPDATE_COMFYUI="${UPDATE_COMFYUI:-1}"
INSTALL_COMFYUI_MANAGER="${INSTALL_COMFYUI_MANAGER:-1}"
DOWNLOAD_IDEOGRAM4="${DOWNLOAD_IDEOGRAM4:-1}"
DOWNLOAD_FLUX2_KLEIN="${DOWNLOAD_FLUX2_KLEIN:-1}"
DOWNLOAD_FLUX2_KLEIN_FP8="${DOWNLOAD_FLUX2_KLEIN_FP8:-0}"
DOWNLOAD_ADONIS_FLUX2KLEIN="${DOWNLOAD_ADONIS_FLUX2KLEIN:-1}"
DOWNLOAD_IDEOGRAM4_UNCONDITIONAL="${DOWNLOAD_IDEOGRAM4_UNCONDITIONAL:-0}"
DOWNLOAD_IDEOGRAM_NVFP4="${DOWNLOAD_IDEOGRAM_NVFP4:-0}"
# Adonis targets FLUX.2 Klein 9B. It is enabled automatically with Adonis,
# but you can set DOWNLOAD_FLUX2_KLEIN_9B=0 to skip the gated 9B base model.
DOWNLOAD_FLUX2_KLEIN_9B="${DOWNLOAD_FLUX2_KLEIN_9B:-$DOWNLOAD_ADONIS_FLUX2KLEIN}"
DOWNLOAD_FLUX2_KLEIN_9B_FP8="${DOWNLOAD_FLUX2_KLEIN_9B_FP8:-0}"
UPGRADE_TORCH_FOR_RTX50="${UPGRADE_TORCH_FOR_RTX50:-0}"

# Safer defaults for Vast.ai provisioning.
# SeedVR2 is optional and caused rotary_embedding_torch import errors in the previous run.
INSTALL_SEEDVR2="${INSTALL_SEEDVR2:-0}"
# Continue past custom-node install errors so model downloads are not blocked by optional nodes.
SKIP_CUSTOM_NODE_ERRORS="${SKIP_CUSTOM_NODE_ERRORS:-1}"
# Fail early with a clear message if there is not enough free disk for the selected model set.
# Set REQUIRED_FREE_GB=0 to disable this check.
REQUIRED_FREE_GB="${REQUIRED_FREE_GB:-60}"
# Keep large temporary Hugging Face downloads on /workspace instead of /tmp.
HF_STAGING_DIR="${HF_STAGING_DIR:-${WORKSPACE_DIR}/.hf_downloads}"

WORKFLOW_URL_IDEOGRAM4="https://raw.githubusercontent.com/AcademiaSD/comfyui_AcademiaSD/main/example_workflows/AcademiaSD_Ideogram-4_v16_Inpaint.json"
WORKFLOW_FILE_IDEOGRAM4="${WORKFLOW_DIR}/AcademiaSD_Ideogram-4_v16_Inpaint.json"

# Model declarations are assembled as: "REPO|FILE_IN_REPO|OUTPUT_PATH"
declare -a HF_MODELS=()

### End Configuration ###

log() {
  echo "[provision] $*"
}

script_cleanup() {
  rm -rf "$HF_SEMAPHORE_DIR"
}

script_error() {
  local exit_code=$?
  local line_number=$1
  echo "[ERROR] Provisioning script failed at line ${line_number} with exit code ${exit_code}" | tee -a "${MODEL_LOG:-/var/log/portal/comfyui.log}" || true
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

main() {
  activate_python_env
  ensure_layout
  update_comfyui
  install_base_python_deps
  maybe_upgrade_torch_for_rtx50

  # Download workflows before custom nodes so a single optional node cannot leave
  # the instance without any workflows installed.
  download_workflows
  install_custom_nodes

  build_model_list
  check_workspace_free_space
  download_all_hf_models
  write_api_wrapper_note
  log "Provisioning completed. Workflows are in: ${WORKFLOW_DIR}"
}

activate_python_env() {
  if [ -f /venv/main/bin/activate ]; then
    # Vast.ai / RunPod-style ComfyUI base images usually use this venv.
    # shellcheck disable=SC1091
    . /venv/main/bin/activate
  elif [ -f "${COMFYUI_DIR}/venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    . "${COMFYUI_DIR}/venv/bin/activate"
  else
    log "No ComfyUI virtualenv found; continuing with system python."
  fi
}

update_comfyui() {
  if [ "$UPDATE_COMFYUI" != "1" ]; then
    log "UPDATE_COMFYUI=0; skipping ComfyUI update."
    return 0
  fi

  if [ ! -d "${COMFYUI_DIR}/.git" ]; then
    log "ComfyUI is not a git checkout at ${COMFYUI_DIR}; skipping core update."
    return 0
  fi

  log "Updating ComfyUI core so Flux.2 / Ideogram 4 nodes are available..."

  # Some Vast.ai templates ship ComfyUI in detached HEAD. A plain `git pull`
  # fails there with: "You are not currently on a branch". This block detects
  # that state, checks out the remote default branch, and continues. If Git still
  # fails, the provisioning continues instead of aborting the whole instance.
  local current_branch=""
  local default_branch=""
  local update_status=0

  current_branch=$(git -C "$COMFYUI_DIR" symbolic-ref --short -q HEAD || true)

  if [ -z "$current_branch" ]; then
    log "ComfyUI is in detached HEAD; switching to the remote default branch before updating."

    default_branch=$(git -C "$COMFYUI_DIR" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}' || true)
    if [ -z "$default_branch" ] || [ "$default_branch" = "(unknown)" ]; then
      if git -C "$COMFYUI_DIR" ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
        default_branch="main"
      elif git -C "$COMFYUI_DIR" ls-remote --exit-code --heads origin master >/dev/null 2>&1; then
        default_branch="master"
      else
        default_branch="main"
      fi
    fi

    set +e
    git -C "$COMFYUI_DIR" fetch --depth 1 origin "$default_branch"
    update_status=$?
    if [ "$update_status" -eq 0 ]; then
      git -C "$COMFYUI_DIR" checkout -B "$default_branch" "origin/$default_branch"
      update_status=$?
    fi
    set -e
  else
    set +e
    git -C "$COMFYUI_DIR" pull --ff-only
    update_status=$?
    if [ "$update_status" -ne 0 ]; then
      log "Fast-forward pull failed; trying fetch + hard reset for branch ${current_branch}."
      git -C "$COMFYUI_DIR" fetch --depth 1 origin "$current_branch"
      update_status=$?
      if [ "$update_status" -eq 0 ]; then
        git -C "$COMFYUI_DIR" reset --hard "origin/$current_branch"
        update_status=$?
      fi
    fi
    set -e
  fi

  if [ "$update_status" -ne 0 ]; then
    log "WARNING: ComfyUI update failed; continuing with the version included in the image."
    return 0
  fi

  if [ -f "${COMFYUI_DIR}/requirements.txt" ]; then
    python -m pip install -r "${COMFYUI_DIR}/requirements.txt"
  fi
}


check_workspace_free_space() {
  if [ "${REQUIRED_FREE_GB}" = "0" ]; then
    log "REQUIRED_FREE_GB=0; skipping free disk check."
    return 0
  fi

  local free_gb
  free_gb=$(df -BG "$WORKSPACE_DIR" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
  free_gb="${free_gb:-0}"

  log "Free disk in ${WORKSPACE_DIR}: ${free_gb} GB. Required minimum: ${REQUIRED_FREE_GB} GB."

  if [ "$free_gb" -lt "$REQUIRED_FREE_GB" ]; then
    echo "ERROR: not enough free disk in ${WORKSPACE_DIR}." >&2
    echo "ERROR: free=${free_gb}GB required=${REQUIRED_FREE_GB}GB." >&2
    echo "ERROR: increase Vast.ai disk size or set DOWNLOAD_FLUX2_KLEIN=0 / DOWNLOAD_ADONIS_FLUX2KLEIN=0 / DOWNLOAD_IDEOGRAM4_UNCONDITIONAL=0." >&2
    return 1
  fi
}

maybe_upgrade_torch_for_rtx50() {
  if [ "$UPGRADE_TORCH_FOR_RTX50" != "1" ]; then
    log "Keeping the image's existing PyTorch/CUDA stack. Set UPGRADE_TORCH_FOR_RTX50=1 only if your base image lacks RTX 50 support."
    return 0
  fi

  log "Upgrading PyTorch CUDA wheels for RTX 50-series compatibility."
  python -m pip install --upgrade --index-url https://download.pytorch.org/whl/cu128 torch torchvision torchaudio
}

ensure_layout() {
  mkdir -p \
    "$COMFYUI_DIR" \
    "$CUSTOM_NODES_DIR" \
    "$WORKFLOW_DIR" \
    "$MODELS_DIR/diffusion_models" \
    "$MODELS_DIR/text_encoders" \
    "$MODELS_DIR/vae" \
    "$MODELS_DIR/loras" \
    "$MODELS_DIR/loras/flux2_klein" \
    "$HF_SEMAPHORE_DIR" \
    "$HF_HOME"
}

install_base_python_deps() {
  log "Installing base Python dependencies for Hugging Face, GGUF loaders and text encoders..."
  python -m pip install --upgrade pip setuptools wheel
  python -m pip install --upgrade     huggingface_hub     hf_transfer     hf-xet     gguf     safetensors     accelerate     transformers     sentencepiece     protobuf     qwen-vl-utils     rotary-embedding-torch
}

run_maybe_nonfatal() {
  local description="$1"
  shift

  if "$@"; then
    return 0
  fi

  if [ "$SKIP_CUSTOM_NODE_ERRORS" = "1" ]; then
    log "WARNING: ${description} failed; continuing because SKIP_CUSTOM_NODE_ERRORS=1."
    return 0
  fi

  log "ERROR: ${description} failed."
  return 1
}

clone_or_update() {
  local repo_url="$1"
  local dir_name="$2"
  local target_dir="${CUSTOM_NODES_DIR}/${dir_name}"
  local clone_extra="${3:-}"

  if [ -d "${target_dir}/.git" ]; then
    log "Updating custom node: ${dir_name}"
    git -C "$target_dir" fetch --depth 1 origin
    git -C "$target_dir" reset --hard origin/HEAD
  else
    log "Installing custom node: ${dir_name}"
    if [ "$clone_extra" = "recursive" ]; then
      git clone --depth 1 --recursive "$repo_url" "$target_dir"
    else
      git clone --depth 1 "$repo_url" "$target_dir"
    fi
  fi
}

clone_or_update_safe() {
  local repo_url="$1"
  local dir_name="$2"
  local clone_extra="${3:-}"
  run_maybe_nonfatal "clone/update ${dir_name}" clone_or_update "$repo_url" "$dir_name" "$clone_extra"
}

install_node_requirements() {
  local node_dir="$1"
  if [ ! -d "$node_dir" ]; then
    return 0
  fi
  if [ -f "${node_dir}/requirements.txt" ]; then
    log "Installing requirements for $(basename "$node_dir")"
    python -m pip install -r "${node_dir}/requirements.txt"
  fi
}

run_node_install_script() {
  local node_dir="$1"
  if [ ! -d "$node_dir" ]; then
    return 0
  fi
  if [ -f "${node_dir}/install.py" ]; then
    log "Running install.py for $(basename "$node_dir")"
    python "${node_dir}/install.py"
  elif [ -f "${node_dir}/install.sh" ]; then
    log "Running install.sh for $(basename "$node_dir")"
    bash "${node_dir}/install.sh"
  fi
}

disable_custom_node_if_present() {
  local dir_name="$1"
  local src_dir="${CUSTOM_NODES_DIR}/${dir_name}"
  local disabled_dir="${COMFYUI_DIR}/custom_nodes_disabled"

  if [ -d "$src_dir" ]; then
    mkdir -p "$disabled_dir"
    local dest_dir="${disabled_dir}/${dir_name}_disabled_$(date +%Y%m%d_%H%M%S)"
    log "Disabling custom node ${dir_name}: moving it to ${dest_dir}"
    mv "$src_dir" "$dest_dir"
  fi
}

dedupe_comfyui_manager() {
  # Some images already include ComfyUI-Manager while older scripts cloned comfyui-manager.
  # Keeping both can make startup noisier and slower.
  if [ -d "${CUSTOM_NODES_DIR}/ComfyUI-Manager" ] && [ -d "${CUSTOM_NODES_DIR}/comfyui-manager" ]; then
    disable_custom_node_if_present "comfyui-manager"
  fi
}

install_custom_nodes() {
  log "Installing custom nodes required by AcademiaSD Ideogram 4 and Flux.2 Klein workflows..."

  dedupe_comfyui_manager

  if [ "$INSTALL_COMFYUI_MANAGER" = "1" ]; then
    clone_or_update_safe "https://github.com/Comfy-Org/ComfyUI-Manager.git" "ComfyUI-Manager"
    dedupe_comfyui_manager
  fi

  clone_or_update_safe "https://github.com/AcademiaSD/comfyui_AcademiaSD.git" "comfyui_AcademiaSD"
  clone_or_update_safe "https://github.com/city96/ComfyUI-GGUF.git" "ComfyUI-GGUF"
  clone_or_update_safe "https://github.com/yolain/ComfyUI-Easy-Use.git" "ComfyUI-Easy-Use" "recursive"
  clone_or_update_safe "https://github.com/yanokusnir-ai/one-node-flux-2-klein.git" "one-node-flux-2-klein"
  clone_or_update_safe "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git" "ComfyUI-Inpaint-CropAndStitch"

  if [ "$INSTALL_SEEDVR2" = "1" ]; then
    clone_or_update_safe "https://github.com/ainvfx/ComfyUI-SeedVR2_VideoUpscaler.git" "ComfyUI-SeedVR2_VideoUpscaler"
  else
    log "INSTALL_SEEDVR2=0; skipping SeedVR2 video upscaler node."
    disable_custom_node_if_present "ComfyUI-SeedVR2_VideoUpscaler"
  fi

  local node_dirs=(
    "${CUSTOM_NODES_DIR}/ComfyUI-Manager"
    "${CUSTOM_NODES_DIR}/comfyui_AcademiaSD"
    "${CUSTOM_NODES_DIR}/ComfyUI-GGUF"
    "${CUSTOM_NODES_DIR}/ComfyUI-Easy-Use"
    "${CUSTOM_NODES_DIR}/one-node-flux-2-klein"
    "${CUSTOM_NODES_DIR}/ComfyUI-Inpaint-CropAndStitch"
  )

  if [ "$INSTALL_SEEDVR2" = "1" ]; then
    node_dirs+=("${CUSTOM_NODES_DIR}/ComfyUI-SeedVR2_VideoUpscaler")
  fi

  local node_dir
  for node_dir in "${node_dirs[@]}"; do
    run_maybe_nonfatal "install requirements for $(basename "$node_dir")" install_node_requirements "$node_dir"
    run_maybe_nonfatal "run install script for $(basename "$node_dir")" run_node_install_script "$node_dir"
  done
}

download_workflows() {
  log "Downloading AcademiaSD Ideogram 4 inpaint workflow..."
  mkdir -p "$WORKFLOW_DIR"
  if ! download_url_file "$WORKFLOW_URL_IDEOGRAM4" "$WORKFLOW_FILE_IDEOGRAM4"; then
    log "WARNING: failed to download AcademiaSD Ideogram 4 workflow; continuing."
  fi
}

download_url_file() {
  local url="$1"
  local output_path="$2"
  local temp_path
  temp_path=$(mktemp)

  mkdir -p "$(dirname "$output_path")"
  curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 -o "$temp_path" "$url"
  python -m json.tool "$temp_path" >/dev/null
  mv "$temp_path" "$output_path"
  log "Downloaded workflow: ${output_path}"
}

add_hf_model() {
  local repo="$1"
  local file_path="$2"
  local output_path="$3"
  HF_MODELS+=("${repo}|${file_path}|${output_path}")
}

build_model_list() {
  HF_MODELS=()

  if [ "$DOWNLOAD_IDEOGRAM4" = "1" ]; then
    # Main workflow: AcademiaSD_Ideogram-4_v16_Inpaint.json
    add_hf_model "Comfy-Org/Ideogram-4" "diffusion_models/ideogram4_fp8_scaled.safetensors" "${MODELS_DIR}/diffusion_models/ideogram4_fp8_scaled.safetensors"
    if [ "$DOWNLOAD_IDEOGRAM4_UNCONDITIONAL" = "1" ]; then
      add_hf_model "Comfy-Org/Ideogram-4" "diffusion_models/ideogram4_unconditional_fp8_scaled.safetensors" "${MODELS_DIR}/diffusion_models/ideogram4_unconditional_fp8_scaled.safetensors"
    fi
    add_hf_model "Comfy-Org/Ideogram-4" "text_encoders/qwen3vl_8b_fp8_scaled.safetensors" "${MODELS_DIR}/text_encoders/qwen3vl_8b_fp8_scaled.safetensors"
    add_hf_model "HauhauCS/Qwen3VL-8B-Uncensored-HauhauCS-Aggressive" "Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf" "${MODELS_DIR}/text_encoders/Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
    add_hf_model "Comfy-Org/gemma-4" "text_encoders/gemma4_e4b_it_fp8_scaled.safetensors" "${MODELS_DIR}/text_encoders/gemma4_e4b_it_fp8_scaled.safetensors"
    add_hf_model "Comfy-Org/Ideogram-4" "vae/flux2-vae.safetensors" "${MODELS_DIR}/vae/flux2-vae.safetensors"
  fi

  if [ "$DOWNLOAD_IDEOGRAM_NVFP4" = "1" ]; then
    # Optional Ideogram 4 low-VRAM alternatives. The official v16 workflow points to the FP8 filenames above by default.
    add_hf_model "Comfy-Org/Ideogram-4" "diffusion_models/ideogram4_nvfp4_mixed.safetensors" "${MODELS_DIR}/diffusion_models/ideogram4_nvfp4_mixed.safetensors"
    add_hf_model "Comfy-Org/Ideogram-4" "text_encoders/qwen3vl_8b_nvfp4.safetensors" "${MODELS_DIR}/text_encoders/qwen3vl_8b_nvfp4.safetensors"
  fi

  if [ "$DOWNLOAD_FLUX2_KLEIN" = "1" ]; then
    # Requested explicitly: Flux.2 Klein, not Flux.2 base/dev.
    # RTX 5090 quality-first default: full non-FP8 4B model + full Qwen 3 4B text encoder.
    add_hf_model "Comfy-Org/vae-text-encorder-for-flux-klein-4b" "split_files/diffusion_models/flux-2-klein-4b.safetensors" "${MODELS_DIR}/diffusion_models/flux-2-klein-4b.safetensors"
    add_hf_model "Comfy-Org/vae-text-encorder-for-flux-klein-4b" "split_files/text_encoders/qwen_3_4b.safetensors" "${MODELS_DIR}/text_encoders/qwen_3_4b.safetensors"
    add_hf_model "Comfy-Org/vae-text-encorder-for-flux-klein-4b" "split_files/vae/flux2-vae.safetensors" "${MODELS_DIR}/vae/flux2-vae.safetensors"
  fi

  if [ "$DOWNLOAD_FLUX2_KLEIN_FP8" = "1" ]; then
    # Optional lightweight fallback for low VRAM or if the full checkpoint is not desired.
    add_hf_model "black-forest-labs/FLUX.2-klein-4b-fp8" "flux-2-klein-4b-fp8.safetensors" "${MODELS_DIR}/diffusion_models/flux-2-klein-4b-fp8.safetensors"
    add_hf_model "Comfy-Org/vae-text-encorder-for-flux-klein-4b" "split_files/text_encoders/qwen_3_4b_fp4_flux2.safetensors" "${MODELS_DIR}/text_encoders/qwen_3_4b_fp4_flux2.safetensors"
  fi

  if [ "$DOWNLOAD_FLUX2_KLEIN_9B" = "1" ]; then
    # Required for Adonis. This is gated/non-commercial; accept the terms on Hugging Face for the token first.
    add_hf_model "black-forest-labs/FLUX.2-klein-9B" "flux-2-klein-9b.safetensors" "${MODELS_DIR}/diffusion_models/flux-2-klein-9b.safetensors"
    add_hf_model "Comfy-Org/vae-text-encorder-for-flux-klein-9b" "split_files/text_encoders/qwen_3_8b.safetensors" "${MODELS_DIR}/text_encoders/qwen_3_8b.safetensors"
    add_hf_model "Comfy-Org/vae-text-encorder-for-flux-klein-9b" "split_files/vae/flux2-vae.safetensors" "${MODELS_DIR}/vae/flux2-vae.safetensors"
  fi

  if [ "$DOWNLOAD_FLUX2_KLEIN_9B_FP8" = "1" ]; then
    # Optional lighter 9B checkpoint. The full 9B above is preferred for Adonis quality.
    add_hf_model "black-forest-labs/FLUX.2-klein-9b-fp8" "flux-2-klein-9b-fp8.safetensors" "${MODELS_DIR}/diffusion_models/flux-2-klein-9b-fp8.safetensors"
    add_hf_model "Comfy-Org/vae-text-encorder-for-flux-klein-9b" "split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors" "${MODELS_DIR}/text_encoders/qwen_3_8b_fp8mixed.safetensors"
    add_hf_model "Comfy-Org/vae-text-encorder-for-flux-klein-9b" "split_files/vae/flux2-vae.safetensors" "${MODELS_DIR}/vae/flux2-vae.safetensors"
  fi

  if [ "$DOWNLOAD_ADONIS_FLUX2KLEIN" = "1" ]; then
    # LoKr/LoRA files are placed directly in models/loras so One Node FLUX.2 Klein sees them in its LoRA selector.
    add_hf_model "n8te0/adonis_flux2klein" "adonis_base.safetensors" "${MODELS_DIR}/loras/adonis_base.safetensors"
    add_hf_model "n8te0/adonis_flux2klein" "adonis_post.safetensors" "${MODELS_DIR}/loras/adonis_post.safetensors"
    add_hf_model "n8te0/adonis_flux2klein" "adonis_refine.safetensors" "${MODELS_DIR}/loras/adonis_refine.safetensors"
    add_hf_model "n8te0/adonis_flux2klein" "Adonis_Workflow.json" "${WORKFLOW_DIR}/Adonis_Workflow.json"
  fi
}

download_all_hf_models() {
  if [ "${#HF_MODELS[@]}" -eq 0 ]; then
    log "No Hugging Face model downloads enabled."
    return 0
  fi

  mkdir -p "$HF_STAGING_DIR"

  if [ -n "$HF_TOKEN" ]; then
    hf auth login --token "$HF_TOKEN" --add-to-git-credential >/dev/null 2>&1 || hf auth login --token "$HF_TOKEN" >/dev/null 2>&1 || true
  else
    log "HF_TOKEN is not set. Public files may download, but gated models will fail."
  fi

  log "Downloading ${#HF_MODELS[@]} Hugging Face files with max parallelism ${HF_MAX_PARALLEL}..."
  local pids=()
  local model repo file_path output_path

  for model in "${HF_MODELS[@]}"; do
    repo="${model%%|*}"
    file_path="${model#*|}"
    file_path="${file_path%%|*}"
    output_path="${model##*|}"
    download_hf_file "$repo" "$file_path" "$output_path" &
    pids+=("$!")
  done

  local pid
  local failed=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done

  if [ "$failed" -ne 0 ]; then
    echo "ERROR: one or more Hugging Face downloads failed." >&2
    return 1
  fi
}

download_hf_file() {
  local repo="$1"
  local file_path="$2"
  local output_path="$3"
  local lockfile="${output_path}.lock"
  local max_retries=5
  local retry_delay=2
  local slot
  local temp_dir
  local attempt=1

  slot=$(acquire_slot)

  mkdir -p "$(dirname "$output_path")"
  while ! mkdir "$lockfile" 2>/dev/null; do
    log "Another process is downloading ${output_path}; waiting..."
    sleep 1
  done

  if [ -s "$output_path" ]; then
    log "File already exists: ${output_path}; skipping."
    rmdir "$lockfile" || true
    release_slot "$slot"
    return 0
  fi

  temp_dir=$(mktemp -d "${HF_STAGING_DIR}/download.XXXXXX")

  while [ "$attempt" -le "$max_retries" ]; do
    log "Downloading ${repo}/${file_path} to ${output_path} (attempt ${attempt}/${max_retries})..."

    local hf_token_args=()
    if [ -n "$HF_TOKEN" ]; then
      hf_token_args=(--token "$HF_TOKEN")
    fi

    if hf download "$repo" "$file_path" --local-dir "$temp_dir" "${hf_token_args[@]}"; then
      if [ -f "${temp_dir}/${file_path}" ]; then
        mv -f "${temp_dir}/${file_path}" "$output_path"
        rm -rf "$temp_dir"
        rmdir "$lockfile" || true
        release_slot "$slot"
        log "Downloaded: ${output_path}"
        return 0
      fi
      log "Download command succeeded but expected file was not found at ${temp_dir}/${file_path}."
    fi

    log "Download failed for ${repo}/${file_path}; retrying in ${retry_delay}s..."
    sleep "$retry_delay"
    retry_delay=$((retry_delay * 2))
    attempt=$((attempt + 1))
  done

  rm -rf "$temp_dir"
  rmdir "$lockfile" || true
  release_slot "$slot"
  echo "ERROR: failed to download ${repo}/${file_path}" >&2
  return 1
}

acquire_slot() {
  local i
  local slot

  while true; do
    i=1
    while [ "$i" -le "$HF_MAX_PARALLEL" ]; do
      slot="${HF_SEMAPHORE_DIR}/slot_${i}"
      if mkdir "$slot" 2>/dev/null; then
        echo "$slot"
        return 0
      fi
      i=$((i + 1))
    done
    sleep 0.5
  done
}

release_slot() {
  rmdir "$1" 2>/dev/null || rm -rf "$1"
}

write_api_wrapper_note() {
  # The AcademiaSD file requested is a ComfyUI UI workflow JSON, not a ComfyUI API prompt JSON.
  # Do not overwrite /opt/comfyui-api-wrapper/payloads with an invalid API payload.
  if [ -d "$API_PAYLOAD_DIR" ]; then
    cat > "${API_PAYLOAD_DIR}/README_AcademiaSD_Ideogram4.txt" <<'NOTE'
AcademiaSD_Ideogram-4_v16_Inpaint.json has been installed into the ComfyUI user workflows folder.
It is a UI workflow JSON. If this serverless wrapper requires an API prompt JSON, load the workflow in ComfyUI,
export it in API format, and place that exported JSON in this payloads directory.
NOTE
  fi
}

main "$@"
