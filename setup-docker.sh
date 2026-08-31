#!/bin/bash
# setup-docker.sh
# Docker 컨테이너에서 Claude Code 네이티브 보이스 모드 활성화
# 사용법: ./setup-docker.sh [--port PORT]
set -e

PULSE_PORT="${1:-4713}"
if [ "$1" = "--port" ]; then PULSE_PORT="${2:-4713}"; fi

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${GREEN}Claude Code Voice Mode - Docker Setup${NC}"
echo ""

# ── 1. Install packages ──
echo -e "${BLUE}[1/5]${NC} 패키지 설치..."
NEED=0
dpkg -s libasound2-plugins &>/dev/null || NEED=1
dpkg -s pulseaudio-utils &>/dev/null || NEED=1
if [ "$NEED" -eq 1 ]; then
  apt-get update -qq 2>/dev/null
  apt-get install -y --no-install-recommends libasound2-plugins pulseaudio-utils 2>/dev/null
fi
echo -e "${GREEN}  ✓${NC} libasound2-plugins, pulseaudio-utils"

# ── 2. ALSA → PulseAudio ──
echo -e "${BLUE}[2/5]${NC} ALSA → PulseAudio 브릿지..."
cat > ~/.asoundrc << 'EOF'
pcm.default pulse
ctl.default pulse
pcm.pulse { type pulse }
ctl.pulse { type pulse }
EOF
echo -e "${GREEN}  ✓${NC} ~/.asoundrc"

# ── 3. Detect gateway ──
echo -e "${BLUE}[3/5]${NC} Docker 게이트웨이 탐지..."
GW=""
grep -q "host.docker.internal" /etc/hosts 2>/dev/null && \
  GW=$(grep "host.docker.internal" /etc/hosts | awk '{print $1}' | head -1)
[ -z "$GW" ] && GW=$(ip route 2>/dev/null | grep default | awk '{print $3}' || true)
[ -z "$GW" ] && GW="172.17.0.1"
echo -e "${GREEN}  ✓${NC} Gateway: $GW"

# ── 4. PulseAudio client ──
echo -e "${BLUE}[4/5]${NC} PulseAudio 클라이언트 설정..."
mkdir -p ~/.config/pulse
cat > ~/.config/pulse/client.conf << CONF
default-server = tcp:${GW}:${PULSE_PORT}
autospawn = no
daemon-binary = /bin/true
CONF
echo -e "${GREEN}  ✓${NC} tcp:${GW}:${PULSE_PORT}"

# ── 5. Shell profile ──
echo -e "${BLUE}[5/5]${NC} 환경변수..."
PROFILE="$HOME/.zshrc"; [ ! -f "$PROFILE" ] && PROFILE="$HOME/.bashrc"
LINE="export PULSE_SERVER=\"tcp:${GW}:${PULSE_PORT}\""
if grep -q "PULSE_SERVER" "$PROFILE" 2>/dev/null; then
  sed -i "s|^export PULSE_SERVER=.*|${LINE}|" "$PROFILE"
else
  echo -e "\n# Claude Code Voice Mode\n${LINE}" >> "$PROFILE"
fi
export PULSE_SERVER="tcp:${GW}:${PULSE_PORT}"
echo -e "${GREEN}  ✓${NC} $PROFILE"

# ── Test ──
echo ""
if pactl info &>/dev/null; then
  echo -e "${GREEN}PulseAudio 연결 성공!${NC}"
  SRC=$(pactl info 2>/dev/null | grep "Default Source" | cut -d: -f2-)
  echo "  Default Source:$SRC"
  echo ""
  echo "테스트: parecord --channels=1 --rate=16000 --format=s16le /tmp/test.raw --duration=2"
  echo "사용:   claude → /voice → Space"
else
  echo -e "${YELLOW}PulseAudio 서버 미연결. README.md의 Step 1~3을 먼저 완료하세요.${NC}"
fi
echo ""
