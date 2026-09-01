#!/bin/bash
# setup-wsl.sh
# WSL에서 PulseAudio TCP 모듈을 로드하고 상태를 확인합니다.
# 사용법: ./setup-wsl.sh
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${GREEN}Claude Code Voice Mode - WSL Setup${NC}"
echo ""

# ── 1. Check PulseAudio ──
echo -e "${BLUE}[1/3]${NC} PulseAudio 확인..."
if ! command -v pactl &>/dev/null; then
  echo -e "${RED}  ✗ pactl not found${NC}"
  echo "  설치: sudo apt-get install pulseaudio"
  exit 1
fi

if ! pactl info &>/dev/null; then
  echo -e "${YELLOW}  PulseAudio 시작 중...${NC}"
  pulseaudio --start 2>/dev/null || true
  sleep 1
fi

if pactl info &>/dev/null; then
  SERVER=$(pactl info | grep "Server Name" | cut -d: -f2-)
  echo -e "${GREEN}  ✓${NC} $SERVER"
else
  echo -e "${RED}  ✗ PulseAudio를 시작할 수 없습니다${NC}"
  exit 1
fi

# ── 2. Load TCP module ──
echo -e "${BLUE}[2/3]${NC} TCP 모듈 로드..."
if ss -tlnp 2>/dev/null | grep -q ":4713"; then
  echo -e "${GREEN}  ✓${NC} 이미 리스닝 중 (port 4713)"
else
  pactl load-module module-native-protocol-tcp \
    auth-ip-acl=127.0.0.1 \
    auth-anonymous=1 2>/dev/null && \
    echo -e "${GREEN}  ✓${NC} 모듈 로드 완료" || \
    echo -e "${YELLOW}  ⚠ 이미 로드되어 있을 수 있음${NC}"
fi

# ── 3. Verify ──
echo -e "${BLUE}[3/3]${NC} 포트 확인..."
if ss -tlnp 2>/dev/null | grep -q ":4713"; then
  echo -e "${GREEN}  ✓${NC} port 4713 LISTEN"
else
  echo -e "${RED}  ✗${NC} port 4713 not listening"
  exit 1
fi

# ── Result ──
echo ""
echo -e "${GREEN}WSL 설정 완료!${NC}"
echo ""
echo "다음 단계: SSH 접속 시 리버스 터널 포함"
echo ""
echo "  ssh -R 24713:localhost:4713 user@your-server"
echo ""
echo "또는 ~/.ssh/config에 추가:"
echo ""
echo "  Host your-server"
echo "      RemoteForward 24713 localhost:4713"
echo ""

# ── Auto-load suggestion ──
PULSE_DEFAULT_PA="$HOME/.config/pulse/default.pa"
if ! grep -q "module-native-protocol-tcp" "$PULSE_DEFAULT_PA" 2>/dev/null; then
  echo -e "${YELLOW}팁:${NC} 재부팅 후에도 자동 로드하려면:"
  echo ""
  echo "  mkdir -p ~/.config/pulse"
  echo "  echo 'load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1' >> ~/.config/pulse/default.pa"
  echo ""
fi

# ── Persistent tunnel (autossh) ──
echo -e "${BLUE}[선택]${NC} 영구 SSH 터널 설정..."
if command -v autossh &>/dev/null; then
  echo -e "${GREEN}  ✓${NC} autossh 설치됨"
  if pgrep -f "autossh.*24713" &>/dev/null; then
    echo -e "${GREEN}  ✓${NC} 터널 이미 실행 중"
  else
    echo ""
    echo "  영구 터널 시작 (터미널 꺼도 유지):"
    echo ""
    echo "  autossh -M 0 -f -N -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -R 24713:localhost:4713 your-server"
    echo ""
  fi
else
  echo -e "${YELLOW}  ⚠${NC} autossh 미설치 — 터미널 닫으면 터널 끊김"
  echo ""
  echo "  설치: sudo apt-get install autossh"
  echo "  이후: autossh -M 0 -f -N -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -R 24713:localhost:4713 your-server"
  echo ""
fi
