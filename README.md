# Claude Code Voice Mode over SSH + Docker

원격 서버의 Docker 컨테이너에서 실행 중인 Claude Code에서 **네이티브 보이스 모드**(`/voice` + `Space`)를 사용할 수 있도록 PulseAudio 오디오 파이프라인을 구성하는 가이드입니다.

## 문제

Claude Code의 보이스 모드는 **로컬 마이크가 필요**합니다. 공식 문서에 따르면:

> "Voice dictation does not work in remote environments such as SSH sessions."

하지만 PulseAudio 네트워크 포워딩을 이용하면 원격 환경에서도 동작시킬 수 있습니다.

## 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                        Audio Pipeline                           │
│                                                                 │
│  ┌──────────┐    ┌──────────────┐    ┌────────────────────────┐│
│  │ Windows  │    │ Linux Server │    │   Docker Container     ││
│  │ (WSL)    │    │              │    │                        ││
│  │          │    │              │    │  Claude Code           ││
│  │ 🎤 마이크 │◄──│  PipeWire/   │◄──│  audio-capture.node    ││
│  │          │    │  PulseAudio  │    │  (ALSA PCM)            ││
│  │ Pulse    │    │              │    │       │                ││
│  │ Audio    │    │  tunnel-     │    │       ▼                ││
│  │ :4713    │◄──│  source      │    │  ~/.asoundrc           ││
│  │          │ SSH│  :24713      │    │  (ALSA→PulseAudio)     ││
│  │          │ -R │              │    │       │                ││
│  │          │    │  :4713 ◄─────│────│  PULSE_SERVER          ││
│  └──────────┘    └──────────────┘    │  tcp:172.17.0.1:4713   ││
│                                      └────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

**데이터 흐름:**

```
Space 키 → Claude Code audio-capture.node (ALSA PCM)
  → ALSA PulseAudio 플러그인 (~/.asoundrc)
  → PulseAudio 클라이언트 (tcp:172.17.0.1:4713)
  → 호스트 PipeWire/PulseAudio
  → tunnel-source (tcp:localhost:24713)
  → SSH 리버스 터널 (-R 24713:localhost:4713)
  → WSL PulseAudio 서버 (:4713)
  → Windows 마이크
```

## 사전 요구사항

| 구성 요소 | 요구사항 |
|-----------|---------|
| **Windows** | Windows 10 21H2+ 또는 Windows 11 (WSLg 지원) |
| **WSL** | WSL2 + PulseAudio (WSLg에 기본 포함) |
| **Linux 서버** | PulseAudio 또는 PipeWire + PulseAudio 호환 레이어 |
| **Docker** | `apt-get` 사용 가능한 컨테이너 (Ubuntu/Debian 기반) |
| **SSH** | OpenSSH 클라이언트 (리버스 터널 지원) |

## 설정

### Step 1: WSL 설정 (Windows 측)

WSL 터미널에서 실행:

```bash
# PulseAudio 동작 확인
pactl info

# TCP 리스닝 모듈 로드
pactl load-module module-native-protocol-tcp \
  auth-ip-acl=127.0.0.1 \
  auth-anonymous=1

# 포트 확인 (4713에서 LISTEN이 보여야 함)
ss -tlnp | grep 4713
```

**PulseAudio가 없는 경우:**

```bash
# Ubuntu/Debian WSL
sudo apt-get install pulseaudio

# 시작
pulseaudio --start
```

> **참고:** WSLg가 활성화된 WSL2에서는 PulseAudio가 기본으로 실행됩니다.

#### TCP 모듈 자동 로드 (영구 설정)

```bash
# WSL에서 실행
mkdir -p ~/.config/pulse
echo "load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
  >> ~/.config/pulse/default.pa
```

### Step 2: SSH 설정

#### 방법 A: SSH config에 영구 설정 (권장)

`~/.ssh/config` (WSL측)에 추가:

```ssh-config
Host your-server
    HostName 192.168.x.x
    User your-username
    RemoteForward 24713 localhost:4713
```

SSH 연결이 끊기면 터널도 같이 죽으므로 **keepalive 설정을 권장**합니다:

