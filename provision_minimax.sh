#!/usr/bin/env bash
# =============================================================
# Vast.ai & RunPod ComfyUI Provisioning (MiniMax-H3 전용)
#   - 상세로그  : /workspace/provision.log
#   - 실패요약  : /workspace/provision_FAILED.txt
#   - 완료마커  : /workspace/.provision_done
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

# Fail-Fast: 에러 발생 시 즉시 로그 기록 후 스크립트 중단
fail() {
    echo "[FAIL] $*" >&2
    echo "$*" >> "$FAILLOG"
    echo "===== MiniMax-H3 provisioning ABORTED: $(date) =====" >&2
    exit 1
}
log()  { echo "[..] $*"; }

echo "===== MiniMax-H3 provisioning start: $(date) ====="

# =============================================================
# 0. python / ComfyUI 경로 탐색 (RunPod + Vast.ai 자동 분기)
# =============================================================
PY=""
for V in /workspace/runpod-slim/venv /venv/main /venv/comfyui /opt/environments/python/comfyui; do
    [ -x "$V/bin/python" ] && PY="$V/bin/python" && break
done
[ -z "$PY" ] && PY="$(command -v python3)"
[ -z "$PY" ] && fail "python not found"
PIP=("$PY" -m pip)
echo "[OK] python: $PY ($("$PY" -V 2>&1))"

COMFY=""
for C in /workspace/runpod-slim/ComfyUI /workspace/ComfyUI /opt/workspace-internal/ComfyUI /opt/ComfyUI "$HOME/ComfyUI"; do
    [ -f "$C/main.py" ] && COMFY="$C" && break
done
[ -z "$COMFY" ] && fail "ComfyUI path not found"
echo "[OK] ComfyUI: $COMFY"

# =============================================================
# 0-1. Civitai 토큰 설정
# =============================================================
CIVITAI_TOKEN="${CIVITAI_TOKEN:-05420d5201ff5924e10b3bfaba6e6277}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

# =============================================================
# 0-2. 필수 패키지 및 ffmpeg 설치
# =============================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    aria2 curl unzip file ca-certificates ffmpeg || fail "apt-get install"

# 토치/넘파이 버전 보존용 제약조건
CONSTRAINTS=/tmp/comfy-constraints.txt
"$PY" - > "$CONSTRAINTS" <<'EOF'
import importlib.metadata as md
for p in ("torch","torchvision","torchaudio","numpy",
          "opencv-python","opencv-python-headless","xformers"):
    try: print(f"{p}=={md.version(p)}")
    except Exception: pass
EOF
PIPQ=("${PIP[@]}" install -q --root-user-action=ignore -c "$CONSTRAINTS")

# pip 내부 ffmpeg 바인딩용 패키지 설치
"${PIPQ[@]}" ffmpeg-python imageio-ffmpeg || fail "pip ffmpeg install"

# =============================================================
# 1. 모델 디렉토리 생성
# =============================================================
mkdir -p "$COMFY/models/diffusion_models"
mkdir -p "$COMFY/models/vae"
mkdir -p "$COMFY/models/vae_approx"
mkdir -p "$COMFY/models/text_encoders"
mkdir -p "$COMFY/models/frame_interpolation"
mkdir -p "$COMFY/models/upscale_models"
mkdir -p "$COMFY/models/latent_upscale_models"
mkdir -p "$COMFY/custom_nodes"

# =============================================================
# 2. 다운로드 헬퍼 함수
# =============================================================
ARIA_OPTS=(
    -x 16 -s 16 -k 1M
    --max-tries=5 --retry-wait=5 --lowest-speed-limit=50K
    --timeout=60 --connect-timeout=20
    --file-allocation=none --console-log-level=warn --summary-interval=0
    --continue=true --allow-overwrite=true --auto-file-renaming=false
    --user-agent="$UA"
)

