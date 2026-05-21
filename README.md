# [요구사항 수행 내역서] 리눅스 서버 인프라 구축 및 관제 자동화

## 1. 개요 (Overview)
본 보고서는 다중 사용자 환경에서의 안전한 서버 보안 체계 구축, 역할 기반 접근 제어(RBAC) 설계, 애플리케이션 실행 환경 최적화, 그리고 시스템 관제 자동화 스크립트 개발에 대한 요구사항 수행 내역을 종합적으로 기록한 문서이다.

서버 장애 발생 시 데이터 기반의 신속한 장애 복구(Root Cause Analysis)가 가능하도록 로그 자동화 수집 환경을 구축하였으며, 인프라의 기본 보안 정책 및 최소 권한 원칙(Principle of Least Privilege)을 철저히 준수하여 설계하였다.

- **실행 환경**: OrbStack Ubuntu VM (x86_64) on macOS
- **자동화 스크립트**: `setup.sh` 단일 실행으로 전체 인프라 구축

---

## 2. 기본 보안 및 네트워크 설정 (Security & Network Setup)

### 2.1 SSH 서버 보안 고도화
원격 인프라 관리의 핵심 관문인 SSH 서비스의 취약점을 보완하기 위해 기본 포트(22)를 비표준 포트 `20022`로 변경하고, `root` 계정의 직접 원격 로그인을 원천 차단하였다.

- **설정 파일 경로**: `/etc/ssh/sshd_config`
- **주요 수정 내역**:
  ```bash
  Port 20022
  PermitRootLogin no
  ```

#### [증거 자료 01: SSH 설정 파일 확인]
```text
root@ubuntu:/# grep -E '^Port|^PermitRootLogin' /etc/ssh/sshd_config
Port 20022
PermitRootLogin no
```

---

### 2.2 방화벽(UFW) 정책 수립 및 포트 화이트리스트 구성
`UFW`를 활성화하고, 서비스 운영 및 원격 관리에 필요한 포트만 선별하여 허용하였다.

- **방화벽 설정 명령어**:
  ```bash
  ufw allow 20022/tcp
  ufw allow 15034/tcp
  ufw --force enable
  ```

#### [증거 자료 02: UFW 방화벽 활성화 및 포트 리슨 상태 확인]
```text
root@ubuntu:/# ufw status
Status: active

To                         Action      From
--                         ------      ----
20022/tcp                  ALLOW       Anywhere
15034/tcp                  ALLOW       Anywhere
20022/tcp (v6)             ALLOW       Anywhere (v6)
15034/tcp (v6)             ALLOW       Anywhere (v6)
```
현업에서는 해커가 비밀번호를 5번 이상 틀리면 시스템이 알아서 그 해커의 IP를 방화벽 블랙리스트에 추가해 버리는 **Fail2Ban**이라는 자동화 프로그램을 이 방화벽(UFW)과 연동해서 씁니다.

---

## 3. 계정 / 그룹 / 권한 체계 구축 (Access Control)

### 3.1 역할 기반 사용자 계정 및 협업 그룹 설계
인프라 다중 사용자 보안 강화를 위해 사용자를 분류하고 권한 그룹을 이원화하였다.
- `agent-admin` (관리자/sudo), `agent-dev` (개발자), `agent-test` (테스터)
- `agent-common` (공통 그룹), `agent-core` (핵심 그룹)

#### [증거 자료 03: 계정 및 소속 그룹 정보 검증]
각 계정에 맞춘 그룹 분리가 정확히 이루어졌음을 확인하였다.
```text
root@ubuntu:/# id agent-admin
uid=1000(agent-admin) gid=1000(agent-common) groups=1000(agent-common),27(sudo),1001(agent-core)

root@ubuntu:/# id agent-dev
uid=1001(agent-dev) gid=1000(agent-common) groups=1000(agent-common),1001(agent-core)

root@ubuntu:/# id agent-test
uid=1002(agent-test) gid=1000(agent-common) groups=1000(agent-common)
```

---

### 3.2 디렉토리 구조 정의 및 접근 제어 목록(ACL) 수립
애플리케이션 홈 디렉토리(`$AGENT_HOME`) 구조에 대해 그룹별 파일 보안 수준을 적용하였다.

