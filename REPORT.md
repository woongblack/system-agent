# 1. [Bug] OOM Crash - 지속적인 힙(Heap) 메모리 누수로 인한 프로세스 강제 종료

### 1.1 Description (현상 설명)
`agent-app-leak` 애플리케이션 실행 후, 내부 작업이 진행됨에 따라 메모리 사용량이 비정상적으로 계속 증가하는 현상이 발생했습니다. 가용 메모리 임계치에 도달하자 시스템 다운을 막기 위해 메모리 보호 정책(MemoryGuard)이 발동하여 프로세스가 강제 종료되었습니다.

### 1.2 Evidence & Logs (증거 자료)
`monitor.sh` 관제 로그 및 프로그램 내부 로그를 분석한 결과, 물리 메모리 사용량이 지속적으로 누적되는 패턴을 확인했습니다.

[monitor.sh 관제 수치 (예시)]
- 17:46:50 - MEM: 10.5% (초기 안정 상태)
- 17:47:20 - MEM: 38.2% (메모리 누수 발생)
- 17:47:50 - MEM: 65.4% (지속적인 누적 확인)
- 17:48:20 - MEM: 95.8% (임계치 도달 직전)

[프로그램 실행 로그 발췌]
2026-05-19 17:48:20 [INFO] [MemoryWorker] Current Heap: 275MB
2026-05-19 17:48:20 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB)
2026-05-19 17:48:20 [CRITICAL] [MemoryGuard] Self-terminating process 2024...
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<

### 1.3 Root Cause Analysis (원인 분석)
어플리케이션이 생성한 데이터를 힙(Heap) 영역에서 적절히 해제하지 않는 메모리 누수(Memory Leak) 결함이 원인입니다. OS 레벨의 OOM Killer가 서버 전체를 멈추기 전에, 프로세스 내부의 방어 로직이 임계치 초과를 감지하고 스스로를 강제 종료시켰습니다.

### 1.4 Workaround & Verification (조치 및 검증)
- **조치:** `.bash_profile`의 `MEMORY_LIMIT` 값을 256MB에서 512MB로 상향 조정했습니다.
- **검증:** 설정 변경 전(256MB)에는 30초 만에 `SELF-TERMINATED`가 발생했으나, 변경 후(512MB)에는 525MB 도달 시 시스템이 캐시를 비우며(Cache Flushed) 안정적으로 생존함을 확인했습니다.

---

# 2. [Bug] Deadlock - 멀티스레드 환경 자원 순환 대기(Circular Wait)로 인한 프로세스 무응답

### 2.1 Description (현상 설명)
`MULTI_THREAD_ENABLE=True` 환경에서 프로세스 실행 직후, 터미널의 로그 출력이 완전히 멈추고 시스템이 아무런 연산을 수행하지 않는 무응답 상태에 빠졌습니다. 프로세스가 오류로 종료(Crash)된 것이 아니라, 백그라운드에 좀비처럼 살아있지만 작업을 진행하지 못하는 상태입니다.

### 2.2 Evidence & Logs (증거 자료)
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

### 2.3 Root Cause Analysis (원인 분석)
마지막 로그를 분석한 결과, 전형적인 '교착상태(Deadlock)'임을 확인했습니다. `Thread-1`은 자원 A를 쥐고 B를 요구하며, `Thread-2`는 자원 B를 쥐고 A를 요구하고 있습니다. 서로가 가진 자원을 양보하지 않고 무한정 기다리는 데드락의 핵심 조건인 '순환 대기(Circular Wait)' 및 '점유 대기(Hold and Wait)'가 발생하여 프로세스 진행이 차단되었습니다.

### 2.4 Workaround & Verification (조치 및 검증)
- **임시 조치:** `pkill -9 -f agent-app-leak` 명령어로 멈춘 프로세스를 강제 종료한 뒤, `MULTI_THREAD_ENABLE=False`로 환경변수를 변경하여 멀티스레딩 기능을 제한했습니다.
- **결과 확인(Before & After):**
  - Before (True): 실행 5초 만에 `WAITING... BLOCKED` 상태로 교착상태 발생
  - After (False): 단일 스레드(Concurrency: False)로 동작하며 자원 쟁탈전이 사라졌고, 작업이 중단 없이 정상 처리됨을 확인했습니다.

---

# 3. [Bug] CPU Latency - 특정 프로세스의 CPU 자원 과점유 시도 및 방어 로직에 의한 처리 지연