```ssh-config
Host your-server
    HostName 192.168.x.x
    User your-username
    RemoteForward 24713 localhost:4713
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

이후 `ssh your-server`로 접속하면 자동으로 리버스 터널이 잡힙니다.

#### 방법 B: 명령줄에서 직접 지정

```bash
ssh -R 24713:localhost:4713 user@your-server
```

#### 방법 C: 기존 SSH 세션에 터널 추가 (재접속 없이)

SSH 세션 안에서 `~C` (틸드 + 대문자 C) 입력:

```
ssh> -R 24713:localhost:4713
Forwarding port.
```

> **주의:** `~C`는 줄 시작에서만 동작합니다. Enter를 먼저 누르세요.

#### 방법 D: 영구 터널 — 터미널 꺼도 유지 (권장)

일반 SSH 세션은 터미널을 닫으면 같이 끊깁니다. `autossh`를 사용하면 **터미널 종료, 네트워크 끊김에도 자동 재접속**됩니다.

**autossh 설치 (WSL에서):**

```bash
sudo apt-get install autossh
```

**백그라운드 터널 실행:**

```bash
autossh -M 0 -f -N \
  -o "ServerAliveInterval=60" \
  -o "ServerAliveCountMax=3" \
  -R 24713:localhost:4713 \
  your-server
```

| 플래그 | 의미 |
|--------|------|
| `-M 0` | OS의 TCP keepalive 사용 (별도 모니터 포트 불필요) |
| `-f` | 백그라운드 실행 |
| `-N` | 셸 안 열고 터널만 유지 |

**터널 확인/종료:**

```bash
# 확인
ps aux | grep autossh

# 종료
pkill -f "autossh.*24713"
```

##### Windows 로그인 시 자동 실행 (systemd)

WSL에서 systemd가 활성화되어 있으면 (`systemctl` 동작 확인):

```bash
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/claude-voice-tunnel.service << 'EOF'
[Unit]
Description=Claude Voice SSH Tunnel (autossh)
After=network.target

[Service]
ExecStart=/usr/bin/autossh -M 0 -N -o "ServerAliveInterval=60" -o "ServerAliveCountMax=3" -R 24713:localhost:4713 your-server
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable claude-voice-tunnel
systemctl --user start claude-voice-tunnel
```

```bash
# 상태 확인
systemctl --user status claude-voice-tunnel

# 로그
journalctl --user -u claude-voice-tunnel -f
```

##### Windows 로그인 시 자동 실행 (systemd 없는 경우)

WSL `~/.bashrc`에 추가:

```bash
# Claude Voice Tunnel - autossh 자동 시작
if ! pgrep -f "autossh.*24713" &>/dev/null; then
  autossh -M 0 -f -N \
    -o "ServerAliveInterval=60" \
    -o "ServerAliveCountMax=3" \
    -R 24713:localhost:4713 \
    your-server 2>/dev/null
fi
```

WSL 터미널을 처음 열 때 자동으로 터널이 시작됩니다.

### Step 3: Linux 서버 설정 (Docker 외부)

SSH 접속 후 서버에서 실행:

```bash
# SSH 터널 확인
ss -tlnp | grep 24713

# PulseAudio 연결 테스트
pactl -s tcp:localhost:24713 info

# WSL 마이크를 서버 PulseAudio에 터널 소스로 등록
pactl load-module module-tunnel-source server=tcp:localhost:24713
```

`pactl info`에서 서버 정보가 보이면 터널이 정상 동작 중입니다.

#### 터널 소스 확인

```bash
# 소스 목록에 tunnel-source가 보여야 함
pactl list sources short

# 기본 소스로 설정
pactl set-default-source tunnel-source.tcp:localhost:24713
```

### Step 4: Docker 컨테이너 설정

**자동 설정 (스크립트 사용):**

```bash
# 레포 클론 후
chmod +x setup-docker.sh
./setup-docker.sh
```

**수동 설정:**

```bash
# 1. 패키지 설치
apt-get update
apt-get install -y libasound2-plugins pulseaudio-utils

