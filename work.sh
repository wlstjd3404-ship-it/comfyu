#!/usr/bin/env bash
# =============================================================
# Vast.ai & RunPod ComfyUI Provisioning (non-interactive / reboot-friendly)
#   - 상세로그  : /workspace/provision.log
#   - 실패요약  : /workspace/provision_FAILED.txt   (없으면 전부 성공)
#   - 완료마커  : /workspace/.provision_done        (재부팅 시 재실행 방지)
#   - 재실행    : FORCE_PROVISION=1 bash /workspace/work.sh
# =============================================================
set -o pipefail

LOG=/workspace/provision.log
FAILLOG=/workspace/provision_FAILED.txt
DONE=/workspace/.provision_done

mkdir -p /workspace
exec > >(tee -a "$LOG") 2>&1

# ---------- 재실행 가드 ----------
if [ -f "$DONE" ] && [ -z "$FORCE_PROVISION" ]; then
    echo "[SKIP] already provisioned ($(cat "$DONE")). FORCE_PROVISION=1 to rerun."
    exit 0
fi

: > "$FAILLOG"
FAILED=0
fail() { echo "[FAIL] $*"; echo "$*" >> "$FAILLOG"; FAILED=$((FAILED+1)); }
log()  { echo "[..] $*"; }

echo "===== provisioning start: $(date) ====="

# =============================================================
# 0. python / ComfyUI 경로 탐색 (RunPod + Vast.ai 자동 분기)
# =============================================================
PY=""
for V in /workspace/runpod-slim/venv /venv/main /venv/comfyui /opt/environments/python/comfyui; do
    [ -x "$V/bin/python" ] && PY="$V/bin/python" && break
done
[ -z "$PY" ] && PY="$(command -v python3)"
[ -z "$PY" ] && { fail "python not found"; exit 1; }
PIP=("$PY" -m pip)
echo "[OK] python: $PY ($("$PY" -V 2>&1))"

COMFY=""
for C in /workspace/runpod-slim/ComfyUI /workspace/ComfyUI /opt/workspace-internal/ComfyUI /opt/ComfyUI "$HOME/ComfyUI"; do
    [ -f "$C/main.py" ] && COMFY="$C" && break
done
[ -z "$COMFY" ] && { fail "ComfyUI path not found"; exit 1; }
echo "[OK] ComfyUI: $COMFY"

# =============================================================
# 0-1. Civitai 인증
# =============================================================
CIVITAI_TOKEN="${CIVITAI_TOKEN:-05420d5201ff5924e10b3bfaba6e6277}"
CIVITAI_HOSTS=("https://civitai.com" "https://civitai.red")
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
[ -z "$CIVITAI_TOKEN" ] && echo "[SKIP] no CIVITAI_TOKEN — civitai 항목 건너뜀"

# =============================================================
# 0-2. 패키지
# =============================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    aria2 curl unzip file ca-certificates || fail "apt-get install"

# torch / numpy 가 노드 requirements 때문에 갈아엎히는 사고 방지
CONSTRAINTS=/tmp/comfy-constraints.txt
"$PY" - > "$CONSTRAINTS" <<'EOF'
import importlib.metadata as md
for p in ("torch","torchvision","torchaudio","numpy",
          "opencv-python","opencv-python-headless","xformers"):
    try: print(f"{p}=={md.version(p)}")
    except Exception: pass
EOF
echo "[OK] pinned:"; cat "$CONSTRAINTS"
PIPQ=("${PIP[@]}" install -q --root-user-action=ignore -c "$CONSTRAINTS")

# =============================================================
# 1. 디렉토리
# =============================================================
mkdir -p "$COMFY"/models/{checkpoints,loras,vae,upscale_models,controlnet,model_patches,ultralytics/bbox,ultralytics/segm}
mkdir -p "$COMFY/custom_nodes"

# =============================================================
# 2. 다운로드 헬퍼
# =============================================================
ARIA_OPTS=(
    -x 16 -s 16 -k 1M
    --max-tries=5 --retry-wait=5 --lowest-speed-limit=50K
    --timeout=60 --connect-timeout=20
    --file-allocation=none --console-log-level=warn --summary-interval=0
    --continue=true --allow-overwrite=true --auto-file-renaming=false
    --user-agent="$UA"
)