### 3.1 Description (현상 설명)
`agent-app-leak` 프로세스의 CPU 사용률이 급격하게 상승하다가, 특정 한계치에 도달하면 강제로 연산을 멈추고 휴식(Cooldown)하는 현상이 반복되어 시스템 전체 응답 지연(Latency)이 발생했습니다.

### 3.2 Evidence & Logs (증거 자료)
`top` 명령어와 내부 로그를 통해 특정 프로세스가 CPU 점유율 임계치에 도달할 때마다 방어 로직(Watchdog)이 발동하는 것을 관측했습니다.

[top 명령어 모니터링 결과]
- PID 2050 (agent-app-leak) CPU 점유율이 49% ~ 50% 구간에서 요동침

[핵심 실행 로그 발췌]
2026-05-19 19:23:47 [INFO] [CpuWorker] Current Load: 8.50%
2026-05-19 19:23:49 [INFO] [CpuWorker] Peak reached (10.00%). Starting cooldown...
2026-05-19 19:23:52 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming...

### 3.3 Root Cause Analysis (원인 분석)
특정 스레드(`CpuWorker`)가 과도한 연산 루프를 돌며 CPU 자원을 과점유하려는 결함입니다. CPU 자원 경쟁으로 서버가 마비되는 것을 방지하기 위해 과점유 방지 정책(Watchdog)이 개입하여 스레드를 강제로 일시 정지(Sleep)시키고 있으며, 이로 인해 작업 처리 속도가 심각하게 느려집니다.

### 3.4 Workaround & Verification (조치 및 검증)
- **조치:** `CPU_MAX_OCCUPY` 환경변수를 10%에서 50%로 상향 조정하여 버퍼를 확보했습니다.
- **검증:** 변경 전(10%)에는 즉각적으로 `Peak reached`가 발생하며 수시로 쿨다운에 진입해 지연되었으나, 변경 후(50%)에는 49%에 도달할 때까지 원활히 연산이 진행되어 처리량이 대폭 개선됨을 확인했습니다.

---

# 4. [Appendix] 운영체제(OS) 및 트러블슈팅 심화 개념 정리

본 미션 수행 및 장애 분석을 바탕으로, 안정적인 서버 운영과 백엔드 개발을 위해 필수적인 핵심 CS 개념들을 추가 정리합니다.

### 4.1 프로그램, 프로세스, 그리고 스레드의 본질
- **프로그램 (Program):** 디스크에 저장된 정적인 코드 덩어리입니다. (비유: 도커 이미지, 요리 레시피)
- **프로세스 (Process):** 프로그램이 실행되어 메모리 자원(공간)을 할당받고 생명력을 얻은 동적 상태입니다. (비유: 도커 컨테이너, 운영 중인 요리 공장)
- **스레드 (Thread):** 프로세스라는 판 위에서, CPU 코어를 점유하며 코드를 한 줄씩 실행해 나가는 **실제로 처리되어야 할 '작업(Task)의 흐름'**입니다. 스레드는 자신만의 책갈피(PC 레지스터)와 개인 작업대(Stack 메모리)를 가지며, 모든 스레드가 공유하는 창고(Heap 메모리)의 데이터를 CPU로 가져와(Fetch) 연산합니다.

### 4.2 메모리 관리와 GC (Garbage Collection)
- **오해와 진실:** 메모리(RAM) 하드웨어 자체에는 청소 기능이 없습니다. 메모리 관리는 전적으로 OS나 런타임(JVM, Python 등) 소프트웨어의 몫입니다.
- **GC의 역할:** Java나 Python 같은 언어는 런타임 내부에 GC(가비지 컬렉터)라는 별도의 관리 스레드가 있어 사용이 끝난 메모리를 대신 찾아내 해제합니다.
- **OOM 발생 원인:** 개발자가 더 이상 쓰지 않는 전역 데이터(List, Map 등)의 '참조(Reference)'를 끊지 않고 유지하면, GC는 이를 사용 중인 자원으로 판단하여 지우지 못합니다. 이것이 힙(Heap) 메모리에 계속 누적되면 결국 시스템의 메모리 누수(OOM, Out Of Memory) 장애로 이어집니다.

