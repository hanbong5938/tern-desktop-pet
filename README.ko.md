# Tern Desktop Pet

[English](README.md) · **한국어**

[`tern-desktop-pet`](https://github.com/hanbong5938/tern-desktop-pet)은 공개된 별도 Tern 플러그인 소스 저장소입니다. 로컬 Tern 창의 에이전트를 공용 네이티브 Herdr Desktop Pet 앱에 연결합니다. 이 저장소에는 앱이 들어 있지 않으며 앱을 설치하거나 빌드하지 않습니다. 아래의 공개 GitHub URL로 플러그인을 설치하세요. OMP 확장, Herdr 서버, 패치된 호스트, 원격 Tern 에이전트, Tern 터미널/PTy 입력은 사용하지 않습니다. 이 플러그인에는 캐릭터 그림과 스크린샷이 없습니다.

## 준비 및 설치

Apple Silicon macOS 13+에서 [Herdr Desktop Pet 앱 소스](https://github.com/hanbong5938/herdr-desktop-pet)의 로컬 체크아웃이 필요합니다. **네이티브 연결 변경이 병합되기 전까지는 기본 브랜치가 아니라 `origin/tern-desktop-pet-integration`을 명시적으로 fetch하고 checkout하세요.** 아래 명령을 사용합니다. 앱 소스 빌드에는 Rust/Cargo, Bun, Node.js/npm, Xcode Command Line Tools, `codesign`이 필요하며 빌드 의존성을 다운로드할 수 있습니다. 소스 설치기는 앱을 앱 소스 체크아웃의 `dist/HerdrDesktopPet.app`에 빌드·패키징합니다. **플러그인과 네이티브 연결 브랜치를 공개했다고 기존 공개 바이너리가 업그레이드되지는 않습니다. 해당 브랜치에서 네이티브 앱을 별도로 소스 빌드하세요. 기존 공개/사전 빌드 앱으로 대체하지 마세요.** 이 연결에는 `tern-exchange`, `--host tern`, `update-capabilities`의 `protocol: 3` 및 `observation_mode: 1`을 지원하는 네이티브 CLI가 필요합니다. 구형 앱에서 `tern-exchange`가 알 수 없는 명령으로 나오면 이 플러그인과 작동하지 않습니다. 앱을 빌드해도 플러그인 체크아웃에 복사되지 않습니다.

현재 Tern은 로그인이 필요한 비공개 베타입니다. 정당하게 부여받은 베타 접근 권한으로 호환 Tern을 설치·실행하고 정상적으로 로그인해야 하며 인증을 우회하지 마세요. 매니페스트 링크나 로그아웃 상태의 빈 창만으로 기능을 검증할 수는 없습니다. 여기서는 특정 최소 Tern 버전이나 공개 배포를 보장하지 않습니다.

**이전에 수행한 로컬 실제 에이전트 검증:** 로그인된 기존 Tern 0.6.1 창에서 분리된 검증 프로필을 사용해 로컬 에이전트 pane이 창 플러그인과 네이티브 펫에 표시되는 것을 확인했습니다. 임시 탭의 에이전트에게 의미 기반 질문을 보내자 네이티브 상태에 `prompt_accepted`, 전달 상태에 `accepted_may_be_queued`가 나타났습니다. 이후 실제 Tern 에이전트 대화 기록에서 요청한 `TERN_PET_SMOKE_OK` 답변을 확인했고, 에이전트 상태는 일치하는 마지막 메시지를 가진 idle이었습니다. 대화 기록은 이 특정 답변의 전달을 별도로 확인해 주지만, 접수 상태나 idle 상태만으로 완료를 확정할 수는 없습니다. 이 과거 관측은 아래의 현재 수정 회귀 검증과 별개입니다. 공개 릴리스나 최소 버전 보증이 아닌, 공개되지 않은 로컬 소스의 검증입니다.

셸에서 `PET_SOURCE`를 네이티브 체크아웃의 **실제 절대 경로**로 지정하세요(새로 clone할 때는 아직 사용하지 않는 디렉터리). 모든 네이티브 명령과 Tern 플러그인 설정에서 동일한 네이티브 config/state 경로를 사용합니다. 새 네이티브 체크아웃은 아래의 `git clone`부터 실행하세요. 기존 체크아웃이라면 그 clone 명령만 건너뛰고, 빌드 전에 반드시 정확한 연결 브랜치를 fetch하고 checkout하세요.

```sh
PET_SOURCE=/absolute/path/to/herdr-desktop-pet-source
PET_CONFIG="$HOME/.config/tern-desktop-pet/native"
PET_STATE="$HOME/.local/state/tern-desktop-pet/native"

git clone https://github.com/hanbong5938/herdr-desktop-pet.git "$PET_SOURCE"
cd "$PET_SOURCE"
git fetch origin tern-desktop-pet-integration
git checkout --detach origin/tern-desktop-pet-integration
bash scripts/install.sh --source
PET_BIN="$PET_SOURCE/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet"
"$PET_BIN" update-capabilities
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" settings set exit_with_herdr off
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" start
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" status

tern plugin install https://github.com/hanbong5938/tern-desktop-pet
tern plugin reload
tern plugin list
```

공개 `tern plugin install` 명령 대신 로컬 플러그인 소스 체크아웃을 연결할 수도 있습니다:

```sh
TERN_PLUGIN=/absolute/path/to/tern-desktop-pet
git clone https://github.com/hanbong5938/tern-desktop-pet.git "$TERN_PLUGIN"
tern plugin link "$TERN_PLUGIN"
tern plugin reload
tern plugin list
```

플러그인 체크아웃이 이미 있다면 해당 clone 명령을 건너뛰세요. 로컬 연결은 개발용 대안이며 별도의 네이티브 앱을 빌드하거나 설치하지 않습니다.

실제 경로로 바꿔 실행하세요. `PET_*` 셸 변수는 편의를 위한 것이며 Tern의 영구 설정이 아닙니다. capability JSON에서 **두** 필드를 확인하고 `status`에서 실행 중인 앱의 실제 실행 파일과 `observation_mode: tern`을 확인하세요. `start`는 이미 실행 중인 데몬을 재사용합니다. 다른 모드 또는 구형 데몬이 같은 프로필을 사용한다면 동일한 config/state 경로로 먼저 중지한 뒤 새 앱을 시작하세요. 두 경로를 함께 분리해야 기존 Herdr 펫 프로필과 충돌하지 않습니다. 네이티브 `--socket`은 **Herdr** 백엔드용이며 Tern 전용 실행에는 필요하지 않습니다. `--host tern`을 명시해 상속된 호스트 모드 환경 설정에 의존하지 않고, `exit_with_herdr off`로 Herdr 없이 독립 실행한 펫을 유지합니다. 셸에 `HERDR_PLUGIN_CONFIG_DIR` 또는 `HERDR_PLUGIN_STATE_DIR`이 설정되어 있다면 수동 명령 실행 시 해제하거나 위 프로필과 일치시키세요. 주입된 플러그인 경로가 CLI 경로보다 우선합니다.

`status.herdr_socket`은 Tern 전용 모드에서도 네이티브 앱의 업데이트 컨텍스트에 보존된 Herdr 소켓 설정 경로를 표시합니다. 실제 Herdr 엔드포인트가 살아 있다는 증거가 아닙니다. Tern 전용 실행에는 Herdr 등록도, 해당 경로의 소켓도, 그 부모 디렉터리도 필요하지 않습니다. 공용 앱은 `--host herdr|tern|both`를 지원하며 이 플러그인이 별도의 네이티브 앱을 도입하는 것은 아닙니다. Tern/Both 업데이트는 프로토콜 3을 유지하면서 서명된 앱과 서명된 헬퍼 모두 `observation_mode: 1`을 지원해야 하며, 재시작된 앱의 상태가 요청한 모드와 정확히 일치해야 합니다.

`tern plugin link`는 이 체크아웃을 제자리에서 참조하며 공개하거나 복사하지 않습니다. `tern plugin reload`는 실행 중인 데몬의 플러그인을 다시 읽고 `tern plugin list`는 로딩 상태/오류를 표시합니다. `window.luau`를 수정했다면 다시 `tern plugin reload`를 실행하세요. 로그인 후 로컬 에이전트 pane이 있는 실제 Tern **창**을 여세요. 창이 없다면 데몬에서 독립적으로 계속 폴링하지 않습니다. 헤드리스 데몬의 플러그인 목록만으로는 플러그인 런타임을 실행·확인한 것이 아닙니다. Tern 명령 팔레트에서 **Connect to desktop pet** (`connect`)을 선택하면 즉시 교환을 요청합니다. 플러그인은 약 1.2초 간격으로도 폴링하고 관련 pane/tab/명령 변경에 반응합니다.

## 창 플러그인 설정

실제 Tern 창의 명령 팔레트에서 **Configure desktop pet connection** (`configure`)을 선택하세요. 다음 세 질문에 순서대로 답합니다.

1. **Desktop pet executable (path or command):** 위 `PET_BIN`에 담긴 전체 절대 경로를 입력합니다. 예: `/absolute/path/to/herdr-desktop-pet-source/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet` (변수명이나 `.app` 디렉터리가 아닙니다).
2. **Absolute desktop pet config directory:** `PET_CONFIG`와 동일한, 확장된 절대 경로를 입력합니다.
3. **Absolute desktop pet state directory:** `PET_STATE`와 동일한, 확장된 절대 경로를 입력합니다.

창 플러그인은 단일 정식 `tern.kv` 키 `connection`에 `{ version = 1, executable = "...", config_dir = "...", state_dir = "..." }` 객체를 저장합니다. 후보 전체(버전/필드, 비어 있지 않은 실행 파일, 절대 config/state 경로, NUL 바이트 없음)를 검증한 뒤 **한 번의 KV 쓰기**로 저장하고, 그 후 활성 프로필을 전환하고 소스 인스턴스를 초기화해 즉시 교환합니다. 어느 질문에서든 취소하거나, 질문/검증에 오류가 나거나, 저장이 실패하면 이전 저장 연결과 활성 연결을 유지합니다. 일부만 입력한 프로필은 활성화되지 않습니다.

`connection`이 없을 때에만 예전 세 키 `executable`, `config_dir`, `state_dir`를 함께 가져오고 누락된 값은 기본값으로 채웁니다. 이 일회성 마이그레이션은 정식 객체 전체를 검증·저장한 뒤 레거시 키 제거를 시도합니다. 제거 실패는 로그에 남지만 이미 저장한 객체를 되돌리지 않습니다. 기존 `connection`이 잘못된 형식이면 오류이며, 예전 키로 되돌아갈 근거가 **절대 아닙니다**. **Configure desktop pet connection**으로 수정하세요.

설정하지 않았을 때 기본값은 실행 파일 `herdr-desktop-pet`, config `${XDG_CONFIG_HOME}/herdr/plugins/config/desktop-pet` 또는 `~/.config/herdr/plugins/config/desktop-pet`, state `${XDG_STATE_HOME}/herdr/plugins/desktop-pet` 또는 `~/.local/state/herdr/plugins/desktop-pet`입니다. 이 기본 프로필은 위에서 분리한 경로와 **다르며**, `PATH`의 실행 파일은 구형 앱일 수 있으므로 세 값을 모두 명시하세요. 플러그인은 `tern-exchange`를 호출할 뿐 네이티브 펫을 시작하지 않으므로 해당 프로필에서 펫을 먼저 실행해야 합니다.

전체 연결을 설정한 뒤, 이전 오류로 창의 타이머 훅이 비활성화되었다면 명시적으로 `tern plugin reload`를 실행하세요. 예를 들어 잘못된 기본 실행 파일 경로를 사용한 뒤 콜백 예산 초과 오류가 난 경우입니다. 올바른 프로필을 저장하거나 **Connect to desktop pet**을 선택해도 Tern이 비활성화한 훅은 다시 켜지지 않으며, 다시 로드할 때까지 비활성 상태를 유지합니다. 이후 데몬의 플러그인 목록만이 아니라 로그인된 실제 창을 확인하세요. 이번 수정에서 사용자의 기존 창 로그인은 정상 동작했습니다. 일반적인 로그인 또는 Keychain 문제의 증거가 아닙니다.

KV는 창 사이에 공유됩니다. 다른 창이 프로필을 저장하면 지연된 설정 질문과 교환 콜백을 차단합니다. 이전 질문 흐름이 새 객체를 덮어쓸 수 없고 이전 교환이 새 프로필로 ask를 전달할 수 없습니다. 하위 프로세스 응답을 해석하기 전과 `agents:ask` 직전에 프로필을 다시 읽습니다. 외부에서 잘못된 형식의 객체를 저장하면 레거시 설정을 되살리지 않고 교환을 중단합니다.

플러그인은 Tern 창의 `hosts`, `panes`, `tabs`, `sessions`, `agents` 목록을 읽고 로컬 호스트가 정확히 하나일 때 그 호스트의 에이전트 pane만 제한된 stdin/stdout `tern-exchange` 하위 프로세스를 통해 네이티브 앱의 같은 사용자 전용 소켓으로 전달합니다. 원격 에이전트 대체 경로는 없습니다. 네이티브 말풍선에서 로컬 세션을 볼 수 있고, 살아 있는 카드를 선택하면 답장 입력이 제공될 수 있습니다. 전송 시 pane을 재확인하고 터미널 입력 대신 Tern의 `agents:ask`를 사용합니다. ask가 성공하고 네이티브 상태가 `prompt_accepted`로 바뀌어도 이는 Tern이 텍스트를 **수락했거나 대기열에 넣었을 수 있다**는 뜻이지, 모델이 읽었다거나 최종 답을 전달·완료했다는 뜻이 아닙니다. 접수 ACK를 작업 완료로 해석하지 마세요. 오류가 나면 Tern 창의 데스크톱 펫 오류 토스트/로그, `tern plugin list`, 네이티브 `status`, 설정된 실행 파일과 프로필, `<state-dir>/desktop-pet.log`를 확인하세요. 연결이 끊기거나 결과를 알 수 없을 때 무작정 재전송하지 마세요.

목록 수집은 Tern의 문서화된 `tern.sleep(0):next(...)`로 예약하는 **지연 0 awaitable 콜백 네 번**으로 나눕니다. `tabs`, `sessions`, `agents`는 각각 별도 콜백에서 읽고, 마지막 콜백은 `hosts`와 `panes`를 함께 읽은 뒤 공용 순수 검증을 수행합니다. 클 수 있는 에이전트 페이로드는 따로 수집합니다. 중요한 로컬 호스트 소속과 pane 검사는 마지막 콜백의 새 `cx`를 공유하며, 명령 재검증도 같은 새 컨텍스트에서 `agents:get`, `agents:ask`를 실행합니다. 첫 후속 실행을 예약하기 전부터 수집 작업은 활성/busy 상태이며, 소스 인스턴스·프로필·작업 식별자·단계 경계 검사가 수집과 재검증의 지연 콜백을 차단합니다. 일반적인 1.2초 폴링 타이머는 유지하지만, 목록 단계 전환에는 더 이상 거친 1 ms 타이머를 사용하지 않습니다.

각 콜백의 **동기 목록 SDK 호출은 최대 두 번**입니다. 목록 호출당 12 ms를 부과하면 Tern의 50 ms 콜백 예산에 대해 모델링된 목록 비용은 최대 `2 × 12 = 24 ms`이며, 호스트 호출이나 콜백 전체 지연 시간을 보장하는 수치가 아닙니다. 소유한 비공개 프로필의 제한된 측정에서 지연 0 awaitable 콜백 다섯 번에 약 20 ms가 걸렸고, 하위 프로세스 표본 20개에서는 동기 실행 시작 비용 0.49–1.68 ms, 전체 프로세스 시간 150–208 ms를 관측했습니다. 이는 일반적인 오버헤드 벤치마크나 전체 처리 시간의 보장이 아닙니다. 개별 SDK 호출, 그 밖의 콜백 작업, OS 선점만으로도 50 ms를 넘을 수 있으며, 지연 0 후속 실행이 무기한 중단 없는 폴링을 보장하지는 않습니다.

다시 로드하거나 새 창을 열면 독립적인 소스 식별자가 생깁니다. 이전 인스턴스와 닫힌 창은 새 창에 조용히 병합되지 않고 단조 시계 기준 신선도 경과 시간이 **5초 이상**일 때 **Offline**이 됩니다. 네이티브 제어 연결 수락 루프는 기존 100 ms 틱으로 만료를 확인하며 직렬 Herdr 폴링이나 클라이언트 I/O와 독립적입니다. 여러 창은 각각 독립적입니다. **64개 소스 한도는 Herdr와 Tern이 공유**하며, Herdr와 별도로 Tern 창 64개를 허용하는 것이 아닙니다. 등록은 대기 중인 작업을 먼저 최종 처리한 뒤 만료된 오프라인 Tern 소스만 회수할 수 있습니다. 살아 있는 Tern 소스나 Herdr 소스는 축출하지 않으며 소스 ID를 재사용하지 않습니다. 플러그인 스냅샷당 로컬 에이전트는 최대 128개입니다. Tern 변경이나 데몬 재시작은 대기 중인 답장을 무효화할 수 있으므로 과거 창의 결과로 성공을 가정하지 말고 현재 카드/상태를 확인하세요.

## 교환 크기 제한과 복구

교환 봉투는 버전 1이며 네이티브 앱/업데이트 프로토콜은 3을 유지합니다. 요청 한도는 **직렬화된 JSON 256 KiB**이며, 선택적인 전송용 LF 또는 CRLF는 JSON 한도에 포함하지 않습니다. 독립적인 응답 한도는 **마지막 LF를 포함한 전체 stdout 512 KiB**입니다. 문자 수나 원본 프롬프트 길이가 아닌 바이트 제한입니다. 네이티브 접수는 대기 작업을 만들거나 명령을 제공하기 전에 실제 호스트 응답을 직렬화하여 검사합니다. 이스케이프 후 한도에 들어가지 않는 페이로드는 불확실한 전송이 아닌 확정적인 `prompt_too_large`/`TooLarge` 결과가 되며 명령을 제공하지 않습니다. 추정한 프레이밍 여유분을 빼는 방식으로 Herdr 허용량을 계산하지 않습니다.

최초 미바인딩 전체 스냅샷은 `instance_id: null`, 빈 `results`를 가지며, 등록 성공 응답의 `command`는 `null`입니다. 실패 응답에는 다음 다섯 값 중 하나인 구조화된 `error_code`가 선택적으로 들어갈 수 있습니다.

| `error_code` | 플러그인 복구 동작 |
| --- | --- |
| `binding_required` | 소스 식별자를 초기화하고 다음 일반 폴링에서 결과 없는 새 스냅샷으로 등록합니다. 최초 등록 응답이 유실되어도 별도 재시도 루프 없이 이 경로로 복구합니다. |
| `instance_changed` | 응답의 네이티브 인스턴스 ID가 달라지면 기존 바인딩과 결과 보고가 무효화됩니다. 초기화 후 다음 일반 폴링에서 등록하며, 대기 중인 전달 결과는 알 수 없는 상태입니다. |
| `source_retired` | 초기화 후 다음 일반 폴링에서 새 소스를 등록합니다. 폐기된 소스의 ask를 재실행하지 않습니다. |
| `receipt_rejected` | 캡처한 인스턴스와 정확히 바인딩된 응답일 때만 캡처한 결과 보고를 버리고, 소스 바인딩과 더 새로운 보고는 유지합니다. 미바인딩/불일치 거절은 보고를 버릴 근거가 아닙니다. |
| `rejected` | 실패를 표시합니다. 성공적인 전달로 추정하거나, 이 코드만으로 바인딩을 초기화하거나, ask를 재실행하지 않습니다. |

명령의 수락 또는 실패를 보고한 뒤, 플러그인은 다음 1.2초 폴링을 기다리지 않고 **일반적인 새 전체 목록 교환을 즉시 시작**해 영수증을 보냅니다. 새 전체 스냅샷을 수집하며, 캐시된 스냅샷을 오래된 검증 근거로 사용하거나 `agents:ask`를 재실행하거나 새 영수증 프로토콜을 추가하거나 타임아웃을 늘리지 않습니다. 복구 교환도 목록을 갱신할 뿐 **결과가 불확실한 `agents:ask`를 재실행하지 않습니다**. 성공적인 제출 영수증도 수락/대기열 접수만 뜻하며 모델의 작업 완료를 뜻하지 않습니다.

## 실제 프로덕션 코드 Luau 회귀 하네스

[`tests/transition-regressions.luau`](tests/transition-regressions.luau)는 실제 Tern 창 Luau VM에서 `window.luau` 원본을 변경하지 않고 `function(tern)` 래퍼 안에서 실행합니다. 예를 들어 절대 경로를 바꾼 다음 창에서 지원하는 Luau 실행 기능([Carly의 Lua 도구 래퍼](https://docs.stencil.so/tern/reference/api-window.html#carlys-lua-tool))으로 다음을 실행하세요.

```lua
local TEST_PATH = "/absolute/path/to/tern-desktop-pet/tests/transition-regressions.luau"
local WINDOW_PATH = "/absolute/path/to/tern-desktop-pet/window.luau"
local suite = assert(loadstring(tern.fs.read(TEST_PATH)))()
local source = tern.fs.read(WINDOW_PATH)
suite.run(tern, source, function(results)
    print(tern.json.encode(results))
end)
-- 비동기 실행: suite.get_results()에서 done/passed/total/cases를 확인합니다.
```

각 사례는 실제 Tern 타이머 콜백으로 예약되고 실제 JSON 코덱을 사용하되, 목록, KV, 질문, 목록 후속 실행 예약, 하위 프로세스 결과, 에이전트 ask는 **통제된 SDK 경계**로 대체합니다. 실제 KV 쓰기, 하위 프로세스, 질문, `agents:ask`는 하네스 밖으로 나가지 않습니다. **현재 awaitable 콜백 수정의 검증은 실제 Tern 0.6.1 창 Luau VM에서 44/44 통과**이며, 독립적인 모델이 아니라 프로덕션 소스를 실행했습니다. 기존 35개 사례, 프로필/소스 식별자/pane/로컬 호스트 단계 경계 검사, 최신 로컬 소속과 pane 식별자 검사, 목록 API당 12 ms·콜백 예산 50 ms 사례, awaitable 실패 시 busy 정리 및 재실행 없는 명령 취소를 포함합니다. 예약 사례는 **타이머 지연 1초와 마이크로태스크 후속 실행당 10 ms**를 모델링하며, 실제 네이티브 하위 프로세스가 아닌 통제된 영수증 소비자를 사용해 네이티브 **5초 기한** 전에 수락 영수증을 확인합니다. 이전 타이머 청크의 43/43 실행은 과거 증거이며 현재 리비전의 증거가 아닙니다. 통제된 SDK 회귀 검증은 측정된 호스트 지연 시간의 보장이나 **전체 실제 에이전트/모델 전달 스모크 테스트가 아닙니다**. 대화 기록 수준의 검증을 대신하거나 위의 이전 실제 에이전트 관측과 혼동하지 마세요.

별도의 이전 창 검증에서는 7초 전후로 소스 관측이 계속 유지되고 의미 기반 `agents:ask`의 영수증이 제때 도착했습니다. 그러나 이후 타이머 청크 실행은 약 16분 뒤 50 ms 콜백 한도에 걸렸으며, 이것이 awaitable 방식으로 전환한 이유입니다. 이전 관측과 비공개 프로필의 시간 측정은 무기한 콜백 예산 준수의 보장이 아닙니다.

실제 설정된 창에서 최종 awaitable 리비전을 실행하자, 이전 소스에 대한 6.25초 유예 뒤 현재 프로필에 새 소스 하나가 관측되었습니다. 이후 실제 네이티브 `sessions.prompt` 작업은 종료 코드 0과 함께 `prompt_accepted`, `committed: false`, `native_applied: false`, 전달 상태 `accepted_may_be_queued`를 반환했습니다. 이어지는 GUI 프로필 전환 전에는 3초 간격 상태 표본 다섯 개 모두 연결된 소스 하나를 표시했습니다. 실제 GUI 설정 흐름에서 **A → B** 전환을 완료한 뒤, 추가 6.25초 유예 후 정식 연결 객체의 config/state 경로는 모두 B였고, 이전 프로필 A는 `connected: false`, 새 프로필 B는 `connected: true`를 보고했습니다. 확인한 로그 구간에는 새 프로덕션 콜백 예산 초과 오류가 없었습니다. 이는 유한한 시점의 관측이며 무기한 50 ms 예산 준수나 호스트 지연 시간의 보장이 아닙니다. 의미 기반 전달 수락과 완료된 설정 전환을 확인한 것이지, 네이티브 업데이터의 전체 GUI Apply 흐름을 검증한 것은 아닙니다.

**현재 특정 응답의 대화 기록 수준 전달 증거:** 소유한 실제 Tern 세션 JSONL에서 이후 assistant 역할 메시지의 정확한 텍스트 `TERN_MICROTASK_SMOKE_OK`를 확인했습니다. 이는 요청한 이 특정 모델 답변이 전달되었음을 별도로 확인합니다. 네이티브 수락 영수증만으로 확인한 것이 아니며, 일반적인 모델 작업 완료나 이후 영수증의 최종 답변 전달을 보장하는 관측도 아닙니다.

## 라이선스

**이 플러그인 저장소의 코드**는 [LICENSE.txt](LICENSE.txt)의 MIT 라이선스를 따릅니다. 네이티브 앱과 번들 캐릭터 그림은 별도의 앱 체크아웃에 남아 있으며 각자의 고유 고지를 따릅니다. 플러그인의 MIT 라이선스가 Rubelia 또는 다른 그림의 라이선스를 바꾸거나 이를 번들한다는 뜻은 아닙니다. 이곳에는 그림을 복사하지 않았습니다.
