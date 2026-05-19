[Bug] OOM Crash - 프로세스 실행 중 지속적인 힙(Heap) 메모리 누수로 인한 강제 종료

## 1. Description (현상 설명)
`agent-app-leak` 애플리케이션 실행 후, 내부 작업이 진행됨에 따라 메모리 사용량이 비정상적으로 계속 증가하는 현상이 발생했습니다. 가용 메모리 임계치에 도달하자 시스템 다운을 막기 위해 메모리 보호 정책(MemoryGuard)이 발동하여 프로세스가 강제 종료되었습니다.

## 2. Evidence & Logs (증거 자료)
`monitor.sh` 관제 로그 및 프로그램 내부 로그를 분석한 결과, 물리 메모리 사용량이 지속적으로 누적되는 패턴을 확인했습니다.

[monitor.sh 관제 수치 (예시)]
- 17:47:50 - MEM: 10.5%
- 17:48:20 - MEM: 95.8% (급격한 선형 상승 패턴 관측)

[프로그램 실행 로그 발췌]
2026-05-19 17:48:20 [INFO] [MemoryWorker] Current Heap: 275MB
2026-05-19 17:48:20 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB)
2026-05-19 17:48:20 [CRITICAL] [MemoryGuard] Self-terminating process 2024...
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<

## 3. Root Cause Analysis (원인 분석)
어플리케이션이 생성한 데이터를 힙(Heap) 영역에서 적절히 해제하지 않는 메모리 누수(Memory Leak) 결함이 원인입니다. OS 레벨의 OOM Killer가 서버 전체를 멈추기 전에, 프로세스 내부의 방어 로직이 임계치 초과를 감지하고 스스로를 강제 종료시켰습니다.

## 4. Workaround & Verification (조치 및 검증)
- 조치: `.bash_profile`의 `MEMORY_LIMIT` 값을 256MB에서 512MB로 상향 조정했습니다.
- 검증: 설정 변경 전(256MB)에는 30초 만에 `SELF-TERMINATED`가 발생했으나, 변경 후(512MB)에는 525MB 도달 시 시스템이 캐시를 비우며(Cache Flushed) 안정적으로 생존함을 확인했습니다.


------------------------
[Bug] Deadlock - 멀티스레드 환경 자원 순환 대기(Circular Wait)로 인한 프로세스 무응답

## 1. Description (현상 설명)
`MULTI_THREAD_ENABLE=True` 환경에서 프로세스 실행 직후, 터미널의 로그 출력이 완전히 멈추고 시스템이 아무런 연산을 수행하지 않는 무응답 상태에 빠졌습니다. 프로세스가 오류로 종료(Crash)된 것이 아니라, 백그라운드에 좀비처럼 살아있지만 작업을 진행하지 못하는 상태입니다.

## 2. Evidence & Logs (증거 자료)
프로세스가 살아있음을 시스템 도구로 확인했으며, 마지막 출력 로그에서 두 스레드가 서로의 자원을 대기하는 것을 확인했습니다.

[시스템 명령어 (PID 확인)]
$ ps -ef | grep agent-app-leak
agent-admin  2042  2031  0 17:52 ?  00:00:00 ./agent-app-leak (프로세스 생존 확인)

[마지막 로그 지점 발췌]
[INFO] [Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
[INFO] [Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
[INFO] [Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
[INFO] [Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
[INFO] [Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
[INFO] [Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)

## 3. Root Cause Analysis (원인 분석)
마지막 로그를 분석한 결과, 전형적인 '교착상태(Deadlock)'임을 확인했습니다. `Thread-1`은 자원 A를 쥐고 B를 요구하며, `Thread-2`는 자원 B를 쥐고 A를 요구하고 있습니다. 서로가 가진 자원을 양보하지 않고 무한정 기다리는 데드락의 핵심 조건인 '순환 대기(Circular Wait)' 및 '점유 대기(Hold and Wait)'가 발생하여 프로세스 진행이 차단되었습니다.

## 4. Workaround & Verification (조치 및 검증)
- **임시 조치**: `pkill -9 -f agent-app-leak` 명령어로 멈춘 프로세스를 강제 종료한 뒤, `MULTI_THREAD_ENABLE=False`로 환경변수를 변경하여 멀티스레딩 기능을 제한했습니다.
- **결과 확인(Before & After)**:
  - Before (True): 실행 5초 만에 `WAITING... BLOCKED` 상태로 교착상태 발생
  - After (False): 단일 스레드(Concurrency: False)로 동작하며 자원 쟁탈전이 사라졌고, 작업이 중단 없이 정상 처리됨을 확인했습니다.

-----------------------------------
[Bug] CPU Latency - 특정 프로세스의 CPU 자원 과점유 시도 및 자체 방어 로직에 의한 처리 지연

## 1. Description (현상 설명)
`agent-app-leak` 프로세스의 CPU 사용률이 급격하게 상승하다가, 특정 한계치에 도달하면 강제로 연산을 멈추고 휴식(Cooldown)하는 현상이 반복되어 시스템 전체 응답 지연(Latency)이 발생했습니다.

## 2. Evidence & Logs (증거 자료)
`top` 명령어와 내부 로그를 통해 특정 프로세스가 CPU 점유율 임계치에 도달할 때마다 방어 로직(Watchdog)이 발동하는 것을 관측했습니다.

[top 명령어 모니터링 결과]
- PID 2050 (agent-app-leak) CPU 점유율이 49% ~ 50% 구간에서 요동침

[핵심 실행 로그 발췌]
2026-05-19 19:23:47 [INFO] [CpuWorker] Current Load: 8.50%
2026-05-19 19:23:49 [INFO] [CpuWorker] Peak reached (10.00%). Starting cooldown...
2026-05-19 19:23:52 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming...

## 3. Root Cause Analysis (원인 분석)
특정 스레드(`CpuWorker`)가 과도한 연산 루프를 돌며 CPU 자원을 과점유하려는 결함입니다. CPU 자원 경쟁으로 서버가 마비되는 것을 방지하기 위해 과점유 방지 정책(Watchdog)이 개입하여 스레드를 강제로 일시 정지(Sleep)시키고 있으며, 이로 인해 작업 처리 속도가 심각하게 느려집니다.

## 4. Workaround & Verification (조치 및 검증)
- 조치: `CPU_MAX_OCCUPY` 환경변수를 10%에서 50%로 상향 조정하여 버퍼를 확보했습니다.
- 검증: 변경 전(10%)에는 즉각적으로 `Peak reached`가 발생하며 수시로 쿨다운에 진입해 지연되었으나, 변경 후(50%)에는 49%에 도달할 때까지 원활히 연산이 진행되어 처리량이 대폭 개선됨을 확인했습니다.