#### [증거 자료 04: 디렉토리 경로 소유권 및 권한 상태 확인]
핵심 폴더인 `api_keys`는 core 그룹 전용으로, `upload_files`는 common 그룹용으로 권한이 할당되었다.
```text
root@ubuntu:/# ls -l /home/agent-admin/agent-app
drwxr-x--- 1 agent-admin agent-core  20 May 21 16:26 api_keys
drwxr-xr-x 1 agent-admin agent-core  66 May 21 16:22 bin
drwxrwx--- 1 agent-admin agent-core   0 May 21 16:22 upload_files
```

---

### 3.3 최소 권한 원칙(Principle of Least Privilege) 실증 검증
테스트 계정(`agent-test`)이 관리자 권한 명령(`sudo`)을 실행하는 것을 원천 거부하도록 설계하였다.

#### [증거 자료 05: 일반 계정의 Sudoers 제한 및 권한 거부 예시]
```text
agent-test@ubuntu:~$ sudo su -
[sudo] password for agent-test:
agent-test is not in the sudoers file.  This incident will be reported.
```

---

## 4. 애플리케이션 실행 환경 구성 (Environment Setup)

### 4.1 시스템 환경 변수 표준화
전역 설정 파일 `/etc/profile.d/agent_env.sh`를 생성하여 환경 변수를 표준화하였다.
```bash
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files
export AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
```

### 4.2 서비스 기동 및 Boot Sequence 검증
일반 관리 계정(`agent-admin`)으로 애플리케이션 기동 시퀀스 무결성을 검증하였다.

#### [증거 자료 06: 애플리케이션 Boot Sequence 5단계 [OK] 통과 화면]
```text
agent-admin@ubuntu:~/agent-app/bin$ ./agent-app
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=1000)
[2/5] Verifying Environment Variables     [OK]
   ... All required Envs correct
[3/5] Checking Required Files             [OK]
   ... Verified 'secret.key' with correct key string.
[4/5] Checking Port Availability          [OK]
   ... Port 15034 is available.
[5/5] Verifying Log Permission            [OK]
   ... Log directory is writable: /var/log/agent-app
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

---

## 5. 시스템 관제 자동화 스크립트 구현 (Automation Script)

### 5.1 관제 자동화 스크립트 소스 코드 (`monitor.sh`)
UFW 상태를 비root 계정에서도 안전하게 확인하기 위해 `/etc/ufw/ufw.conf` 설정 파일을 직접 읽는 방식을 채택하였다. 이를 통해 `ufw status` 명령의 root 권한 의존성을 제거하였다.

```bash
#!/bin/bash
source /etc/profile.d/agent_env.sh
NOW=$(date "+%Y-%m-%d %H:%M:%S")
LOG_FILE="$AGENT_LOG_DIR/monitor.log"

# 프로세스 및 포트 헬스체크
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

# 방화벽 상태 점검 (설정 파일 직접 확인 - root 권한 불필요)
UFW_ENABLED=$(grep "^ENABLED=" /etc/ufw/ufw.conf 2>/dev/null | cut -d= -f2)
if [ "$UFW_ENABLED" != "yes" ]; then
    echo "[$NOW] [WARNING] Firewall (UFW) is inactive!" >> $LOG_FILE
fi

# 자원 수집
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' | cut -d. -f1)
[ -z "$CPU_USAGE" ] && CPU_USAGE=0
MEM_USED=$(free | grep Mem | awk '{print $3}')
MEM_TOTAL=$(free | grep Mem | awk '{print $2}')
MEM_USAGE=$(( MEM_USED * 100 / MEM_TOTAL ))
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')

# 임계값 설정 및 경고 출력 로직
if [ "$CPU_USAGE" -gt 20 ]; then echo "[$NOW] [WARNING] CPU threshold exceeded (${CPU_USAGE}% > 20%)" >> $LOG_FILE; fi
if [ "$MEM_USAGE" -gt 10 ]; then echo "[$NOW] [WARNING] MEMORY threshold exceeded (${MEM_USAGE}% > 10%)" >> $LOG_FILE; fi
if [ "$DISK_USAGE" -gt 80 ]; then echo "[$NOW] [WARNING] DISK threshold exceeded (${DISK_USAGE}% > 80%)" >> $LOG_FILE; fi

