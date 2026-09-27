#!/bin/bash
# omavoice installer for Omarchy (Arch Linux + Hyprland).
#
# Detects the hardware and picks the setup that won't bog the machine down:
#   NVIDIA with 12GB+ VRAM : transcription and cleanup both on the GPU
#   NVIDIA with 6 to 11GB  : transcription on the CPU, cleanup on the GPU
#   no NVIDIA GPU          : transcription on the CPU, cleanup off
# Scripts and service files are symlinked from this repo, so pulling the repo
# updates them. Your config files are only created when missing.
#
# Usage: ./install.sh [--cleanup | --no-cleanup] [--name NAME]
set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
cfg="$HOME/.config/voxtype"
units="$HOME/.config/systemd/user"
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

force_cleanup=""
name=""
while (($#)); do
  case $1 in
    --cleanup) force_cleanup=true ;;
    --no-cleanup) force_cleanup=false ;;
    --name) name=$2; shift ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
  shift
done

step "Checking hardware"
grep -qw avx2 /proc/cpuinfo || { echo "Voxtype's ONNX builds need a CPU with AVX2."; exit 1; }
cpu_bin=/usr/lib/voxtype/voxtype-onnx-avx2
grep -qw avx512f /proc/cpuinfo && cpu_bin=/usr/lib/voxtype/voxtype-onnx-avx512
ram_gb=$(awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo)
vram_mib=0
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
  vram_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | sort -n | tail -1)
elif lspci 2>/dev/null | grep -Eiq '(vga|3d).*nvidia'; then
  echo "An NVIDIA GPU is present but nvidia-smi is not working. Install the NVIDIA driver"
  echo "(Omarchy does this on setup), reboot, and run this installer again for GPU acceleration."
fi

if ((vram_mib >= 12000)); then voxtype_gpu=true; cleanup=true
elif ((vram_mib >= 6000)); then voxtype_gpu=false; cleanup=true
else voxtype_gpu=false; cleanup=false; fi
[[ -n $force_cleanup ]] && cleanup=$force_cleanup
echo "RAM ${ram_gb}GB, NVIDIA VRAM ${vram_mib}MiB"
echo "Transcription: $([[ $voxtype_gpu == true ]] && echo GPU || echo "CPU ($(basename "$cpu_bin"))")"
echo "LLM cleanup:   $cleanup$([[ $cleanup == true && $vram_mib -lt 6000 ]] && echo ' (forced on without a GPU: expect 10s+ per dictation)')"
if ((ram_gb < 16)) && [[ $voxtype_gpu == false ]]; then
  echo "Warning: CPU transcription holds about 9.4GB of RAM; with ${ram_gb}GB the machine may swap."
fi

step "Installing packages"
pkgs=(voxtype-bin wtype wl-clipboard libnotify python curl)
[[ $cleanup == true ]] && pkgs+=(ollama-cuda)
[[ $voxtype_gpu == true ]] && pkgs+=(cudnn)
sudo pacman -S --needed --noconfirm "${pkgs[@]}"