# 2. ALSA → PulseAudio 브릿지 설정
cat > ~/.asoundrc << 'EOF'
pcm.default pulse
ctl.default pulse

pcm.pulse {
    type pulse
}

ctl.pulse {
    type pulse
}
EOF

# 3. PulseAudio 클라이언트 설정
mkdir -p ~/.config/pulse
cat > ~/.config/pulse/client.conf << 'EOF'
default-server = tcp:172.17.0.1:4713
autospawn = no
daemon-binary = /bin/true
EOF

# 4. 환경변수 설정
echo 'export PULSE_SERVER="tcp:172.17.0.1:4713"' >> ~/.zshrc
source ~/.zshrc
```

> **`172.17.0.1`** 은 Docker 기본 게이트웨이 IP입니다. 다른 네트워크 설정을 사용하는 경우 `ip route | grep default | awk '{print $3}'`으로 확인하세요.

### Step 5: 테스트

Docker 컨테이너에서:

```bash
# PulseAudio 연결 확인
pactl info

# 녹음 테스트 (2초)
parecord --channels=1 --rate=16000 --format=s16le /tmp/test.raw --duration=2
ls -la /tmp/test.raw  # 64000 bytes 정도면 정상

# Claude Code에서 보이스 모드 사용
claude
# Claude Code 안에서:
# /voice → Space 키로 말하기
```

## 포트 가이드

| 포트 | 위치 | 용도 |
|------|------|------|
| **4713** | WSL | PulseAudio TCP 서버 (기본 포트) |
| **24713** | Linux 서버 | SSH 리버스 터널 (WSL→서버) |
| **4713** | Linux 서버 | PipeWire/PulseAudio (컨테이너→호스트) |

> **중요:** Docker가 매핑한 포트 범위(예: 10040-10059)와 SSH 터널 포트가 겹치면 안 됩니다. Docker 포트 매핑이 SSH 터널보다 우선하여 연결이 실패합니다.

## 재접속 시 자동화

SSH 접속을 끊었다 다시 연결하면 터널과 tunnel-source가 모두 초기화됩니다. 아래 설정으로 **전체 자동화**할 수 있습니다.

### 자동화 체크리스트

| 구성 요소 | 자동화 | 설정 위치 |
|-----------|--------|-----------|
| SSH 리버스 터널 | `RemoteForward` | WSL `~/.ssh/config` |
| SSH keepalive | `ServerAliveInterval` | WSL `~/.ssh/config` |
| WSL PulseAudio TCP | `default.pa` | WSL `~/.config/pulse/default.pa` |
| 서버 tunnel-source | `.bashrc` 스크립트 | 서버 `~/.bashrc` |
| Docker ALSA/PulseAudio | `setup-docker.sh` | Docker (1회) |
| Docker `PULSE_SERVER` | `.zshrc` | Docker (1회) |

### 서버 자동화 (핵심)

`setup-server.sh --auto`를 실행하면 서버 `~/.bashrc`에 자동 로드 스크립트가 추가됩니다.

또는 수동으로 **Linux 서버**의 `~/.bashrc` (또는 `~/.zshrc`)에 추가:

```bash
# Claude Code Voice Mode - tunnel-source 자동 등록
# SSH 리버스 터널(24713)이 열려있으면 tunnel-source를 자동으로 로드/재로드
_claude_voice_tunnel() {
  local port="${CLAUDE_VOICE_TUNNEL_PORT:-24713}"
  if ! ss -tlnp 2>/dev/null | grep -q ":${port}"; then
    return
  fi
  local current_src
  current_src=$(pactl list sources short 2>/dev/null | grep "tunnel-source" || true)
  if [ -n "$current_src" ]; then
    if echo "$current_src" | grep -q "RUNNING\|IDLE"; then
      return  # 이미 정상 동작 중
    fi
    # SUSPENDED/FAILED 상태면 재로드
    pactl unload-module module-tunnel-source 2>/dev/null
  fi
  pactl load-module module-tunnel-source "server=tcp:localhost:${port}" 2>/dev/null
  pactl set-default-source "tunnel-source.tcp:localhost:${port}" 2>/dev/null
}
_claude_voice_tunnel
```

이 스크립트는:
1. SSH 터널 포트(24713)가 열려있는지 확인
2. tunnel-source가 이미 정상이면 스킵
3. SUSPENDED/FAILED 상태면 재로드
4. 터널이 없으면 아무것도 안 함 (일반 SSH 접속에 영향 없음)

### WSL 자동화

WSL `~/.config/pulse/default.pa`에 추가하면 PulseAudio TCP 모듈이 자동 로드됩니다:

```bash
mkdir -p ~/.config/pulse
echo "load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
  >> ~/.config/pulse/default.pa