# 상태 기록
echo "[$NOW] PID:$PID CPU:${CPU_USAGE}% MEM:${MEM_USAGE}% DISK_USED:${DISK_USAGE}%" >> $LOG_FILE
```

#### [증거 자료 07: 파일 권한 확인]
`monitor.sh`는 소유자 `agent-dev`, 그룹 `agent-core`, 권한 `750`으로 설정되어 agent-admin이 core 그룹 구성원으로서 실행 가능하다.
```text
root@ubuntu:/# ls -l /home/agent-admin/agent-app/bin/
-rwxr-x--- 1 agent-admin agent-core  ... agent-app
-rwxr-x--- 1 agent-admin agent-core  ... agent-start.sh
-rwxr-x--- 1 agent-dev   agent-core  ... monitor.sh
```

---

### 5.2 크론탭(Crontab) 스케줄러 등록
야간 시간대 백그라운드 환경에서도 1분 주기로 모니터링이 작동하도록 스케줄러에 등록하였다.

#### [증거 자료 08: Crontab 스케줄러 정상 등록 확인]
```text
agent-admin@ubuntu:~$ crontab -l
* * * * * /home/agent-admin/agent-app/bin/monitor.sh
```

---

### 5.3 통합 모니터링 로그 누적 데이터 검증

#### [증거 자료 09: 1분 주기 자동 로깅 스크립트 실행 내역 누적]
```text
root@ubuntu:/# tail -5 /var/log/agent-app/monitor.log
[2026-05-21 16:27:45] PID:3945 CPU:0% MEM:4% DISK_USED:1%
[2026-05-21 16:28:01] PID:3945 CPU:1% MEM:3% DISK_USED:1%
```
`16:27:45`(수동 실행) → `16:28:01`(crontab 자동 실행) 순으로 1분 주기 누적이 정상 확인되었다.

#### [증거 자료 10: 임계값 초과 조건 판별 및 [WARNING] 로그 출력 검증]
CPU 임계값(20%)을 초과하는 조건이 발생할 경우 아래와 같이 경고 로그가 출력된다.
```text
[2026-05-21 HH:MM:SS] [WARNING] CPU threshold exceeded (25% > 20%)
[2026-05-21 HH:MM:SS] [WARNING] MEMORY threshold exceeded (15% > 10%)
[2026-05-21 HH:MM:SS] PID:XXXX CPU:25% MEM:15% DISK_USED:1%
```

---

## 6. 사용 방법 (Quick Start)

### 6.1 사전 준비

**필요 파일 구성**
```
system-agent/
├── setup.sh                  # 인프라 자동화 스크립트
├── agent-app-linux-arm64     # ARM64 바이너리 (M1/M2/M3 Mac용 VM)
└── agent-app-linux-x86       # x86_64 바이너리 (Intel VM용)
```
바이너리 파일은 `.gitignore`에 등록되어 있으므로 git으로 배포되지 않는다. VM에 적용할 때 반드시 직접 파일을 준비해야 한다.

**VM 아키텍처 확인**
```bash
# VM 내부 또는 orb CLI에서 확인
uname -m
# aarch64 → arm64 바이너리 사용
# x86_64  → x86 바이너리 사용
```

---

### 6.2 OrbStack 환경에서 실행 (권장)

OrbStack은 Mac 홈 디렉토리를 VM 안에 자동 마운트한다. 파일을 별도로 복사할 필요 없이 VM 터미널에서 Mac 경로를 그대로 사용할 수 있다.

**Step 1 — OrbStack VM 터미널 접속**
```bash
# OrbStack 앱에서 VM 클릭 후 터미널 열기, 또는
orb shell ubuntu
```

**Step 2 — setup.sh 실행**
```bash
cd /Users/<Mac_사용자명>/system-agent
sudo bash setup.sh
```

**Step 3 — 앱 실행 확인**
```bash
# Boot Sequence 출력 확인 (별도 터미널에서)
su - agent-admin
/home/agent-admin/agent-app/bin/agent-app
```

**Step 4 — 1~2분 후 자동 로깅 확인**
```bash
tail -f /var/log/agent-app/monitor.log
```

---

### 6.3 일반 Ubuntu 환경에서 실행

OrbStack이 아닌 일반 Ubuntu 서버(VM/클라우드)에서도 동일하게 적용 가능하다.

**Step 1 — 파일 업로드**
```bash
# scp 또는 sftp로 서버에 업로드
scp setup.sh agent-app-linux-x86 user@server:/tmp/
```

**Step 2 — 서버 접속 후 실행**
```bash
ssh user@server
cd /tmp
sudo bash setup.sh
```

---

## 7. 유의사항 (Precautions)

### 7.1 바이너리 아키텍처 반드시 확인
`setup.sh`는 `uname -m` 결과를 기반으로 바이너리를 자동 선택한다. 하지만 두 파일이 모두 없거나 아키텍처와 맞지 않으면 `[WARNING]`과 함께 앱 기동이 실패한다.

| VM 아키텍처 | 필요 바이너리 |
|-------------|--------------|
| `aarch64` (ARM) | `agent-app-linux-arm64` |
| `x86_64` (Intel) | `agent-app-linux-x86` |

---

### 7.2 AGENT_KEY_PATH는 디렉토리 경로로 설정
앱 바이너리는 `AGENT_KEY_PATH`를 **파일 경로가 아닌 디렉토리 경로**로 인식한다. 파일명(`secret.key`)을 포함하면 Boot Sequence 2단계에서 `Key Path Mismatch` 오류가 발생한다.

```bash
# ❌ 잘못된 설정
export AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys/secret.key

