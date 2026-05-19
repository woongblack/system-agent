# [요구사항 수행 내역서] 리눅스 서버 인프라 구축 및 관제 자동화

## 1. 개요 (Overview)
본 보고서는 다중 사용자 환경에서의 안전한 서버 보안 체계 구축, 역할 기반 접근 제어(RBAC) 설계, 애플리케이션 실행 환경 최적화, 그리고 시스템 관제 자동화 스크립트 개발에 대한 요구사항 수행 내역을 종합적으로 기록한 문서이다. 

서버 장애 발생 시 데이터 기반의 신속한 장애 복구(Root Cause Analysis)가 가능하도록 로그 자동화 수집 환경을 구축하였으며, 인프라의 기본 보안 정책 및 최소 권한 원칙(Principle of Least Privilege)을 철저히 준수하여 설계하였다.

---

## 2. 기본 보안 및 네트워크 설정 (Security & Network Setup)

### 2.1 SSH 서버 보안 고도화
원격 인프라 관리의 핵심 관문인 SSH(Secure Shell) 서비스의 취약점을 보완하기 위해 기본 설정을 변경하였다. 무차별 대입 공격(Brute Force Attack)의 표적이 되는 기본 포트(22)를 비표준 포트인 `20022`로 변경하고, 시스템 최고 권한자인 `root` 계정으로의 직접적인 원격 로그인(`PermitRootLogin no`)을 원천 차단하였다.

- **설정 파일 경로**: `/etc/ssh/sshd_config`
- **주요 수정 내역**:
  ```bash
  Port 20022
  PermitRootLogin no
  ```

#### [증거 자료 01: 오픈 패키지 설치 및 설정 파일 무결성 유지]
기존 로컬 수정본 설정을 보존하면서 `openssh-server` 패키지를 안전하게 업데이트한 확인 내역이다.
```text
sshd_config: A new version (/tmp/tmp.xq0zTHOrzu) of configuration file /etc/ssh/sshd_config is available, but the version installed currently has been locally modified.
What do you want to do about modified configuration file sshd_config?
> keep the local version currently installed
```

---

### 2.2 방화벽(UFW) 정책 수립 및 포트 화이트리스트 구성
시스템에 허용되지 않은 비정상 접근을 차단하기 위해 Ubuntu 기본 방화벽 도구인 `UFW`를 활성화하고, 서비스 운영 및 원격 관리에 필요한 포트만을 선별하여 허용하였다.

- **방화벽 설정 명령어**:
  ```bash
  ufw allow 20022/tcp
  ufw allow 15034/tcp
  ufw enable
  ```

#### [증거 자료 02: UFW 방화벽 활성화 및 포트 리슨 상태 확인]
`ufw status` 명령을 통해 20022 및 15034 포트만 안전하게 개방된 것을 확인하였다.
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
uid=1001(agent-admin) gid=1001(agent-admin) groups=1001(agent-admin),27(sudo),1002(agent-common),1003(agent-core)

root@ubuntu:/# id agent-dev
uid=1004(agent-dev) gid=1004(agent-dev) groups=1004(agent-dev),1002(agent-common),1003(agent-core)
```

---

### 3.2 디렉토리 구조 정의 및 접근 제어 목록(ACL) 수립
애플리케이션 홈 디렉토리(`$AGENT_HOME`) 구조에 대해 그룹별 파일 보안 수준을 적용하였다.

#### [증거 자료 04: 디렉토리 경로 소유권 및 권한 상태 확인]
핵심 폴더인 `api_keys`는 core 그룹 전용으로, `upload_files`는 common 그룹용으로 권한이 할당되었다.
```text
root@ubuntu:/# ls -l /home/agent-admin/agent-app
drwxrwx--- 2 agent-admin agent-core   4096 May 13 18:00 api_keys
drwxrwx--- 2 agent-admin agent-core   4096 May 13 18:00 bin
drwxrwx--- 2 agent-admin agent-common 4096 May 13 18:00 upload_files
```

---

### 3.3 최소 권한 원칙(Principle of Least Privilege) 실증 검증
보안 위협 예방을 위해 테스트 계정(`agent-test`)이 임의로 관리자 권한 명령(`sudo`)을 실행하는 것을 원천 거부하도록 설계하였다.

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
export AGENT_LOG_DIR=/var/log/agent-app
```

### 4.2 서비스 기동 및 Boot Sequence 검증
일반 관리 계정(`agent-admin`)으로 파이썬 애플리케이션 기동 시퀀스 무결성을 검증하였다.

