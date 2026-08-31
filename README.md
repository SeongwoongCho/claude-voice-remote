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

## 매번 SSH 접속 시 해야 할 것

### 자동화된 부분 (한 번 설정하면 끝)

- [x] SSH config의 `RemoteForward` → SSH 접속 시 자동 터널
- [x] Docker `~/.asoundrc`, `~/.config/pulse/client.conf` → 영구
- [x] Docker `~/.zshrc`의 `PULSE_SERVER` → 영구

### 수동으로 해야 할 것

SSH 접속 후 **Linux 서버**에서:

```bash
pactl load-module module-tunnel-source server=tcp:localhost:24713
```

> 서버 PulseAudio/PipeWire가 재시작되면 tunnel-source가 사라지므로 다시 로드해야 합니다.

#### 서버에서도 자동화하려면

```bash
# ~/.bashrc 또는 ~/.zshrc에 추가 (Linux 서버)
if ! pactl list modules short 2>/dev/null | grep -q "module-tunnel-source"; then
  pactl load-module module-tunnel-source server=tcp:localhost:24713 2>/dev/null
fi
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