dl_file() {
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

dl_civitai_file() {
    local url="$1" out="$2" min="${3:-1000000}"
    local dir name auth_url; dir="$(dirname "$out")"; name="$(basename "$out")"
    if [ -s "$out" ] && [ "$(stat -c%s "$out")" -gt "$min" ]; then
        echo "[SKIP] $name"; return 0
    fi
    rm -f "$out" "$out.aria2"; mkdir -p "$dir"
    log "download civitai $name"

    # URL 토큰 파라미터만 주입 (Authorization 헤더 중복 전송 방지)
    if [ -n "$CIVITAI_TOKEN" ]; then
        [[ "$url" == *"?"* ]] && auth_url="${url}&token=${CIVITAI_TOKEN}" || auth_url="${url}?token=${CIVITAI_TOKEN}"
    else
        auth_url="$url"
    fi

    if aria2c "${ARIA_OPTS[@]}" -d "$dir" -o "$name" "$auth_url" \
       && [ "$(stat -c%s "$out" 2>/dev/null || echo 0)" -gt "$min" ]; then
        echo "[OK] $name ($(du -h "$out" | cut -f1))"
    else
        rm -f "$out" "$out.aria2"; fail "download civitai $name"
    fi
}

# =============================================================
# 3. 모델 다운로드
# =============================================================
# [diffusion_models] Civitai Model (civitai.com 도메인 적용)
dl_civitai_file "https://civitai.com/api/download/models/3314675?fileId=3203130" \
                "$COMFY/models/diffusion_models/minimax_h3_diffusion.safetensors"

# [vae]
dl_file "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors" \
        "$COMFY/models/vae/minimax_h3_video_vae_fp16.safetensors"

dl_file "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors" \
        "$COMFY/models/vae/minimax_h3_audio_vae_fp32.safetensors"

# [vae_approx]
dl_file "https://huggingface.co/Kijai/MiniMax-H3-TAE/resolve/main/vae_approx/taeh3.safetensors?download=true" \
        "$COMFY/models/vae_approx/taeh3.safetensors"

# [text_encoders]
dl_file "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
        "$COMFY/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"

# [frame_interpolation]
dl_file "https://huggingface.co/Comfy-Org/frame_interpolation/resolve/main/frame_interpolation/rife_v4.25_heavy.safetensors?download=true" \
        "$COMFY/models/frame_interpolation/rife_v4.25_heavy.safetensors"

# [upscale_models]
dl_file "https://github.com/Kim2091/Kim2091-Models/releases/download/2x-AnimeSharpV4/2x-AnimeSharpV4_RCAN.safetensors" \
        "$COMFY/models/upscale_models/2x-AnimeSharpV4_RCAN.safetensors"

# [latent_upscale_models]
dl_file "https://huggingface.co/LBH-123-AI/Minimax_h3_latent_Upscaler/resolve/main/minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors?download=true" \
        "$COMFY/models/latent_upscale_models/minimax_h3_latent_upscaler_3d_bf16.safetensors"

# =============================================================
# 4. 커스텀 노드 설치
# =============================================================
NODE_DIR="$COMFY/custom_nodes"
nodes=(
    "https://github.com/city96/ComfyUI-GGUF.git"
    "https://github.com/darksidewalker/ComfyUI-DaSiWa-Nodes.git"
    "https://github.com/bbaudio-2025/Comfyui-MMH3-UltimateUpscale.git"
)

for repo in "${nodes[@]}"; do
    name="$(basename "$repo" .git)"
    path="$NODE_DIR/$name"
    if [ -d "$path/.git" ]; then
        echo "[SKIP] node $name"
    else
        rm -rf "$path"
        git clone --depth 1 --recursive "$repo" "$path" >/dev/null 2>&1 \
            || fail "clone $name"
        echo "[OK] clone $name"
    fi
    if [ -f "$path/requirements.txt" ]; then
        "${PIPQ[@]}" -r "$path/requirements.txt" \
            && echo "[OK] deps $name" || fail "deps $name"
    fi
done

# =============================================================
# 5. 무결성 확인 및 완료
# =============================================================
"$PY" -c "import torch,numpy;print('[OK] torch',torch.__version__,'cuda',torch.cuda.is_available(),'| numpy',numpy.__version__)" \
    || fail "torch/numpy broken"

# 모든 단계 통과 시 완료 마커 생성
date > "$DONE"
rm -f "$FAILLOG"
echo "===== MiniMax-H3 provisioning end: $(date) ====="
echo "ALL OK -> 인스턴스 재부팅(Reboot) 권장."
