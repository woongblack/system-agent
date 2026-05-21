#!/bin/bash
# 파일명: setup.sh
# 실행 방법: sudo bash setup.sh
# (주의: 맥북 실리콘 M1/M2/M3 계열이면 아키텍처에 맞게 agent-app-linux-arm64 파일을 준비해 두세요.)

set -e # 도중에 에러가 발생하면 스크립트를 즉시 중단합니다.

echo "===================================================="
echo "OrbStack VM 내 인프라 구축 및 관제 자동화 세팅 시작"
echo "===================================================="

# 변수 정의
AGENT_HOME="/home/agent-admin/agent-app"
AGENT_LOG_DIR="/var/log/agent-app"

# 1. 역할 기반 계정 및 그룹 생성
echo "[1/7] 계정 및 협업 그룹 생성 중..."
groupadd -f agent-common
groupadd -f agent-core

id agent-admin &>/dev/null || useradd -m -g agent-common -G agent-core,sudo -s /bin/bash agent-admin
id agent-dev &>/dev/null || useradd -m -g agent-common -G agent-core -s /bin/bash agent-dev
id agent-test &>/dev/null || useradd -m -g agent-common -s /bin/bash agent-test

# 테스트용 패스워드 일괄 설정 (원하는 비밀번호로 변경 가능)
echo "agent-admin:password" | chpasswd
echo "agent-dev:password" | chpasswd
echo "agent-test:password" | chpasswd


# 2. 전역 시스템 환경 변수 표준화 설정
echo "[2/7] 시스템 전역 환경 변수 주입 중..."
cat << 'EOF' > /etc/profile.d/agent_env.sh
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files
export AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
EOF
chmod 644 /etc/profile.d/agent_env.sh
source /etc/profile.d/agent_env.sh


# 3. 디렉토리 트리 구조 생성 및 최소 권한(ACL) 설정
echo "[3/7] 디렉토리 보안 및 접근 제어 정책 적용 중..."
mkdir -p $AGENT_HOME/upload_files $AGENT_HOME/api_keys $AGENT_HOME/bin $AGENT_LOG_DIR

chown -R agent-admin:agent-core $AGENT_HOME
chown -R agent-admin:agent-core $AGENT_LOG_DIR

chmod 711 /home/agent-admin
chmod 750 $AGENT_HOME
chmod 770 $AGENT_HOME/upload_files  # common 그룹 R/W 가능
chmod 750 $AGENT_HOME/api_keys      # core 그룹만 접근 가능
chmod 750 $AGENT_LOG_DIR             # core 그룹만 접근 가능


# 4. 필수 API 보안 키 파일 생성
echo "[4/7] 보안 인증용 API 키 파일 생성 중..."
echo "agent_api_key_test" > $AGENT_HOME/api_keys/secret.key
chown agent-admin:agent-core $AGENT_HOME/api_keys/secret.key
chmod 640 $AGENT_HOME/api_keys/secret.key


# 5. 제공된 실행 바이너리 배치 (Mac 사양에 맞춤 처리)
echo "[5/7] 미션 제공 바이너리 파일 배치 중..."
# VM 아키텍처에 맞는 바이너리를 자동 선택해 복사합니다.
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] && [ -f "agent-app-linux-arm64" ]; then
    cp agent-app-linux-arm64 $AGENT_HOME/bin/agent-app
    echo "... arm64 바이너리 선택 (아키텍처: $ARCH)"
elif [ "$ARCH" = "x86_64" ] && [ -f "agent-app-linux-x86" ]; then
    cp agent-app-linux-x86 $AGENT_HOME/bin/agent-app
    echo "... x86_64 바이너리 선택 (아키텍처: $ARCH)"
else
    echo "[WARNING] 제공된 에이전트 바이너리 파일이 현재 디렉토리에 없습니다!"
    echo "동작을 위해 파일을 $AGENT_HOME/bin/agent-app 경로에 수동으로 넣어주셔야 합니다."
fi

# 바이너리 권한 설정
if [ -f "$AGENT_HOME/bin/agent-app" ]; then
    chown agent-admin:agent-core $AGENT_HOME/bin/agent-app
    chmod 750 $AGENT_HOME/bin/agent-app
fi


# 6. 기동 스크립트 및 관제 스크립트 코드 생성 및 권한 위임
echo "[6/7] 실행 및 관제 자동화 스크립트 소스코드 생성 중..."

# 6-1. agent-start.sh 생성
cat << 'EOF' > $AGENT_HOME/bin/agent-start.sh
#!/bin/bash
source /etc/profile.d/agent_env.sh
if [ "$(whoami)" = "root" ]; then
    echo "[ERROR] 루트 계정 실행은 금지됩니다."
    exit 1
