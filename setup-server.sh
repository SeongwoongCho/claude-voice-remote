#!/bin/bash
# setup-server.sh
# Linux 서버에서 SSH 터널을 확인하고 tunnel-source를 등록합니다.
# 사용법: ./setup-server.sh [TUNNEL_PORT]
set -e

PORT="${1:-24713}"
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${GREEN}Claude Code Voice Mode - Server Setup${NC}"
echo ""

# ── 1. Check tunnel port ──
echo -e "${BLUE}[1/3]${NC} SSH 터널 확인 (port $PORT)..."
if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
  echo -e "${GREEN}  ✓${NC} port $PORT LISTEN"
else
  echo -e "${RED}  ✗${NC} port $PORT not listening"
  echo ""
  echo "  WSL에서 SSH 접속 시 리버스 터널을 포함했는지 확인:"
  echo "  ssh -R ${PORT}:localhost:4713 user@$(hostname)"
  exit 1
fi

# ── 2. Test PulseAudio via tunnel ──
echo -e "${BLUE}[2/3]${NC} PulseAudio 연결 테스트..."
if pactl -s "tcp:localhost:${PORT}" info &>/dev/null; then
  SERVER=$(pactl -s "tcp:localhost:${PORT}" info | grep "Server Name" | cut -d: -f2-)
  echo -e "${GREEN}  ✓${NC} $SERVER"
else
  echo -e "${RED}  ✗${NC} PulseAudio 연결 실패"
  echo "  WSL에서 PulseAudio TCP 모듈이 로드되어 있는지 확인"
  exit 1
fi

# ── 3. Load tunnel-source ──
echo -e "${BLUE}[3/3]${NC} tunnel-source 등록..."
if pactl list modules short 2>/dev/null | grep -q "module-tunnel-source"; then
  echo -e "${GREEN}  ✓${NC} 이미 등록됨"
else
  MODULE_ID=$(pactl load-module module-tunnel-source "server=tcp:localhost:${PORT}" 2>/dev/null)
  if [ -n "$MODULE_ID" ]; then
    echo -e "${GREEN}  ✓${NC} module ID: $MODULE_ID"
  else
    echo -e "${RED}  ✗${NC} 모듈 로드 실패"
    exit 1
  fi
fi

# Set as default source
pactl set-default-source "tunnel-source.tcp:localhost:${PORT}" 2>/dev/null && \
  echo -e "${GREEN}  ✓${NC} 기본 소스 설정 완료" || true

# ── Result ──
echo ""
echo -e "${GREEN}서버 설정 완료!${NC}"
echo ""
echo "소스 목록:"
pactl list sources short 2>/dev/null
echo ""
echo "다음: Docker 컨테이너에서 setup-docker.sh 실행"
echo ""

# ── Auto-load suggestion ──
SHELL_RC="$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"
if ! grep -q "module-tunnel-source" "$SHELL_RC" 2>/dev/null; then
  echo -e "${YELLOW}팁:${NC} SSH 접속 시 자동 로드하려면 ${SHELL_RC}에 추가:"
  echo ""
  echo '  if ! pactl list modules short 2>/dev/null | grep -q "module-tunnel-source"; then'
  echo "    pactl load-module module-tunnel-source server=tcp:localhost:${PORT} 2>/dev/null"
  echo '  fi'
  echo ""
fi