# dl_hf <url> <out> [min_bytes]
dl_hf() {
    local url="$1" out="$2" min="${3:-1000000}"
    local dir name; dir="$(dirname "$out")"; name="$(basename "$out")"
    if [ -s "$out" ] && [ "$(stat -c%s "$out")" -gt "$min" ]; then
        echo "[SKIP] $name"; return 0
    fi
    rm -f "$out" "$out.aria2"; mkdir -p "$dir"
    log "download $name"
    if aria2c "${ARIA_OPTS[@]}" -d "$dir" -o "$name" "$url" \
       && [ "$(stat -c%s "$out" 2>/dev/null || echo 0)" -gt "$min" ]; then
        echo "[OK] $name ($(du -h "$out" | cut -f1))"
    else
        rm -f "$out" "$out.aria2"; fail "download $name"
    fi
}

# dl_civitai_zip <api_path> <tmpzip> <target_dir> <marker>
dl_civitai_zip() {
    local apath="$1" out_zip="$2" target_dir="$3" marker="$4"
    local name; name="$(basename "$out_zip")"
    mkdir -p "$(dirname "$out_zip")" "$target_dir"

    if [ -n "$marker" ] && find "$target_dir" -name "$marker" -print -quit | grep -q .; then
        echo "[SKIP] extracted: $marker"; return 0
    fi
    [ -z "$CIVITAI_TOKEN" ] && { fail "no CIVITAI_TOKEN: $name"; return 1; }

    local host mode url code sz
    for host in "${CIVITAI_HOSTS[@]}"; do
      for mode in header query; do
        rm -f "$out_zip"
        if [ "$mode" = "query" ]; then
            if [[ "$apath" == *"?"* ]]; then url="${host}${apath}&token=${CIVITAI_TOKEN}"
            else                             url="${host}${apath}?token=${CIVITAI_TOKEN}"; fi
            code=$(curl -sSL --retry 3 --retry-delay 3 --connect-timeout 20 --max-time 1800 \
                   -A "$UA" -o "$out_zip" -w '%{http_code}' "$url")
        else
            code=$(curl -sSL --retry 3 --retry-delay 3 --connect-timeout 20 --max-time 1800 \
                   -A "$UA" -H "Authorization: Bearer ${CIVITAI_TOKEN}" \
                   -o "$out_zip" -w '%{http_code}' "${host}${apath}")
        fi
        sz=$(stat -c%s "$out_zip" 2>/dev/null || echo 0)
        echo "[..] $name via ${host} [$mode] HTTP=$code size=$sz"

        if [ "$code" = "200" ] && [ "$sz" -gt 10000 ] && unzip -tqq "$out_zip" >/dev/null 2>&1; then
            unzip -o -q "$out_zip" -d "$target_dir" || { fail "unzip $name"; return 1; }
            # 중첩 폴더 평탄화
            find "$target_dir" -mindepth 2 -type f \( -name '*.pt' -o -name '*.pth' \) \
                 -exec mv -n {} "$target_dir"/ \; 2>/dev/null
            find "$target_dir" -mindepth 1 -type d -empty -delete 2>/dev/null
            rm -f "$out_zip"
            echo "[OK] $name -> $target_dir"
            ls -1 "$target_dir"
            return 0
        fi
        { echo "--- $name / $host / $mode / HTTP=$code / size=$sz / $(file -b "$out_zip" 2>/dev/null)"
          head -c 300 "$out_zip" 2>/dev/null; echo; } >> "$FAILLOG"
      done
    done
    rm -f "$out_zip"
    fail "civitai $name (all hosts/modes failed)"
    return 1
}

# =============================================================
# 3. 모델
# =============================================================
BBOX_DIR="$COMFY/models/ultralytics/bbox"
SEGM_DIR="$COMFY/models/ultralytics/segm"
CN_DIR="$COMFY/models/controlnet"
PATCH_DIR="$COMFY/models/model_patches"

# --- 업스케일 ---
dl_hf "https://huggingface.co/FacehugmanIII/4x_foolhardy_Remacri/resolve/main/4x_foolhardy_Remacri.pth" \
      "$COMFY/models/upscale_models/4x_foolhardy_Remacri.pth"

# --- sam3.1_multiplex ---
dl_hf "https://huggingface.co/Comfy-Org/sam3.1/resolve/main/checkpoints/sam3.1_multiplex_fp16.safetensors" "$COMFY/models/checkpoints/sam3.1_multiplex_fp16.safetensors"