fi
echo "Launching Agent Binary..."
nohup $AGENT_HOME/bin/agent-app > /dev/null 2>&1 &
sleep 2
if ss -tuln | grep -q ":$AGENT_PORT "; then
    echo "Agent READY (Port $AGENT_PORT Listening)"
else
    echo "[ERROR] Boot Sequence 검증 실패. 환경 변수와 키 파일 권한을 확인하세요."
fi
EOF
chown agent-admin:agent-core $AGENT_HOME/bin/agent-start.sh
chmod 750 $AGENT_HOME/bin/agent-start.sh

# 6-2. monitor.sh 생성 (소유자: agent-dev, 그룹: agent-core)
cat << 'EOF' > $AGENT_HOME/bin/monitor.sh
#!/bin/bash
source /etc/profile.d/agent_env.sh
NOW=$(date "+%Y-%m-%d %H:%M:%S")
LOG_FILE="$AGENT_LOG_DIR/monitor.log"

PID=$(pgrep -f "bin/agent-app" | head -1)
if [ -z "$PID" ]; then
    echo "[$NOW] [ERROR] agent-app binary is not running!" >> $LOG_FILE
    exit 1
fi
PORT_CHECK=$(ss -tuln | grep ":$AGENT_PORT ")
if [ -z "$PORT_CHECK" ]; then
    echo "[$NOW] [ERROR] Port $AGENT_PORT is not listening!" >> $LOG_FILE
    exit 1
fi

UFW_ENABLED=$(grep "^ENABLED=" /etc/ufw/ufw.conf 2>/dev/null | cut -d= -f2)
if [ "$UFW_ENABLED" != "yes" ]; then
    echo "[$NOW] [WARNING] Firewall (UFW) is inactive!" >> $LOG_FILE
fi

CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' | cut -d. -f1)
[ -z "$CPU_USAGE" ] && CPU_USAGE=0
MEM_USED=$(free | grep Mem | awk '{print $3}')
MEM_TOTAL=$(free | grep Mem | awk '{print $2}')
MEM_USAGE=$(( MEM_USED * 100 / MEM_TOTAL ))
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')

if [ "$CPU_USAGE" -gt 20 ]; then echo "[$NOW] [WARNING] CPU threshold exceeded (${CPU_USAGE}% > 20%)" >> $LOG_FILE; fi
if [ "$MEM_USAGE" -gt 10 ]; then echo "[$NOW] [WARNING] MEMORY threshold exceeded (${MEM_USAGE}% > 10%)" >> $LOG_FILE; fi
if [ "$DISK_USAGE" -gt 80 ]; then echo "[$NOW] [WARNING] DISK threshold exceeded (${DISK_USAGE}% > 80%)" >> $LOG_FILE; fi

echo "[$NOW] PID:$PID CPU:${CPU_USAGE}% MEM:${MEM_USAGE}% DISK_USED:${DISK_USAGE}%" >> $LOG_FILE
EOF
chown agent-dev:agent-core $AGENT_HOME/bin/monitor.sh
chmod 750 $AGENT_HOME/bin/monitor.sh


# 7. 네트워크 방화벽(UFW), 로그 백업 정책 및 크론탭 자동화 최종 가동
echo "[7/7] SSH 보안 정책 변경, UFW 방화벽 및 크론탭 스케줄러 등록 중..."
# openssh-server 설치 (없을 경우)
if ! dpkg -l openssh-server 2>/dev/null | grep -q '^ii'; then
    apt-get install -y openssh-server
fi
# SSH 포트 및 Root 원격 접속 제한
sed -i 's/^#\?Port .*/Port 20022/' /etc/ssh/sshd_config
if grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
    echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
fi
systemctl restart sshd || true

# UFW 설치 (없을 경우)
if ! command -v ufw &>/dev/null; then
    apt-get install -y ufw
fi

# 방화벽 정책 규칙 활성화
ufw allow 20022/tcp
ufw allow 15034/tcp
ufw --force enable

# logrotate 규칙 설정 (최대 10MB, 10개 유지 관리 정책)
cat << 'EOF' > /etc/logrotate.d/agent-app
/var/log/agent-app/monitor.log {
    size 10M
    rotate 10
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0660 agent-admin agent-core
}
EOF

# agent-admin 계정의 크론탭 스케줄러에 1분 주기 자동화 등록
echo "* * * * * /home/agent-admin/agent-app/bin/monitor.sh" | crontab -u agent-admin -

echo "===================================================="
echo "인프라 구축 완료! 서비스 엔진을 기동합니다."
echo "===================================================="

# agent-admin 일반 권한으로 바이너리 최초 실행
su - agent-admin -c "cd /home/agent-admin/agent-app/bin && ./agent-start.sh"

echo ">>> [성공] 모든 인프라 세팅 및 앱 가동이 끝났습니다! <<<"