### 4.3 동시성 제어 기법과 시스템 보호 패턴 (Locks & Circuit Breaker)
여러 스레드(작업 흐름)가 동시에 하나의 공유 자원(메모리/DB)에 접근할 때 발생하는 동시성 문제를 해결하고 시스템 연쇄 장애를 방지하는 기법입니다.
- **비관적 락 (Pessimistic Lock):** 충돌이 무조건 발생할 것이라 비관적으로 가정하고 데이터 접근 시 즉각 물리적인 자물쇠를 채웁니다. 정합성은 확실히 보장되나, 다른 스레드들의 대기 시간이 길어지고 심하면 데드락(Deadlock) 위험이 있습니다.
- **낙관적 락 (Optimistic Lock):** 충돌이 적을 것이라 낙관하고 물리적 자물쇠 대신 데이터에 '버전(Version)'을 표기합니다. 수정 시점에 타 스레드에 의해 버전이 바뀌었다면 작업을 처음부터 재시도(Retry)하는 방식으로 성능 병목을 최소화합니다.
- **서킷 브레이커 (Circuit Breaker):** 외부 API나 연동 서버에 장애가 났을 때, 우리 서버의 수많은 스레드들이 무한 대기에 빠져 스택(Stack) 메모리 한도를 다 갉아먹는 상황을 막아줍니다. 장애를 감지하면 즉시 '두꺼비집(차단기)'을 내려 트래픽을 차단(Fail-Fast)함으로써, 우리 서버가 동반 OOM 장애로 죽는 것을 방지합니다.

### 4.4 CPU 과점유(Spike) 분석과 병목 판단 지표
서버의 CPU 사용률이 치솟을 때, 맹목적으로 코드를 수정하기 전에 장애의 성격이 **내부 로직(CPU-Bound)** 때문인지, **외부 요인(I/O-Bound)** 때문인지 정확히 진단해야 합니다. 리눅스의 `top` 명령어 지표를 통해 이를 증명할 수 있습니다.
- **`us` (User Space) - 로직 병목:** 애플리케이션 코드가 순수하게 CPU를 쓰며 연산 중인 비율입니다. 이 수치가 높다면 내부 코드의 무한 루프, 비효율적 알고리즘, 혹은 실제 트래픽 폭주가 원인입니다. (해결: 코드 프로파일링 및 최적화, 서버 스케일 아웃)
- **`wa` (I/O Wait) - 외부 장애 병목:** CPU가 연산하지 못하고 DB, 디스크, 외부 API의 응답을 기다리는 비율입니다. 이 수치가 치솟는다면 서버 내부 코드가 아니라 연동된 외부 시스템의 장애를 의심해야 합니다. (해결: 서킷 브레이커 작동, 외부 DB/네트워크 점검)
- **`sy` (System Space) - OS 과부하:** 로직 처리나 대기 없이 커널 작업 비율이 높은 상태입니다. 주로 과도한 스레드 생성으로 인한 **컨텍스트 스위칭(Context Switching)** 비용 폭발 시 발생합니다. (해결: 스레드 풀(Thread Pool) 크기 제한, 불필요한 동시성 제어 로직 수정)

### 4.5 OOM(Out of Memory)의 다양한 원인 (Memory Leak 외의 케이스)
OOM 현상이 무조건 코드 내의 메모리 누수(Leak)만을 의미하는 것은 아닙니다. 실무에서는 다음과 같은 상황에서도 빈번하게 OOM이 발생하므로 다각적인 원인 분석이 필요합니다.
- **대용량 객체의 순간적 할당 (Huge Object Allocation):** 누수는 없지만, 파일 다운로드 등에서 수십~수백만 건의 DB 데이터를 한 번에 메모리에 올리려 할 때 순간적으로 한계치를 초과하여 발생합니다. (해결: 데이터를 조금씩 나누어 가져오는 I/O Streaming 방식이나 페이징/커서 처리)
- **스레드 폭주 (Thread Exhaustion):** 외부 API 장애나 DB 병목으로 인해 요청 처리가 지연될 때, 대기 상태의 스레드가 무한정 늘어나며 스레드별 스택(Stack) 메모리 한도를 모두 소진하여 시스템 전체 메모리 고갈로 이어집니다.
- **인프라 설정 오류 (Too Restrictive Limits):** 애플리케이션은 정상적인 메모리를 사용 중이나, 도커(Docker) 컨테이너 등 인프라 구동 시 메모리 상한선(Limit)을 비현실적으로 낮게 설정하여 발생하는 단순 설정 오류입니다.