# --- Detectors (HuggingFace) ---
dl_hf "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov9c.pt" "$BBOX_DIR/hand_yolov9c.pt"
dl_hf "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt" "$BBOX_DIR/face_yolov9c.pt"

# --- Detectors (Civitai zip) ---
dl_civitai_zip "/api/download/models/582143?fileId=497517"   "/tmp/Eyeful_v2.zip"       "$BBOX_DIR" "*Eyeful*"
dl_civitai_zip "/api/download/models/2350456?fileId=2240838" "/tmp/ntd11_nsfw_segm.zip" "$SEGM_DIR" "*.pt"

# --- Model Patches (LLLite) & ControlNet 심볼릭 링크 ---
for f in anima-lllite-pose-1 anima-lllite-depth-1 \
         anima-lllite-inpainting-v1 anima-lllite-inpainting-v2 \
         anima-lllite-lineart-1 \
         anima-lllite-any-test-like-v2; do
    dl_hf "https://huggingface.co/kohya-ss/Anima-LLLite/resolve/main/${f}.safetensors" \
          "$PATCH_DIR/${f}.safetensors" 100000
    [ -f "$PATCH_DIR/${f}.safetensors" ] && ln -sf "$PATCH_DIR/${f}.safetensors" "$CN_DIR/${f}.safetensors"
done

# =============================================================
# 4. 커스텀 노드
# =============================================================
NODE_DIR="$COMFY/custom_nodes"
nodes=(
    "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
    "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git"
    "https://github.com/rgthree/rgthree-comfy.git"
    "https://github.com/alexopus/ComfyUI-Image-Saver.git"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
    "https://github.com/willmiao/ComfyUI-Lora-Manager.git"
    "https://github.com/yolain/ComfyUI-Easy-Use.git"
    "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git"
    "https://gitlab.com/UmeAiRT-Studio/comfyui-umeairt-toolkit.git"
    "https://github.com/pamparamm/ComfyUI-ppm.git"
    "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
    "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
    "https://github.com/lonecatone23/ComfyUI_LC123_nodes.git"
    "https://github.com/Sen-sou/Comfyui-Anima-Regional-Conditioning.git"
    "https://github.com/teenu/ComfyUI-Jakkanna.git"
)
for repo in "${nodes[@]}"; do
    name="$(basename "$repo" .git)"
    path="$NODE_DIR/$name"
    if [ -d "$path/.git" ]; then
        echo "[SKIP] node $name"
    else
        rm -rf "$path"
        git clone --depth 1 --recursive "$repo" "$path" >/dev/null 2>&1 \
            || { fail "clone $name"; continue; }
        echo "[OK] clone $name"
    fi
    if [ -f "$path/requirements.txt" ]; then
        "${PIPQ[@]}" -r "$path/requirements.txt" \
            && echo "[OK] deps $name" || fail "deps $name"
    fi
done

# --- Impact Pack / Subpack install.py ---
for n in ComfyUI-Impact-Pack ComfyUI-Impact-Subpack; do
    if [ -f "$NODE_DIR/$n/install.py" ]; then
        ( cd "$NODE_DIR/$n" && "$PY" install.py >/dev/null 2>&1 ) \
            && echo "[OK] install.py $n" || fail "install.py $n"
    fi
done

# =============================================================
# 5. 무결성 확인
# =============================================================
"$PY" -c "import torch,numpy;print('[OK] torch',torch.__version__,'cuda',torch.cuda.is_available(),'| numpy',numpy.__version__)" \
    || fail "torch/numpy broken"

echo "[INFO] bbox:"; ls -1 "$BBOX_DIR" 2>/dev/null
echo "[INFO] segm:"; ls -1 "$SEGM_DIR" 2>/dev/null
echo "[INFO] model_patches:"; ls -1 "$PATCH_DIR" 2>/dev/null

# =============================================================
# 6. 마무리
# =============================================================
echo "===== provisioning end: $(date) / failures=$FAILED ====="
date > "$DONE"
if [ "$FAILED" -eq 0 ]; then
    rm -f "$FAILLOG"
    echo "ALL OK -> 인스턴스 재부팅(Reboot) 권장."
else
    echo "$FAILED failure(s) -> cat $FAILLOG"
fi
