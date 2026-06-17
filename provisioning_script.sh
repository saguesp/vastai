#!/bin/bash

set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE_DIR}/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
WORKFLOW_DIR="${COMFYUI_DIR}/user/default/workflows"
HF_SEMAPHORE_DIR="${WORKSPACE_DIR}/hf_download_sem_$$"
HF_MAX_PARALLEL=3

# Model declarations: "URL|OUTPUT_PATH"
HF_MODELS=(
  "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors|$MODELS_DIR/vae/flux2-vae.safetensors"
  "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/diffusion_models/flux2_dev_fp8mixed.safetensors|$MODELS_DIR/diffusion_models/flux2_dev_fp8mixed.safetensors"
  "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/text_encoders/mistral_3_small_flux2_bf16.safetensors|$MODELS_DIR/text_encoders/mistral_3_small_flux2_bf16.safetensors"
  
  # === ECOSISTEMA PULID (Consistencia de Rostro de alta fidelidad sin alterar el cuerpo) ===
  "https://huggingface.co/guozhipeng/PuLID-Flux/resolve/main/pulid_flux_v1.safetensors|$MODELS_DIR/pulid/pulid_flux_v1.safetensors"
  
  # === ECOSISTEMA SUPIR (Fotorrealismo, eliminación de pixelado y micro-textura de poros) ===
  "https://huggingface.co/Benjamin-Z/SUPIR/resolve/main/SUPIR_v0Q.ckpt|$MODELS_DIR/layer_model/SUPIR_v0Q.ckpt"
  
  # === ESCALADORES MATEMÁTICOS (Para Ultimate SD Upscale sin alterar estructura) ===
  "https://huggingface.co/kimbalist/4x-UltraSharp/resolve/main/4x-UltraSharp.pth|$MODELS_DIR/upscale_models/4x-UltraSharp.pth"
)
  
### End Configuration ###

script_cleanup() {
   rm -rf "$HF_SEMAPHORE_DIR"
}