step "Downloading Cohere Transcribe (fp16, 3.9GB)"
# Voxtype 1.0.1's setup --download has no Cohere entry (upstream issue #687), so fetch it directly.
model="$HOME/.local/share/voxtype/models/cohere-transcribe-fp16"
hf=https://huggingface.co/onnx-community/cohere-transcribe-03-2026-ONNX/resolve/main
mkdir -p "$model"
for pair in tokenizer.json:tokenizer.json tokenizer_config.json:tokenizer_config.json \
  config.json:config.json generation_config.json:generation_config.json processor_config.json:processor_config.json \
  onnx/encoder_model_fp16.onnx:encoder_model.onnx onnx/decoder_model_merged_fp16.onnx:decoder_model_merged.onnx \
  onnx/encoder_model_fp16.onnx_data:encoder_model_fp16.onnx_data onnx/encoder_model_fp16.onnx_data_1:encoder_model_fp16.onnx_data_1 \
  onnx/decoder_model_merged_fp16.onnx_data:decoder_model_merged_fp16.onnx_data; do
  [[ -s $model/${pair#*:} ]] || curl -fL --retry 3 -o "$model/${pair#*:}" "$hf/${pair%%:*}"
done

step "Linking scripts and services from $repo"
mkdir -p "$HOME/.local/bin" "$units/voxtype.service.d" "$cfg"
for f in "$repo"/bin/*; do ln -sfn "$f" "$HOME/.local/bin/$(basename "$f")"; done
ln -sfn "$repo/systemd/voxtype.service.d/override.conf" "$units/voxtype.service.d/override.conf"
if [[ $cleanup == true ]]; then
  if systemctl is-enabled ollama.service >/dev/null 2>&1; then
    echo "System-wide ollama.service is enabled; using it instead of a user service."
  else
    ln -sfn "$repo/systemd/ollama.service" "$units/ollama.service"
  fi
  if ((vram_mib >= 6000)); then
    ln -sfn "$repo/systemd/dictation-vram-guard.service" "$units/dictation-vram-guard.service"
  fi
fi

step "Creating config files (existing ones are kept)"
if [[ -e $cfg/config.toml ]] && ! grep -q dictation-cleanup "$cfg/config.toml"; then
  # A stock config (Omarchy ships one) lacks eager processing and the cleanup hook.
  mv "$cfg/config.toml" "$cfg/config.toml.before-omavoice"
  echo "Moved your previous Voxtype config to $cfg/config.toml.before-omavoice"
fi
if [[ ! -e $cfg/config.toml ]]; then
  sed "s|__HOME__|$HOME|" "$repo/config/config.toml" >"$cfg/config.toml"
  if [[ $voxtype_gpu == false ]]; then
    threads=$(($(nproc) / 2)); ((threads > 8)) && threads=8; ((threads < 2)) && threads=2
    sed -i "s/^threads = 8$/threads = $threads/" "$cfg/config.toml"
  fi
else
  echo "Keeping your $cfg/config.toml. Compare it with $repo/config/config.toml; it needs"
  echo "eager_processing = true, on_demand_loading = false and the post_process command."
fi
[[ -e $cfg/app-styles.toml ]] || cp "$repo/config/app-styles.toml" "$cfg/app-styles.toml"
[[ -e $cfg/dictionary.txt ]] || cp "$repo/config/dictionary.example.txt" "$cfg/dictionary.txt"
if [[ ! -e $cfg/omavoice.toml ]]; then
  [[ -n $name ]] || name=$(getent passwd "$USER" | cut -d: -f5 | cut -d, -f1 | awk '{print $1}')
  [[ -n $name ]] || name=$USER
  sed -e "s|__NAME__|$name|" -e "s|__CLEANUP__|$cleanup|" "$repo/config/omavoice.toml" >"$cfg/omavoice.toml"
else
  sed -i "s/^cleanup = .*/cleanup = $cleanup/" "$cfg/omavoice.toml"
fi
if [[ $voxtype_gpu == true ]]; then
  rm -f "$cfg/omavoice.env"
else
  echo "VOXTYPE_BIN=$cpu_bin" >"$cfg/omavoice.env"
fi

step "Protecting against surprise Voxtype updates"
# Hold voxtype-bin back from routine updates; omavoice-upgrade tests a new
# version before installing it. The Omarchy hooks keep the hold in place and
# check everything after each system update.
"$repo/bin/omavoice-hold"
hooks="$HOME/.config/omarchy/hooks"
mkdir -p "$hooks/pre-refresh-pacman.d" "$hooks/post-update.d"
ln -sfn "$repo/hooks/pre-refresh-pacman" "$hooks/pre-refresh-pacman.d/50-omavoice"
ln -sfn "$repo/hooks/post-update" "$hooks/post-update.d/50-omavoice"
installed=$(pacman -Q voxtype-bin | awk '{print $2}')
mkdir -p "$HOME/.local/share/omavoice/rollback"
cp -n /var/cache/pacman/pkg/voxtype-bin-"$installed"-*.pkg.tar.zst "$HOME/.local/share/omavoice/rollback/" 2>/dev/null ||
  echo "No cached voxtype-bin $installed package; omavoice-upgrade will save one before the next upgrade."

step "Starting services"
systemctl --user daemon-reload
if [[ $cleanup == true ]]; then
  [[ -e $units/ollama.service ]] && systemctl --user enable --now ollama.service
  for _ in {1..30}; do curl -s 127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done
  ollama pull gemma4:e4b
  [[ -e $units/dictation-vram-guard.service ]] && systemctl --user enable --now dictation-vram-guard.service
fi
systemctl --user enable voxtype.service >/dev/null 2>&1 || true
systemctl --user restart voxtype.service

step "Done"
if grep -qs dictation-record "$HOME/.config/hypr/bindings.lua"; then
  echo "Hyprland dictation keys already point at dictation-record."
else
  echo "Add the dictation keys to ~/.config/hypr/bindings.lua:"
  echo
  cat "$repo/hyprland/bindings.lua"
fi
echo
echo "Then tap Super + Alt (or hold F9) and talk. Add names and jargon to $cfg/dictionary.txt."
echo "Check the setup any time with omavoice-doctor; upgrade Voxtype with omavoice-upgrade."
