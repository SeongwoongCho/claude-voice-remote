#!/bin/bash
# setup-server.sh
# Linux 서버에서 SSH 터널을 확인하고 tunnel-source를 등록합니다.
# 사용법: ./setup-server.sh [--auto] [--port PORT]
set -e

PORT="24713"
AUTO=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --auto) AUTO=1; shift ;;
    --port) PORT="$2"; shift 2 ;;
    [0-9]*) PORT="$1"; shift ;;
    --help|-h)
      echo "Usage: ./setup-server.sh [--auto] [--port PORT]"
      echo ""
      echo "  --auto    서버 ~/.bashrc에 자동 로드 스크립트 추가"
      echo "  --port    SSH 터널 포트 (default: 24713)"
      exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${GREEN}Claude Code Voice Mode - Server Setup${NC}"
echo ""

# ── 1. Check tunnel port ──
echo -e "${BLUE}[1/4]${NC} SSH 터널 확인 (port $PORT)..."
if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
  echo -e "${GREEN}  ✓${NC} port $PORT LISTEN"
else
  echo -e "${RED}  ✗${NC} port $PORT not listening"
  echo ""
  echo "  WSL에서 SSH 접속 시 리버스 터널을 포함했는지 확인:"
  echo "  ssh -R ${PORT}:localhost:4713 user@$(hostname)"
  if [ "$AUTO" -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}  --auto 설정은 터널 없이도 진행합니다.${NC}"
  else
    exit 1
  fi
fi

# ── 2. Test PulseAudio via tunnel ──
echo -e "${BLUE}[2/4]${NC} PulseAudio 연결 테스트..."
if ss -tlnp 2>/dev/null | grep -q ":${PORT}" && pactl -s "tcp:localhost:${PORT}" info &>/dev/null; then
  SERVER=$(pactl -s "tcp:localhost:${PORT}" info | grep "Server Name" | cut -d: -f2-)
  echo -e "${GREEN}  ✓${NC} $SERVER"
else
  echo -e "${YELLOW}  ⚠${NC} 현재 연결 불가 (터널 미활성 시 정상)"
fi

# ── 3. Load tunnel-source ──
echo -e "${BLUE}[3/4]${NC} tunnel-source 등록..."
if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
  # Unload stale module if exists
  if pactl list modules short 2>/dev/null | grep -q "module-tunnel-source"; then
    CURRENT=$(pactl list sources short 2>/dev/null | grep "tunnel-source" || true)
    if echo "$CURRENT" | grep -q "SUSPENDED\|FAILED"; then
      pactl unload-module module-tunnel-source 2>/dev/null || true
      echo -e "${YELLOW}  ↻${NC} 기존 모듈 재로드 중..."
    elif echo "$CURRENT" | grep -q "RUNNING\|IDLE"; then
      echo -e "${GREEN}  ✓${NC} 이미 정상 동작 중"
    fi
  fi

  if ! pactl list modules short 2>/dev/null | grep -q "module-tunnel-source"; then
    MODULE_ID=$(pactl load-module module-tunnel-source "server=tcp:localhost:${PORT}" 2>/dev/null || true)
    if [ -n "$MODULE_ID" ]; then
      echo -e "${GREEN}  ✓${NC} module ID: $MODULE_ID"
    else
      echo -e "${RED}  ✗${NC} 모듈 로드 실패"
    fi
  fi

  pactl set-default-source "tunnel-source.tcp:localhost:${PORT}" 2>/dev/null && \
    echo -e "${GREEN}  ✓${NC} 기본 소스 설정 완료" || true
else
  echo -e "${YELLOW}  ⚠${NC} 터널 미활성 - 모듈 로드 스킵"
fi

# ── 4. Auto-load setup ──
echo -e "${BLUE}[4/4]${NC} 자동화 설정..."

SHELL_RC="$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"

MARKER="# Claude Code Voice Mode - tunnel-source auto"

if grep -q "$MARKER" "$SHELL_RC" 2>/dev/null; then
  if [ "$AUTO" -eq 1 ]; then
    echo -e "${GREEN}  ✓${NC} 이미 설정됨 ($SHELL_RC)"
  else
    echo -e "${GREEN}  ✓${NC} 자동 로드 이미 설정됨"
  fi
elif [ "$AUTO" -eq 1 ]; then
  cat >> "$SHELL_RC" << AUTOEOF

${MARKER}
_claude_voice_tunnel() {
  local port="${PORT}"
  if ! ss -tlnp 2>/dev/null | grep -q ":\${port}"; then
    return
  fi
  local src
  src=\$(pactl list sources short 2>/dev/null | grep "tunnel-source" || true)
  if [ -n "\$src" ]; then
    if echo "\$src" | grep -q "RUNNING\|IDLE"; then
      return
    fi
    pactl unload-module module-tunnel-source 2>/dev/null
  fi
  pactl load-module module-tunnel-source "server=tcp:localhost:\${port}" 2>/dev/null
  pactl set-default-source "tunnel-source.tcp:localhost:\${port}" 2>/dev/null
}
_claude_voice_tunnel
AUTOEOF
  echo -e "${GREEN}  ✓${NC} 자동 로드 스크립트 추가됨 ($SHELL_RC)"
else
  echo -e "${YELLOW}  ⚠${NC} 자동화 미설정 (--auto 플래그로 설정 가능)"
fi

# ── Result ──
echo ""
echo -e "${GREEN}서버 설정 완료!${NC}"
echo ""
echo "소스 목록:"
pactl list sources short 2>/dev/null
echo ""
if [ "$AUTO" -eq 1 ]; then
  echo "다음 SSH 접속부터 tunnel-source가 자동으로 등록됩니다."
else
  echo "다음: Docker 컨테이너에서 setup-docker.sh 실행"
  echo "팁:   ./setup-server.sh --auto 로 자동화 설정"
fi
echo ""