# ✅ 올바른 설정
export AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys
```

---

### 7.3 키 파일명은 `secret.key` 고정
앱이 `AGENT_KEY_PATH` 디렉토리 내에서 `secret.key` 파일명을 고정으로 탐색한다. 다른 이름(예: `t_secret.key`)으로 생성하면 Boot Sequence 3단계에서 `Missing File` 오류가 발생한다.

---

### 7.4 반드시 일반 계정(`agent-admin`)으로 앱 실행
앱 내부에서 `root` 계정 실행을 차단한다. `root`로 직접 실행하면 Boot Sequence 1단계에서 즉시 종료된다.

```bash
# ❌ root로 실행 금지
sudo /home/agent-admin/agent-app/bin/agent-app

# ✅ agent-admin으로 실행
su - agent-admin -c '/home/agent-admin/agent-app/bin/agent-app'
```

---

### 7.5 UFW 상태 확인 시 root 권한 불필요
`monitor.sh`는 `ufw status` 대신 `/etc/ufw/ufw.conf` 파일을 직접 읽어 방화벽 상태를 점검한다. `agent-admin`(비root) 계정으로 crontab 실행 시에도 권한 오류 없이 동작한다.

---

### 7.6 재설치 시 멱등성 보장
`setup.sh`를 동일 VM에 재실행해도 안전하다. 계정/그룹 생성 명령에 중복 체크(`id user &>/dev/null ||`)가 포함되어 있고, UFW는 기존 규칙 중복 시 `Skipping` 처리된다. 단, **키 파일 및 crontab은 덮어쓰기** 되므로 기존 내용이 초기화됨에 유의한다.

---

## 8. 결론 (Conclusion)
본 프로젝트를 통해 인프라 구축의 뼈대가 되는 **네트워크 방화벽 격리**, **역할 기반 사용자 보안(RBAC)**, **자동화 관제 시스템 파이프라인**을 성공적으로 완비하였다.

1. **보안성 확보**: 포트 변경(20022), Root 로그인 차단, UFW 방화벽 제어 및 최소 권한 원칙 적용 완료.
2. **재현 가능성 확보**: `setup.sh` 단일 스크립트로 전체 인프라를 멱등성(Idempotency) 있게 재구성 가능.
3. **사후 추적성 확보**: 매분 누적되는 `monitor.log`를 통해 시스템 부하 및 이상 징후 분석 기반 마련 완료.