```

### 완전 자동화 후 워크플로우

모든 자동화 설정이 끝나면:

```bash
# WSL에서 SSH 접속 (이것만 하면 됨)
ssh your-server

# 서버 로그인 시 자동으로 tunnel-source 등록됨
# Docker 컨테이너 진입 후 바로 사용 가능
claude
# /voice → Space
```

## 트러블슈팅

### "Connection refused"

```bash
# 1. WSL에서 PulseAudio TCP 확인
pactl info                    # PulseAudio 동작?
ss -tlnp | grep 4713          # TCP 모듈 리스닝?

# 2. 서버에서 SSH 터널 확인
ss -tlnp | grep 24713         # 터널 포트 열림?
pactl -s tcp:localhost:24713 info  # 터널 통해 연결?

# 3. Docker에서 호스트 연결 확인
timeout 1 bash -c "echo > /dev/tcp/172.17.0.1/4713" && echo "OK" || echo "FAIL"
```

### "Connection terminated"

- Docker 포트 매핑과 SSH 터널 포트 충돌 → 다른 포트 사용
- PulseAudio 인증 실패 → `auth-anonymous=1` 확인

### 재접속 후 보이스 모드 안 됨

SSH를 끊었다 다시 접속하면 터널이 초기화됩니다:
1. WSL → 서버 SSH 재접속 (`RemoteForward` 포함)
2. 서버에서 `pactl unload-module module-tunnel-source && pactl load-module module-tunnel-source server=tcp:localhost:24713`
3. 또는 `setup-server.sh --auto`로 자동화 설정

### SSH 터널이 자주 끊김

`~/.ssh/config`에 keepalive 추가:
```ssh-config
Host your-server
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

### 녹음은 되지만 무음

- Windows 마이크 음소거 확인
- Windows 사운드 설정에서 마이크 입력 레벨 확인
- WSL에서 `parecord --duration=2 /tmp/test.wav && paplay /tmp/test.wav`로 로컬 테스트

### Docker 게이트웨이 IP 확인

```bash
# Docker 컨테이너 안에서
cat /etc/hosts | grep host.docker.internal
ip route | grep default | awk '{print $3}'
# 또는 일반적으로 172.17.0.1
```

### 서버에 PulseAudio/PipeWire가 없는 경우

```bash
# PulseAudio 설치 (Ubuntu/Debian)
sudo apt-get install pulseaudio

# 사용자 서비스로 시작
pulseaudio --start --exit-idle-time=-1
```

## Claude Code 보이스 모드 설정

Claude Code 내에서 보이스 모드 세부 설정:

```bash
# ~/.claude/settings.json
{
  "voice": {
    "enabled": true,
    "mode": "hold",        # "hold" (길게 누르기) 또는 "tap" (토글)
    "autoSubmit": true      # 녹음 종료 시 자동 전송
  }
}
```

키 바인딩 변경:

```bash
# ~/.claude/keybindings.json
{
  "bindings": [
    {
      "context": "Chat",
      "bindings": {
        "meta+k": "voice:pushToTalk"
      }
    }
  ]
}
```

## 검증된 환경

- Windows 11 + WSL2 (Ubuntu 22.04) + WSLg
- Linux 서버: Ubuntu 22.04, PipeWire 1.0.5
- Docker: Ubuntu 22.04 기반 컨테이너
- Claude Code 2.1.x

## 라이선스

MIT