script_error() {
    local exit_code=$?
    local line_number=$1
    echo "[ERROR] Provisioning Script failed at line $line_number with exit code $exit_code" | tee -a "${MODEL_LOG:-/var/log/portal/comfyui.log}"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

main() {
    . /venv/main/bin/activate
    mkdir -p "$HF_SEMAPHORE_DIR"
    
    # Crear la estructura de directorios avanzados antes de descargar
    mkdir -p "$MODELS_DIR/pulid"
    mkdir -p "$MODELS_DIR/layer_model"
    mkdir -p "$MODELS_DIR/upscale_models"
    
    # Instalar repositorios y dependencias binarias de Python
    install_custom_nodes
    
    write_workflow
    write_api_workflow
    
    pids=()
    # Download all models in parallel
    for model in "${HF_MODELS[@]}"; do
        url="${model%%|*}"
        output_path="${model##*|}"
        download_hf_file "$url" "$output_path" &
        pids+=($!)
    done
    
    # Wait for each job and check exit status
    for pid in "${pids[@]}"; do
        wait "$pid" || exit 1
    done
    
    echo "=== PROVISIONAMIENTO COMPLETADO EXITOSAMENTE ==="
}

install_custom_nodes() {
    echo "=== Instalando extensiones y dependencias nativas ==="
    mkdir -p "${COMFYUI_DIR}/custom_nodes"
    cd "${COMFYUI_DIR}/custom_nodes"
    
    # 1. Impact Pack (Segmentación de ropa con SAM)
    if [ ! -d "ComfyUI-Impact-Pack" ]; then
        git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git
        pip install --no-cache-dir -r ComfyUI-Impact-Pack/requirements.txt
    fi

    # 2. PuLID para FLUX (Consistencia nativa de identidad)
    if [ ! -d "ComfyUI-PuLID-Flux" ]; then
        git clone https://github.com/balazskreith/ComfyUI-PuLID-Flux.git
        # Requisito crítico de compilación para análisis facial insightface
        pip install --no-cache-dir insightface onnxruntime-gpu
    fi

    # 3. SUPIR (Motor avanzado de restauración y nitidez)
    if [ ! -d "ComfyUI-SUPIR" ]; then
        git clone https://github.com/kijai/ComfyUI-SUPIR.git
        pip install --no-cache-dir -r ComfyUI-SUPIR/requirements.txt
    fi

    # 4. Ultimate SD Upscale (Mosaico de texturas de alta resolución)
    if [ ! -d "ComfyUI_Ultimate_SD_Upscale" ]; then
        git clone https://github.com/ssitu/ComfyUI_Ultimate_SD_Upscale.git
    fi

    cd "${WORKSPACE_DIR}"
}

download_hf_file() {
  local url="$1"
  local output_path="$2"
  local lockfile="${output_path}.lock"
  local max_retries=5
  local retry_delay=2
  
  local slot=$(acquire_slot)
  
  while ! mkdir "$lockfile" 2>/dev/null; do
    echo "Another process is downloading to $output_path (waiting...)"
    sleep 1
  done
  
  if [ -f "$output_path" ]; then
    echo "File already exists: $output_path (skipping)"
    rmdir "$lockfile"
    release_slot "$slot"
    return 0
  fi
  
  local repo=$(echo "$url" | sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p')
  local file_path=$(echo "$url" | sed -n 's|https://huggingface.co/[^/]*/[^/]*\)/resolve/[^/]*/\(.*\)|\1|p')
  
  if [ -z "$repo" ] || [ -z "$file_path" ]; then
    repo=$(echo "$url" | cut -d'/' -f4,5)
    file_path=$(echo "$url" | cut -d'/' -f7-)
  fi
  
  local temp_dir=$(mktemp -d)
  local attempt=1
  
  while [ $attempt -le $max_retries ]; do
    echo "Downloading $file_path (attempt $attempt/$max_retries)..."
    
    if hf download "$repo" \
      "$file_path" \
      --local-dir "$temp_dir" 2>&1; then
      
      mkdir -p "$(dirname "$output_path")"
      mv "$temp_dir/$file_path" "$output_path"
      rm -rf "$temp_dir"
      rmdir "$lockfile"
      release_slot "$slot"
      echo "✓ Successfully downloaded: $output_path"
      return 0
    else
      echo "✗ Download failed (attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
      sleep $retry_delay
      retry_delay=$((retry_delay * 2))
      attempt=$((attempt + 1))
    fi
  done
  
  echo "ERROR: Failed to download $output_path after $max_retries attempts"
  rm -rf "$temp_dir"
  rmdir "$lockfile"
  release_slot "$slot"
  return 1
}

acquire_slot() {
  while true; do
    local count=$(find "$HF_SEMAPHORE_DIR" -name "slot_*" 2>/dev/null | wc -l)
    if [ $count -lt $HF_MAX_PARALLEL ]; then
      local slot="$HF_SEMAPHORE_DIR/slot_$$_$RANDOM"
      touch "$slot"
      echo "$slot"
      return 0
    fi
    sleep 0.5
  done
}

release_slot() {
  rm -f "$1"
}

write_workflow() {
    mkdir -p "${WORKFLOW_DIR}"
    local workflow_json
    read -r -d '' workflow_json << 'WORKFLOW_JSON' || true
{
  "id": "7c048efb-a059-44e2-970a-43e1eb472d0d",
  "revision": 0,
  "last_node_id": 51,
  "last_link_id": 138,
  "nodes": [
    {
      "id": 13,
      "type": "SamplerCustomAdvanced",
      "pos": [1020, 192],
      "size": [272.36, 124.53],
      "flags": {},
      "order": 21,
      "mode": 0,
      "inputs": [
        {"name": "noise", "type": "NOISE", "link": 37},
        {"name": "guider", "type": "GUIDER", "link": 30},
        {"name": "sampler", "type": "SAMPLER", "link": 19},
        {"name": "sigmas", "type": "SIGMAS", "link": 132},
        {"name": "latent_image", "type": "LATENT", "link": 131}
      ],
      "outputs": [
        {"name": "output", "type": "LATENT", "slot_index": 0, "links": [24]},
        {"name": "denoised_output", "type": "LATENT", "links": null}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": []
    },
    {
      "id": 8,
      "type": "VAEDecode",
      "pos": [1020, 367],
      "size": [210, 46],
      "flags": {},
      "order": 22,
      "mode": 0,
      "inputs": [
        {"name": "samples", "type": "LATENT", "link": 24},
        {"name": "vae", "type": "VAE", "link": 12}
      ],
      "outputs": [
        {"name": "IMAGE", "type": "IMAGE", "slot_index": 0, "links": [9]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": []
    },
    {
      "id": 16,
      "type": "KSamplerSelect",
      "pos": [620, 740],
      "size": [315, 58],
      "flags": {},
      "order": 0,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "SAMPLER", "type": "SAMPLER", "links": [19]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["euler"]
    },
    {
      "id": 22,
      "type": "BasicGuider",
      "pos": [720, 48],
      "size": [222.34, 46],
      "flags": {},
      "order": 20,
      "mode": 0,
      "inputs": [
        {"name": "model", "type": "MODEL", "link": 133},
        {"name": "conditioning", "type": "CONDITIONING", "link": 130}
      ],
      "outputs": [
        {"name": "GUIDER", "type": "GUIDER", "slot_index": 0, "links": [30]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": []
    },
    {
      "id": 40,
      "type": "VAEEncode",
      "pos": [165, 43],
      "size": [140, 46],
      "flags": {},
      "order": 17,
      "mode": 0,
      "inputs": [
        {"name": "pixels", "type": "IMAGE", "link": 122},
        {"name": "vae", "type": "VAE", "link": 120}
      ],
      "outputs": [
        {"name": "LATENT", "type": "LATENT", "links": [121]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": []
    },
    {
      "id": 41,
      "type": "ImageScaleToTotalPixels",
      "pos": [-156, -3],
      "size": [270, 82],
      "flags": {},
      "order": 14,
      "mode": 0,
      "inputs": [
        {"name": "image", "type": "IMAGE", "link": 123}
      ],
      "outputs": [
        {"name": "IMAGE", "type": "IMAGE", "links": [122]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["area", 1]
    },
    {
      "id": 45,
      "type": "ImageScaleToTotalPixels",
      "pos": [-160, -380],
      "size": [270, 82],
      "flags": {},
      "order": 10,
      "mode": 0,
      "inputs": [
        {"name": "image", "type": "IMAGE", "link": 128}
      ],
      "outputs": [
        {"name": "IMAGE", "type": "IMAGE", "links": [126]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["area", 1]
    },
    {
      "id": 44,
      "type": "VAEEncode",
      "pos": [171, -55],
      "size": [140, 46],
      "flags": {},
      "order": 15,
      "mode": 0,
      "inputs": [
        {"name": "pixels", "type": "IMAGE", "link": 126},
        {"name": "vae", "type": "VAE", "link": 127}
      ],
      "outputs": [
        {"name": "LATENT", "type": "LATENT", "links": [125]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": []
    },
    {
      "id": 46,
      "type": "LoadImage",
      "pos": [-470, -380],
      "size": [274, 314],
      "flags": {},
      "order": 1,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "IMAGE", "type": "IMAGE", "links": [128]},
        {"name": "MASK", "type": "MASK", "links": null}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["model_reference.png", "image"]
    },
    {
      "id": 26,
      "type": "FluxGuidance",
      "pos": [620, 144],
      "size": [317, 58],
      "flags": {},
      "order": 16,
      "mode": 0,
      "inputs": [
        {"name": "conditioning", "type": "CONDITIONING", "link": 41}
      ],
      "outputs": [
        {"name": "CONDITIONING", "type": "CONDITIONING", "slot_index": 0, "links": [118]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": [1.8],
      "color": "#233",
      "bgcolor": "#355"
    },
    {
      "id": 48,
      "type": "Flux2Scheduler",
      "pos": [620, 840],
      "size": [270, 106],
      "flags": {},
      "order": 12,
      "mode": 0,
      "inputs": [
        {"name": "width", "type": "INT", "link": 136},
        {"name": "height", "type": "INT", "link": 138}
      ],
      "outputs": [
        {"name": "SIGMAS", "type": "SIGMAS", "links": [132]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": [25, 1024, 1024]
    },
    {
      "id": 51,
      "type": "PrimitiveNode",
      "pos": [210, 740],
      "size": [210, 82],
      "flags": {},
      "order": 2,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "INT", "type": "INT", "links": [137, 138]}
      ],
      "title": "height",
      "properties": {},
      "widgets_values": [1024, "fixed"]
    },
    {
      "id": 50,
      "type": "PrimitiveNode",
      "pos": [210, 620],
      "size": [210, 82],
      "flags": {},
      "order": 3,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "INT", "type": "INT", "links": [135, 136]}
      ],
      "title": "width",
      "properties": {},
      "widgets_values": [1024, "fixed"]
    },
    {
      "id": 25,
      "type": "RandomNoise",
      "pos": [620, 600],
      "size": [315, 82],
      "flags": {},
      "order": 5,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "NOISE", "type": "NOISE", "links": [37]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": [1064877805904688, "randomize"]
    },
    {
      "id": 6,
      "type": "CLIPTextEncode",
      "pos": [180, 240],
      "size": [422, 164],
      "flags": {},
      "order": 13,
      "mode": 0,
      "inputs": [
        {"name": "clip", "type": "CLIP", "link": 117}
      ],
      "outputs": [
        {"name": "CONDITIONING", "type": "CONDITIONING", "slot_index": 0, "links": [41]}
      ],
      "title": "CLIP Text Encode (Positive Prompt)",
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["A realistic smartphone candid reflection selfie, casual look, shot on mobile phone camera, imperfect natural indoor lighting, detailed skin texture with micro-pores and natural flaws, raw photography style, highly consistent anatomy"]
    },
    {
      "id": 38,
      "type": "CLIPLoader",
      "pos": [-200, 270],
      "size": [298, 106],
      "flags": {},
      "order": 6,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "CLIP", "type": "CLIP", "links": [117]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["mistral_3_small_flux2_bf16.safetensors", "flux2", "default"]
    },
    {
      "id": 12,
      "type": "UNETLoader",
      "pos": [-200, 144],
      "size": [315, 82],
      "flags": {},
      "order": 7,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "MODEL", "type": "MODEL", "slot_index": 0, "links": [133]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["flux2_dev_fp8mixed.safetensors", "default"]
    },
    {
      "id": 10,
      "type": "VAELoader",
      "pos": [-200, 432],
      "size": [311, 60],
      "flags": {},
      "order": 8,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "VAE", "type": "VAE", "slot_index": 0, "links": [12, 120, 127]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["flux2-vae.safetensors"]
    },
    {
      "id": 42,
      "type": "LoadImage",
      "pos": [-466, -3],
      "size": [274, 314],
      "flags": {},
      "order": 9,
      "mode": 0,
      "inputs": [],
      "outputs": [
        {"name": "IMAGE", "type": "IMAGE", "links": [123]},
        {"name": "MASK", "type": "MASK", "links": null}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["clothing_reference.png", "image"]
    },
    {
      "id": 43,
      "type": "ReferenceLatent",
      "pos": [400, -36],
      "size": [197, 46],
      "flags": {},
      "order": 19,
      "mode": 4,
      "inputs": [
        {"name": "conditioning", "type": "CONDITIONING", "link": 129},
        {"name": "latent", "type": "LATENT", "link": 125}
      ],
      "outputs": [
        {"name": "CONDITIONING", "type": "CONDITIONING", "links": [130]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": []
    },
    {
      "id": 39,
      "type": "ReferenceLatent",
      "pos": [400, 49],
      "size": [197, 46],
      "flags": {},
      "order": 18,
      "mode": 4,
      "inputs": [
        {"name": "conditioning", "type": "CONDITIONING", "link": 118},
        {"name": "latent", "type": "LATENT", "link": 121}
      ],
      "outputs": [
        {"name": "CONDITIONING", "type": "CONDITIONING", "links": [129]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": []
    },
    {
      "id": 9,
      "type": "SaveImage",
      "pos": [1320, -312],
      "size": [400, 400],
      "flags": {},
      "order": 23,
      "mode": 0,
      "inputs": [
        {"name": "images", "type": "IMAGE", "link": 9}
      ],
      "outputs": [],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": ["Smartphone_Output"]
    },
    {
      "id": 47,
      "type": "EmptyFlux2LatentImage",
      "pos": [210, 444],
      "size": [270, 106],
      "flags": {},
      "order": 11,
      "mode": 0,
      "inputs": [
        {"name": "width", "type": "INT", "link": 135},
        {"name": "height", "type": "INT", "link": 137}
      ],
      "outputs": [
        {"name": "LATENT", "type": "LATENT", "links": [131]}
      ],
      "properties": {"cnr_id": "comfy-core", "ver": "0.3.75"},
      "widgets_values": [1024, 1024, 1]
    }
  ],
  "links": [
    [9, 8, 0, 9, 0, "IMAGE"],
    [12, 10, 0, 8, 1, "VAE"],
    [19, 16, 0, 13, 2, "SAMPLER"],
    [24, 13, 0, 8, 0, "LATENT"],
    [30, 22, 0, 13, 1, "GUIDER"],
    [37, 25, 0, 13, 0, "NOISE"],
    [41, 6, 0, 26, 0, "CONDITIONING"],
    [117, 38, 0, 6, 0, "CLIP"],
    [118, 26, 0, 39, 0, "CONDITIONING"],
    [120, 10, 0, 40, 1, "VAE"],
    [121, 40, 0, 39, 1, "LATENT"],
    [122, 41, 0, 40, 0, "IMAGE"],
    [123, 42, 0, 41, 0, "IMAGE"],
    [125, 44, 0, 43, 1, "LATENT"],
    [126, 45, 0, 44, 0, "IMAGE"],
    [127, 10, 0, 44, 1, "VAE"],
    [128, 46, 0, 45, 0, "IMAGE"],
    [129, 39, 0, 43, 0, "CONDITIONING"],
    [130, 43, 0, 22, 1, "CONDITIONING"],
    [131, 47, 0, 13, 4, "LATENT"],
    [132, 48, 0, 13, 3, "SIGMAS"],
    [133, 12, 0, 22, 0, "MODEL"],
    [135, 50, 0, 47, 0, "INT"],
    [136, 50, 0, 48, 0, "INT"],
    [137, 51, 0, 47, 1, "INT"],
    [138, 51, 0, 48, 1, "INT"]
  ],
  "groups": [],
  "config": {},
  "extra": {},
  "version": 0.4
}
WORKFLOW_JSON
    echo "$workflow_json" > "${WORKFLOW_DIR}/flux.2-dev.json"
}

write_api_workflow() {
    local workflow_json
    local payload_json
    read -r -d '' workflow_json << 'WORKFLOW_API_JSON' || true
{
  "6": {
    "inputs": {
      "text": "A realistic smartphone candid reflection selfie, casual look, shot on mobile phone camera, imperfect natural indoor lighting, detailed skin texture with micro-pores and natural flaws, raw photography style, highly consistent anatomy",
      "clip": ["38", 0]
    },
    "class_type": "CLIPTextEncode"
  },
  "8": {
    "inputs": {
      "samples": ["13", 0],
      "vae": ["10", 0]
    },
    "class_type": "VAEDecode"
  },
  "9": {
    "inputs": {
      "filename_prefix": "Smartphone_Output",
      "images": ["8", 0]
    },
    "class_type": "SaveImage"
  },
  "10": {
    "inputs": {
      "vae_name": "flux2-vae.safetensors"
    },
    "class_type": "VAELoader"
  },
  "12": {
    "inputs": {
      "unet_name": "flux2_dev_fp8mixed.safetensors",
      "weight_dtype": "default"
    },
    "class_type": "UNETLoader"
  },
  "13": {
    "inputs": {
      "noise": ["25", 0],
      "guider": ["22", 0],
      "sampler": ["16", 0],
      "sigmas": ["48", 0],
      "latent_image": ["47", 0]
    },
    "class_type": "SamplerCustomAdvanced"
  },
  "16": {
    "inputs": {
      "sampler_name": "euler"
    },
    "class_type": "KSamplerSelect"
  },
  "22": {
    "inputs": {
      "model": ["12", 0],
      "conditioning": ["26", 0]
    },
    "class_type": "BasicGuider"
  },
  "25": {
    "inputs": {
      "noise_seed": "__RANDOM_INT__"
    },
    "class_type": "RandomNoise"
  },
  "26": {
    "inputs": {
      "guidance": 1.8,
      "conditioning": ["6", 0]
    },
    "class_type": "FluxGuidance"
  },
  "38": {
    "inputs": {
      "clip_name": "mistral_3_small_flux2_bf16.safetensors",
      "type": "flux2",
      "device": "default"
    },
    "class_type": "CLIPLoader"
  },
  "40": {
    "inputs": {
      "pixels": ["41", 0],
      "vae": ["10", 0]
    },
    "class_type": "VAEEncode"
  },
  "41": {
    "inputs": {
      "upscale_method": "area",
      "megapixels": 1,
      "image": ["42", 0]
    },
    "class_type": "ImageScaleToTotalPixels"
  },
  "42": {
    "inputs": {
      "image": "clothing_reference.png"
    },
    "class_type": "LoadImage"
  },
  "44": {
    "inputs": {
      "pixels": ["45", 0],
      "vae": ["10", 0]
    },
    "class_type": "VAEEncode"
  },
  "45": {
    "inputs": {
      "upscale_method": "area",
      "megapixels": 1,
      "image": ["46", 0]
    },
    "class_type": "ImageScaleToTotalPixels"
  },
  "46": {
    "inputs": {
      "image": "model_reference.png"
    },
    "class_type": "LoadImage"
  },
  "47": {
    "inputs": {
      "width": 1024,
      "height": 1024,
      "batch_size": 1
    },
    "class_type": "EmptyFlux2LatentImage"
  },
  "48": {
    "inputs": {
      "steps": 25,
      "width": 1024,
      "height": 1024
    },
    "class_type": "Flux2Scheduler"
  }
}
WORKFLOW_API_JSON
    payload_json=$(jq -n --argjson workflow "$workflow_json" '{input: {workflow_json: $workflow}}')
    rm -f /opt/comfyui-api-wrapper/payloads/*.json || true
    echo "$payload_json" > /opt/comfyui-api-wrapper/payloads/flux.2-dev.json
}

main