#### [증거 자료 06: 애플리케이션 Boot Sequence 5단계 [OK] 통과 화면]
```text
agent-admin@ubuntu:~/agent-app$ python3 agent-app.py 
Starting Agent Boot Sequence...
[1/5] Checking User Account         [OK]
... Running as service user 'woongblack1235185'
[2/5] Verifying Environment Variables[OK]
... All required Envs correct
[3/5] Checking Required Files       [OK]
... Verified key file exists
[4/5] Checking Port Availability    [OK]
... Port 15034 is available.
[5/5] Verifying Log Permission      [OK]
... Log directory is writable: /var/log/agent-app
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

---

## 5. 시스템 관제 자동화 스크립트 구현 (Automation Script)

### 5.1 관제 자동화 스크립트 소스 코드 (`monitor.sh`)
정수 연산만 지원하는 Bash의 한계를 극복하기 위해 `bc` 도구를 사용하여 임계값 소수점 데이터를 정밀하게 비교/처리하였다.

```bash
#!/bin/bash
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_LOG_DIR=/var/log/agent-app
source /etc/profile.d/agent_env.sh

NOW=$(date "+%Y-%m-%d %H:%M:%S")
LOG_FILE="$AGENT_LOG_DIR/monitor.log"

# 프로세스 및 포트 헬스체크
PID=$(pgrep -f agent-app.py)
if [ -z "$PID" ]; then
    echo "[$NOW] [ERROR] agent-app.py is not running!" >> $LOG_FILE
    exit 1
fi

PORT_CHECK=$(ss -tuln | grep :$AGENT_PORT)
if [ -z "$PORT_CHECK" ]; then
    echo "[$NOW] [ERROR] Port $AGENT_PORT is not listening!" >> $LOG_FILE
    exit 1
fi

# 자원 수집
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
if [ -z "$CPU_USAGE" ]; then CPU_USAGE=0; fi
MEM_USAGE=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')

# 임계값 설정 및 경고 출력 로직
CPU_THRESHOLD=20.0
if [ "$(echo "$CPU_USAGE > $CPU_THRESHOLD" | bc)" -eq 1 ]; then
    WARN_MSG="[WARNING] CPU threshold exceeded (${CPU_USAGE}% > ${CPU_THRESHOLD}%)"
    echo "[$NOW] $WARN_MSG" >> $LOG_FILE
fi

# 상태 기록
echo "[$NOW] PID:$PID CPU:${CPU_USAGE}% MEM:${MEM_USAGE}% DISK_USED:${DISK_USAGE}%" >> $LOG_FILE
echo "Monitor completed at $NOW"
```

#### [증거 자료 07: 파일 생성 시 그룹 권한(부모 디렉토리 접근) 트러블슈팅]
상위 부모 폴더의 접근 권한 제약으로 발생한 Permission denied 이슈를 `chmod 711` 실행 권한 부여로 해결하였다.
```text
[ Error writing /home/agent-admin/agent-app/bin/monitor.sh: Permission denied ]

root@ubuntu:~# chmod 711 /home/agent-admin
root@ubuntu:~# chmod 711 /home/agent-admin/agent-app
```

---

### 5.2 크론탭(Crontab) 스케줄러 등록
야간 시간대 백그라운드 환경에서도 1분 주기로 모니터링이 작동하도록 스케줄러에 등록하였다.

#### [증거 자료 08: Crontab 스케줄러 정상 등록 확인]
```text
agent-admin@ubuntu:~$ crontab -l
# m h  dom mon dow   command
* * * * * /home/agent-admin/agent-app/bin/monitor.sh
```

---

### 5.3 통합 모니터링 로그 누적 데이터 검증

#### [증거 자료 09: 1분 주기 자동 로깅 스크립트 실행 내역 누적]
```text
agent-dev@ubuntu:~$ tail -f /var/log/agent-app/monitor.log
[2026-05-13 18:17:01] PID:4598 CPU:0% MEM:1.91732% DISK_USED:1%
[2026-05-13 18:18:01] PID:4598 CPU:0% MEM:1.96412% DISK_USED:1%
[2026-05-13 18:19:01] PID:4598 CPU:0% MEM:2.03207% DISK_USED:1%
```

#### [증거 자료 10: 임계값 초과 조건 판별 및 [WARNING] 로그 출력 검증]
임계값 하향 조정 디버깅 테스트를 통해 조건부 분기 처리가 정상 작동하는 것을 실증하였다.
```text
agent-dev@ubuntu:~$ tail -n 5 /var/log/agent-app/monitor.log
[2026-05-13 18:50:01] PID:4598 CPU:0% MEM:1.90052% DISK_USED:1%
[2026-05-13 18:51:01] [WARNING] CPU threshold exceeded (0% > -1%)
[2026-05-13 18:51:01] PID:4598 CPU:0% MEM:1.96524% DISK_USED:1%
```

---

## 6. 결론 (Conclusion)
본 프로젝트를 통해 인프라 구축의 뼈대가 되는 **네트워크 방화벽 격리**, **역할 기반 사용자 보안(RBAC)**, **자동화 관제 시스템 파이프라인**을 성공적으로 완비하였다.

1. **보안성 확보**: 포트 변경, Root 로그인 차단, UFW 제어 및 최소 권한 원칙 적용 완료.
2. **사후 추적성 확보**: 매분 누적되는 `monitor.log`를 통해 시스템 부하 및 이상 징후 분석 기반 마련 완료.