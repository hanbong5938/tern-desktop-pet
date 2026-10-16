# Tern Desktop Pet

[English](README.md) · **한국어**

## Desktop Pet 소비자 — 플러그인 0.2.1 소스 후보

이 창 플러그인은 Tern 에이전트 관찰과 의미 기반 질문을 별도로 설치한 호스트 중립 [Desktop Pet](https://github.com/hanbong5938/desktop-pet) 앱에 연결합니다. `native-adapter`는 Tern 연동만 소유하며 앱·UI·캐릭터·업데이터는 공통 저장소에 있습니다. 플러그인은 네이티브 앱을 **다운로드·설치·빌드·자동 시작·중지하지 않습니다**. 플러그인 업데이트/제거로 공용 앱이나 두 프로필 디렉터리를 변경하지 않습니다.

[앱 홈페이지](https://hanbong5938.github.io/desktop-pet/) · [Core 설치·프로필](https://github.com/hanbong5938/desktop-pet/blob/main/docs/development.ko.md) · [현재 앱 사용법](https://github.com/hanbong5938/desktop-pet/blob/main/docs/usage.ko.md) · [Core Wiki](https://github.com/hanbong5938/desktop-pet/wiki) · [기존 설치 이전](https://github.com/hanbong5938/desktop-pet/blob/main/docs/migrations/desktop-pet.md). 링크는 core 소유의 목적지이며 실제 공개 배포·재연결 증거가 아닙니다.

**공개/검증 상태:** 플러그인 **0.2.1**, Core **0.4.9**, bridge **0.3.13**은 아직 공개·적격 검증하지 않은 후속 후보입니다. 이전의 **adapter 41개 / 통제 경계 150개 사례** 결과는 구형 Tern revision `1b3798871131da5f88a705440f9f0cfb8f905fa0`에만 해당하며 이후 경로/cold-load 수정이나 실제 재연결을 검증하지 않습니다. 이전 독립 [Desktop Pet v0.4.1](https://github.com/hanbong5938/desktop-pet/releases/tag/v0.4.1)의 공개·네이티브 준비 및 **Tern 0.8.3 통제 경계 132/132 / adapter 38개** 관측은 과거의 제한된 증거이지 현재 바이트의 적격 검증이 아닙니다. 최종 불변 소스/산출물 revision에서 지원되는 실제 창의 cold load, 인증된 네이티브 경로 전환과 현재 instance의 신선한 binding을 검증해야 합니다. 문제 컴퓨터의 구형 실행 파일 없음은 네트워크·계정·Keychain 실패의 증거가 아니며 별도 toolsMac의 `load` 50 ms 실패도 그 컴퓨터의 원인을 입증하지 않습니다. 아래 0.1.0/Herdr 네이티브 관측은 과거 증거로만 보존합니다.

### 새 설치·수동 설정: 네이티브 앱은 별도로 설치·시작

**새 설치·수동 설정**에서는 공개 앱을 별도로 `brew install hanbong5938/tap/desktop-pet`으로 설치하거나 명시적으로 검증한 core 소스 빌드를 사용하세요. 구형 포뮬러는 새 제품의 별칭이 아닙니다. 네이티브를 직접 시작한 후 실제 실행 파일과 두 프로필 경로를 **Configure desktop pet connection → Connect to desktop pet**에서 선택하세요. 아래의 승인된 자동 업데이트는 Configure·Resume·추가 동의 질문이 **필요하지 않습니다**. 이 플러그인 설치로 네이티브 앱을 설치하거나 시작하지 않습니다. 로컬 core 개발 예시:

```sh
CORE=/absolute/path/to/desktop-pet
# 공통 저장소의 빌드 준비 조건과 소스 설치 안내를 먼저 따르세요.
(cd "$CORE" && bash scripts/install.sh --source)
PET_BIN="$CORE/dist/DesktopPet.app/Contents/MacOS/desktop-pet"
"$PET_BIN" update-capabilities
# integration_api: 1 확인. 중립 앱/도우미: protocol: 4, observation_mode: 2.
"$PET_BIN" profile show --json
```

`profile show --json`은 `{ "version":1, "config_dir":"/absolute/...", "state_dir":"/absolute/..." }`를 읽기 전용으로 반환하며 디렉터리를 만들거나 데몬을 시작하지 않습니다. 결과의 **두 경로를 함께** 복사하거나 기존 프로필의 두 경로를 명시적으로 선택하세요. 앱은 같은 경로로 직접 시작합니다. Tern 전용이면 `--host tern`, 등록된 연동을 함께 관찰하려면 네이티브 Auto를 선택합니다.

```sh
PET_CONFIG=/absolute/path/from/profile-show
PET_STATE=/absolute/path/from/profile-show
DESKTOP_PET_CONFIG_DIR="$PET_CONFIG" DESKTOP_PET_STATE_DIR="$PET_STATE" \
  "$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" --host tern start
"$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" status

# 로컬 플러그인 개발: 네이티브 앱을 설치/빌드하지 않습니다.
tern plugin link /absolute/path/to/tern-desktop-pet
tern plugin reload
tern plugin list
```

공개 후 별도 플러그인 설치 명령은 `tern plugin install https://github.com/hanbong5938/tern-desktop-pet`입니다. 정당한 Tern 베타 접근과 로그인된 실제 창이 필요하며 헤드리스 카탈로그만으로 실행이나 재연결을 검증할 수 없습니다.

**이미 설치된 플러그인 배포:** 앱만 업데이트하거나 후속 소스를 공개해도 설치된 플러그인 0.2.0의 창 VM은 바뀌지 않습니다. 승인된 네이티브 이전은 Tern의 지원되는 [`tern plugin install <package-dir> --force --json`](https://docs.stencil.so/tern/reference/cli.md#tern-plugin-install) 계약으로 신뢰된 후속 플러그인도 전달해야 합니다. Tern은 설치 복사본을 원자적으로 교체하고 별도 KV를 보존하며 [창 VM을 자동 재로드](https://docs.stencil.so/tern/concepts/lifecycle.md#reloading)합니다. `window_start`가 반복되지 않아도 시작 timer가 재연결하며 두 시작 경로는 하나의 진행 중 setup 흐름을 공유합니다. `--force`는 연결된 개발 패키지를 덮어쓰지 않습니다. 설치 exit 0·설치 버전·재로드 요청·헤드리스 Ready 카탈로그는 재연결 증거가 아닙니다. 새 이전은 durable 네이티브 Commit 뒤 **승인된 구형 설치/별칭을 폐기하기 전에** 소비자를 전달·로드하고 필수 실제 신선한 binding 이후에만 폐기해야 합니다. 전달·재로드·binding 실패는 앱 commit/연동 사용 불가/폐기 대기 상태로 드러나야 하며 전체 완료나 추가 수동 Configure·업데이트 확인으로 대신하지 않습니다.

### Connect·Configure·기존 연결 이전

**Connect to desktop pet**은 저장된 절대 실행 파일을 검증하거나 다음 순서로 중립 앱을 찾습니다: 명시적 절대 실행 파일 → OS 계정 home의 검증된 비공개 `.local/share/desktop-pet/installation.json` → `PATH`의 `desktop-pet` → 실제 `brew --prefix desktop-pet` → OS 계정 home의 `Applications/DesktopPet.app`. 잘못된 명시적 경로/locator는 다른 설치로 우회하지 않고 실패합니다. bootstrap은 중립 bundle identity와 앱/도우미 서명을 확인한 뒤 일치하는 도우미의 읽기 전용 `discover --json`을 실행하고, 도우미가 실제 설치 origin/capability를 검증합니다. 앱 탐색을 위해 셸 wrapper를 실행하지 않습니다. 호환성은 플러그인/앱 버전 일치가 아닌 **`integration_api:1`**입니다.

탐색·capability·`profile show --json`은 제한된 [문서화된 awaitable 하위 프로세스](https://docs.stencil.so/tern/reference/api-shared.md#ternprocessrun) 단계로 실행합니다. 일반 폴링은 재탐색이나 콜백의 동기 대기 없이 검증한 절대 경로 세 값만 사용합니다. 새 기본 경로는 검증된 앱의 profile 응답에서만 얻고 **Herdr 경로를 조합하지 않습니다**. 앱 없음·JSON 오류·시간 초과·호환 API 없음·권한/서명 오류는 실제 오류를 표시하고 저장하지 않습니다. 다른 창이 연결을 원자적으로 저장하면 이전 작업을 폐기하고 다음 주기 tick에서 정확히 그 실행 파일과 두 경로를 검증한 후 자동 재연결합니다. custom 실행 파일을 탐색 결과로 대체하지 않습니다.

**Configure desktop pet connection**은 의도적인 경로 변경·복구에 계속 사용할 수 있습니다. 절대 실행 파일, 절대 config 디렉터리, 절대 state 디렉터리를 순서대로 묻고 설치된 앱과 전체 후보 프로필을 검증한 뒤 한 번의 원자적 KV 쓰기로 `{ version = 1, executable = "...", config_dir = "...", state_dir = "..." }` 객체를 저장합니다. 아래의 증거로 허용된 저장 경로 전환 외에는 Connect가 객체를 다시 쓰지 않습니다. 취소·검증/저장 실패·오래된 콜백은 이전 객체를 보존합니다. 완전한 구형 세 키는 자동 저장 없이 읽을 수 있고 Configure 또는 승인된 전환 성공 시 정식 객체를 먼저 저장한 후 구형 키 정리를 시도합니다. 불완전한 구형 설정은 명시적 복구가 필요하며 잘못된 정식 객체가 있어도 구형 키를 되살리지 않습니다.

**SDK 동시성 경계:** 창만 [`tern.kv.get/set`](https://docs.stencil.so/tern/reference/api-shared.md#ternkv)을 사용하며 네이티브는 플러그인 KV를 편집하지 않습니다. 비동기 콜백 전후와 단일 정식 SDK 저장 직전에 저장 identity·소스 generation을 비교합니다. 자기 쓰기를 다시 읽은 뒤에만 활성화하고, 대체된 exchange는 연결 성공을 주장하거나 ask를 전달할 수 없습니다. 이는 **낙관적 변경 검사와 원자적 교체이지 트랜잭션 compare-and-set이 아닙니다**. SDK에는 CAS가 없으며 서로 다른 VM의 정확히 동시 쓰기는 마지막 rename이 이깁니다. 관측된 수동/custom/잘못된 형식의 중간 변경은 오래된 콜백을 차단합니다. 대체되거나 다시 읽을 수 없는 저장은 버려진 경로를 활성화하지 않고 실제 저장 경로의 정확한 재검증을 기다립니다.

저장된 실행 파일이 `herdr-desktop-pet`이며 **`/opt/homebrew/bin/herdr-desktop-pet` 별칭이 사라진 경우**도, 보존된 증거가 그 정확한 경로를 인증하면 최초 네이티브 업데이트 승인만으로 충분합니다. Connect와 주기 tick은 서명된 중립 앱을 질의 전송 대상으로 찾은 뒤 사라진 구형 실행 파일을 실행하지 않고 **저장된 실행 파일과 원래 config/state 경로 두 개 전체**의 읽기 전용 `legacy-migration-route` 증거를 요청합니다. 버전 1 응답은 `committed:true`와 정확한 `original`·`target` 연결 세 값을 포함해야 하며 단순 탐색은 이전 권한이 아닙니다. 원본은 변경 없는 저장 값과 같고 대상은 검증된 실행 파일 및 같은 config/state 경로와 같아야 합니다. 그때만 SDK 저장 후 binding/result를 비운 새 소스로 Configure·Resume·재연결 질문 없이 자동 연결합니다. 보존된 경로 계보·승인·대상·Tern provider가 없으면 실제 실패를 표시하며 별칭 계보를 꾸미거나 대체 symlink를 만들지 않습니다. 이후 네이티브 commit은 다음 1.2초 주기 tick에서 감지할 수 있고 setup 시도는 겹치지 않으며 각 하위 프로세스 제한은 10초입니다. 플러그인은 네이티브를 설치/시작/중지하거나 프로필·이전 journal·캐릭터·대화·기록을 이동·병합·삭제·재작성하지 않습니다.

**네이티브 증거 허용 경로는 둘입니다.** 새 이전의 폐기 전 경로에는 불변 최초 승인/저장 경로, 정확한 대상 이미지와 실행 중인 원래 프로필, 성공한 필수 manager 결과, durable Commit, 현재 Stop 경계가 필요하며 이미 폐기되었음을 요구하면 안 됩니다. 과거 commit된 `AwaitingReconnect` 복구에는 보존된 실제 Commit/폐기와 인증된 동일 프로필의 현재 소유자/후속 설치 증거가 필요합니다. 이 경로 질의는 읽기 전용이며 복구가 migration·manager·Stop/start·Commit·폐기를 재실행하거나 원본 plan/journal을 변경해서는 안 됩니다. 사용자 Stop은 자동 시작/전달 권한을 무효화하며 소비자는 네이티브를 시작해 이를 무시하지 않습니다.

같은 정확한 증거로 오래되거나 삭제된 정식 Homebrew keg 등 중립 `desktop-pet` 저장 경로도 복구합니다. Connect는 **구형일 수 있는 실행 파일을 호출하기 전에** 서명된 현재 소유자 전송 대상으로 증거를 질의하며, 일치하는 증거가 없으면 저장된 원본만 검증하고 탐색한 앱으로 대체하지 않습니다. 원본이 없거나 활성 중립 연결이 실패/데몬 identity가 바뀌면 겹치지 않는 제한된 주기 질의로 commit된 현재 소유자를 감지합니다. 질의 실패만으로는 저장 값과 아직 유효한 binding/불확실한 결과를 폐기하지 않습니다. 실제 데몬 instance 변경은 실행 파일이 이미 현재 버전이고 KV 재저장이 없어도 별도로 이전 결과를 차단하고 결과 없는 새 소스를 등록합니다. 성공에는 변경 없는 경로나 경로 증거가 아닌 새 instance와의 exchange가 필요합니다. 정확한 네이티브 증거가 허용하지 않는 `desktop-pet` 이름의 custom 경로를 포함해 정상 custom 설정은 그대로 유지합니다.

**전달된 소비자의 handover:** 버전 1 경로 요청은 바꾸지 않습니다. 응답은 `version`, `kind`, `committed`, `original`, `target`을 유지하고 `handover`만 선택적으로 추가할 수 있습니다. 검증된 네이티브 capability `migration_handover_protocol:1`이 있을 때만 이 추가 필드와 별도 `migration-integration-handover` receipt 명령을 사용합니다. Descriptor는 소문자 16진수 32자리 operation ID, 절대 plan 경로(4096바이트 이하), 소문자 16진수 64자리 plan digest·token, 소문자 16진수 40자리 소비자 revision, 비어 있지 않은 대상 instance(128바이트 이하)만 엄격히 허용합니다. SDK 저장/다시 읽기 검사 뒤 또는 정확히 같은 저장 대상이면, 요청과 성공 응답이 모두 대상 instance를 지정하고 로컬 generation이 양수인 **결과 없는 bound v2 exchange**를 완료해야 합니다. 그 뒤 정확한 descriptor·원본/대상 세 값·실제 exchange 소스 `window_id`(256바이트 이하)·`loaded_protocol:1`을 보냅니다. 네이티브는 durable 전달·실제 설치된 패키지/window 해시·SDK 저장 후 대상·현재 Stop 경계·**바로 그 소스 창의 신선하고 확인된 binding**을 독립적으로 인증한 뒤 settlement receipt를 기록합니다. CLI exit 0·token/revision echo·다른 창·일반 binding 증거로 대신할 수 없습니다. Revision은 승인된 capability이지 VM bytecode의 자체 증명이 아니며 소비자는 패키지 파일을 읽거나 별도 context 명령을 쓰지 않습니다.

이미 현재 경로인 정식 연결은 KV 재저장이 필요 없지만 인증된 경로 handover와 현재 instance receipt는 필요합니다. 변경 없는 완전한 구형 세 키 대상은 인증된 handover 권한 아래에서만 정식 객체로 저장할 수 있고, 그 뒤 결과 없는 새 소스와 bound exchange가 있어야 receipt를 보냅니다. Protocol 1 capability가 있으나 handover 권한이 없으면 활성 중립 연결은 **정확한 저장 세 값**을 겹치지 않게 **최대 10초에 한 번** 질의하여 이후 네이티브 Commit도 Configure 없이 감지합니다. 선택적 질의의 부재/실패는 로그에 남기되 실제 정상 binding을 끊지 않으며 권한이나 저장되지 않은 기본 경로를 꾸미지 않습니다. 필수 handover 실패는 드러나며 **최소 1.2초 뒤**의 다음 일반 신선한 결과 없는 bound exchange 이후에만 동일한 멱등 receipt를 재시도할 수 있고 하위 프로세스 제한은 10초입니다. Stop/identity 변경으로 manager·네이티브 시작·불확실한 ask를 재실행하거나 폐기를 허용하지 않습니다. 실제 전달·cold-load·runtime 적격 검증은 필수입니다.

인증된 로컬 control 질의 `{"version":1,"kind":"tern-migration-evidence"}`에는 사용자가 만든 증거 파일이나 창 식별자가 필요하지 않습니다. 어댑터는 실제로 신선하며 현재 데몬 확인이 끝난 로컬 binding을 골라 실제 `instance_id`, `window_id`, `binding_epoch`, `sequence`, `local_host`, `observation_generation`, `native_generation`, `fresh:true`를 반환합니다. 선택적 `window_id`를 지정하면 해당 창만 허용하고 다른 창으로 우회하지 않습니다. 미확인·오래됨·Offline·원격·읽기 전용·generation 불일치·폐기 source는 증거가 될 수 없으며 적합한 binding이 없으면 성공을 꾸미지 않고 오류를 반환합니다.

새 설치나 수동 연결은 네이티브 `status`에서 실제 실행 이미지와 선택한 두 경로를 확인하세요. 승인된 네이티브 이전이 아닌 경우 다른/구형 데몬이 프로필을 소유하면 그 실행 파일과 같은 경로로 직접 중지한 뒤 의도한 앱을 시작해야 합니다. 플러그인은 몰래 데몬을 교체하지 않습니다. `DESKTOP_PET_CONFIG_DIR` / `DESKTOP_PET_STATE_DIR` 환경 변수와 명시적 native 인자는 항상 같은 두 경로를 선택합니다.

소스·인스턴스·generation·공유 KV·단계·pane/host 경계를 유지합니다. 연결 전환은 활성 경로 변경 전에 이전 작업을 폐기합니다. 이미 제공했거나 불확실한 ask는 **UnknownDelivery**이며 새 binding에서 재전송하지 않습니다. `agents:ask` 성공은 수락/대기열 접수 가능성을 뜻하며 모델 작업 완료가 아닙니다. 현재 소스의 exchange는 **버전 2**로 독립된 host별 스냅샷과 관찰/네이티브 generation을 사용하며 저장된 연결 객체는 **버전 1**입니다. 원격 host는 읽기 전용 관찰이며 의미 기반 `agents:get`/`agents:ask`는 로컬만 허용합니다. 요청 256 KiB/응답 512 KiB의 독립 한도는 유지합니다.

### 현재 소스: 연결된 모든 Tern 호스트

Tern 관찰이 활성화되면 플러그인은 창의 `hosts`, `panes`, `tabs`, `sessions`, `agents` 목록으로 **로컬 호스트와 연결된 모든 원격 호스트**를 자동 관찰합니다. 새 호스트 선택 UI는 없습니다. Herdr의 로컬/원격 스위치와 머신 선택은 Tern 호스트를 필터링하지 않습니다. SDK 목록에는 여전히 정확히 하나의 로컬 호스트가 필요하지만, 이는 답장 안전 조건이지 로컬 전용 관찰 제한이 아닙니다.

교환은 **v2만** 지원하며 호스트별 스냅샷을 `hosts` 배열에 보냅니다. 각 항목은 호스트 식별자·이름/label·`is_local`·상태(`available`, `disconnected`, `unavailable`)·`observation_generation`·자신의 agents 배열을 갖습니다. 네이티브 응답은 각 호스트의 관찰 generation과 독립적인 네이티브 `generation`을 반환하며 exchange-v1로 되돌아가지 않습니다. 세션 키는 호스트 식별자/generation을 포함하므로 pane ID가 같아도 서로 다른 호스트가 병합되지 않습니다. 호스트 이름 변경은 label만 갱신하고 세션 키는 유지합니다. 네이티브 소스에는 호스트 이름과 **로컬 / 원격(Local / Remote)** 표시의 영어·한국어·일본어·중국어 번역이 있으나 실제 화면 검증은 하지 못했습니다.

호스트 단절·복구·신선도는 독립적입니다. 관측된 단절/목록 불가 또는 목록에서 빠진 호스트는 다른 호스트와 별개로 **Offline**이 됩니다. 관측된 복구 또는 식별/locality/address 변경 시 해당 호스트의 플러그인 관찰 generation이 증가합니다. 이는 관찰 수명이며 스냅샷 사이에 끝난 재연결에 대한 **SDK transport generation 보장이 아닙니다**. 네이티브는 단조 시계 기준 신선도가 5초 이상 경과하면 해당 네이티브 수명을 만료시킵니다. 따라서 플러그인 관찰 generation이 그대로여도 이후 새 네이티브 generation을 받을 수 있습니다. 다시 로드하거나 닫힌 창의 parent/source 식별자는 독립적이며 조용히 병합되지 않습니다.

**일치하는 네이티브 소스: 신선도 5초 + Offline 보존 30초.** 현재 네이티브 구현은 Tern Offline 행을 단조 시계 기준 30초 유예 뒤 기존 100 ms 유지보수에서 새 등록 없이 소스·행·집계·registry child와 함께 제거합니다. 자연 만료의 유예 시작은 `last_seen + 5s`, 명시적 손실(단절/unavailable·완전한 목록에서 누락·관찰 epoch 전환)은 최초 유효 관측 시점입니다. 반복 손실·다른 호스트 heartbeat는 유예를 늘리지 않고 정리 전 일관된 복구는 해제합니다. live Tern·정상 available 빈 호스트·Herdr는 TTL 정리하지 않습니다. 원격 child 정리는 살아 있는 parent의 binding·로컬 상태를 보존하며 죽은 빈 parent는 결국 정리되고 이전 binding 요청은 `SourceRetired`가 됩니다. generation/revision 경계와 ID 비재사용으로 오래된 키 거절을 유지하고 ask는 최초 손실 때 확정하며 재전송하지 않습니다. 기존 64-source 용량 회수는 더 일찍 가능하고 high-water 메타데이터는 남으므로 전체 과거 메모리 상한이나 정확한 벽시계 마감을 뜻하지 않습니다. 이 소스 전용 네이티브 변경은 **플러그인 RPC·타이머·식별자를 바꾸지 않으며**, 공개 중립 번들에 포함되었다고 주장하거나 네이티브 설치 정책을 완화하지 않습니다.

**Adapter 추출 의미 보존:** `native-adapter`가 최초 손실 시계와 `TernIntegration::tick`의 보존 정리를 소유하며 공통 domain은 `remove_offline_source`로 정확한 offline generation을 재확인합니다. 교환은 신선도만 만료시키고 보존 정리는 수행하지 않습니다. 성공한 helper 응답은 바인딩된 daemon instance와 일치해야 하며 영수증으로 새 parent epoch를 만들 수 없습니다. 요청 크기는 디코딩 전 실제 JSON으로 검사하고 생략된 선택 필드를 정규화된 `null`로 다시 계산하지 않습니다. 현재 adapter의 두 suite에서 **41개 테스트가 통과**했습니다. 아래 원본 native 근거는 이 adapter 결과와 별개입니다.

**보존 검증 범위:** main native **760 통과/1 ignored**, 실제 AppKit composer·네이티브 IME callback·렌더 이미지 검사, coordinator **73**, Bun **59**, 실제 Tern VM 통제 경계 Luau **132/132**가 통과했습니다. populated 주입 v2 IPC는 새 등록 없이 **1 live/63 Offline → 1 live/0 Offline**으로 정리되었습니다. 별도 실제 SDK 소유 in-process loopback의 빈 호스트 관측 bridge는 **2 connected/0 Offline → stalled 1 connected/1 Offline → 정리 1 connected/0 Offline → 복구 2 connected/0 Offline**을 보였고 로컬 generation은 유지했습니다. 설치된 프로덕션 플러그인 연결·외부 실제 원격 에이전트·네트워크 장애·semantic ask/모델 전달 증거가 아닙니다. 중립 설치의 API 1/protocol 4 요구와 native checkout의 protocol 3/API 없음 차단은 그대로입니다. 사용자가 승인한 권한 없는 AppKit·소스 앱 IPC·선택/커서 검사는 실제 카드 클릭 자동화·물리 IME 인증을 주장하지 않으며 이전 0.1.0/v0.3.6 근거는 그대로입니다.


목록 수집은 기존 지연 0 awaitable 단계를 유지합니다. `tabs`, `sessions`, `agents`는 따로 읽고 새 컨텍스트에서 `hosts`, `panes`를 함께 읽습니다. 호스트 범위의 오류는 해당 호스트의 agents만 비우고 unavailable로 표시하며, 캐시된 에이전트로 대체하거나 정상인 다른 호스트를 버리지 않습니다. 전체 목록 식별자/구조 오류 또는 호스트 수 초과는 전체 수집을 실패시킵니다. 네이티브의 용량 부족 등 접수 오류는 호스트별로 반환되어 정상인 다른 호스트와 로컬 영수증 처리는 계속될 수 있습니다. 호스트별 응답 오류 텍스트는 **512바이트**로 제한합니다.

한도는 **창 스냅샷당 호스트 64개**, **호스트당 에이전트 128개**(창 전체 128개가 아님), 네이티브 **parent 64개**, **Herdr와 Tern 호스트 소스가 공유하는 소스 64개**입니다. 서로 다른 제한이며 기존 소스 외에 호스트 64개를 추가 허용한다는 뜻이 아닙니다. 용량 회수는 대기 작업을 먼저 최종 처리한 뒤 만료된 오프라인 Tern 소스만 대상으로 하며 살아 있는 Tern/Herdr 소스를 축출하거나 소스 ID를 재사용하지 않습니다. 요청은 **직렬화 JSON 256 KiB**(선택적 전송 LF/CRLF 제외), 응답은 **마지막 LF를 포함한 전체 stdout 512 KiB**입니다. 이스케이프 후 한도를 넘는 명령은 제공 전에 거절하며 불확실한 전송으로 처리하지 않습니다.

**답장은 로컬만 허용합니다.** reply-by-pane map에는 사용 가능한 로컬 에이전트만 들어갑니다. 원격 카드는 읽기 전용이며 네이티브 소스는 원격 프롬프트를 `session_read_only`로 거절하고 원격 명령을 제공하지 않습니다. 플러그인은 원격 `agents:get`/`agents:ask`를 호출하거나 터미널/PTy에 입력하지 않습니다. 로컬 전송은 새 host 소속·pane/session 식별자·프로필·소스 incarnation·관찰/네이티브 generation·단계 경계를 재검증한 뒤 의미 기반 `agents:ask`를 호출합니다. 영수증은 새 전체 목록 교환을 즉시 시작할 뿐 결과가 불확실한 ask를 재전송하지 않습니다. `prompt_accepted`는 수락/대기열 접수 가능성을 뜻하며 모델 완료가 아닙니다.

### 현재 프로덕션 코드 Luau 회귀 하네스

[`tests/transition-regressions.luau`](tests/transition-regressions.luau)는 단일 대형 suite를 즉시 컴파일하는 파일이 아닌 **작은 로더**입니다. 같은 디렉터리에 일반 모듈 `transition-fixture.luau`, `transition-cases-core.luau`, `transition-cases-installation.luau`, `transition-cases-hosts.luau`를 함께 두세요. 모듈 읽기/컴파일/등록, fixture 작업, 개별 프로덕션 콜백을 각각 실제 지연 0 후속 실행에 예약하여 VM 콜백 예산을 지킵니다. `window.luau` 원본은 변경 없이 `function(tern)` 안에서 실제 JSON 코덱으로 실행하며, 하네스 분리는 프로덕션 콜백 내부에 yield를 추가하지 않습니다.

**Cold-load 검증은 별도입니다.** 프로덕션 entry는 시계/소스 identity 생성과 실제 설정·프로세스 작업을 비동기 시작까지 미루며 목록·파일을 즉시 읽지 않습니다. Handover는 제한된 비동기 하위 프로세스를 사용하고 패키지 root/파일시스템 의존성을 추가하지 않습니다. 불필요한 entry 작업을 줄이는 것이지 [창 `load` 예산 50 ms](https://docs.stencil.so/tern/concepts/runtime.md#budgets)를 우회하거나 전체 chunk의 load/JIT 비용을 검증한 것이 아닙니다. 실제 지원 Tern의 toolsMac cold load가 이전에 이 예산을 초과했습니다. 최종 패키지의 프로덕션 `window.luau`를 지원되는 새 Tern 창 VM에서 실제 설치/재로드하고, `load`/timer/await 예산 초과로 비활성화되지 않으며 SDK KV 보존·자동 경로 전환·현재 instance binding·네이티브 동일 창 receipt가 이루어짐을 검증해야 합니다. 하네스 예약 분할이나 카탈로그 ACK는 이 검증을 대신할 수 없으며 toolsMac의 실패를 근거 없이 다른 컴퓨터의 원인으로 설명해서도 안 됩니다.

로그인된 실제 Tern 창의 지원되는 Luau 실행 기능([Carly의 Lua 도구](https://docs.stencil.so/tern/reference/api-window.html#carlys-lua-tool))을 사용하세요. checkout 절대 경로와 쓰기 가능한 결과 파일 경로로 바꾸고 결과 파일의 부모 디렉터리는 미리 존재해야 합니다. 같은 VM에서 전역 변수를 유지하며 다음을 **별도 호출**로 실행하세요. 결과 조회를 위해 suite를 다시 로드하지 마세요.

호출 1 — 로더만 읽기:

```lua
desktop_pet_root = "/absolute/path/to/tern-desktop-pet"
desktop_pet_result = "/tmp/desktop-pet-regressions.json"
desktop_pet_suite = assert(loadstring(tern.fs.read(
    desktop_pet_root .. "/tests/transition-regressions.luau")))()
return "suite loaded"
```

호출 2 — 체크포인트를 파일에 기록하며 한 번 시작하기. Carly VM에는 plugin root가 없으므로 **다섯 번째 tests 디렉터리 인자**를 명시합니다.

```lua
local function persist(results)
    tern.fs.write(desktop_pet_result, tern.json.encode(results))
end
return desktop_pet_suite.run(
    tern, tern.fs.read(desktop_pet_root .. "/window.luau"),
    nil, persist, desktop_pet_root .. "/tests")
```

이후 호출 3 — 재시작 없이 결과 조회:

```lua
return tern.json.encode(desktop_pet_suite.get_results())
```

다른 호출/프로세스에서 기록된 JSON을 읽어도 됩니다. `scheduled = true`는 시작 접수일 뿐이며 사례 등록도 비동기입니다. **`done == true`, `fatal_error` 없음, `passed == total`**을 모두 요구하세요. 고정 sleep이나 중간 개수를 완료 조건으로 삼지 말고 `cases`의 실패를 확인하세요. 체크포인트는 다음 작업 콜백 전에 완료 사례와 `active_case`/`stage`/`step`을 기록하므로 강제 콜백 예산 중단 시에도 마지막 위치를 남깁니다.

**현재 통제 경계 결과: 191/191, `done=true`, fatal error 없음**. 격리된 실제 Tern Luau 엔진에서 현재 프로덕션 소스를 실행했으며 자동 경로 복구와 선택적 handover 프로토콜을 포함합니다. 목록·KV·질문·하위 프로세스·ask는 통제된 fixture 경계이며 실제 KV 변경이나 에이전트 ask가 하네스 밖으로 나가지 않습니다. headless 런타임은 정상적으로 account gate off와 `signed_in:false`를 보고했습니다. **인증된 GUI 재연결·패키지 cold-load/reload·네이티브 구버전 정리·모델 답변 전달의 합격 증거가 아닙니다.**

이전 **132/132** 및 과거 **44/44** 관측은 원래 범위의 기록이며 더 새로운 소스나 공개 설치를 검증한 결과로 사용하지 않습니다.

### 과거 네이티브 소스 증거와 당시 일치하는 설치의 차단 사유

다음은 core 이전 Herdr 네이티브 체크아웃의 과거 한정 증거이며 현재 독립 core의 소유권·capability 계약 설명이 아닙니다. 현재 후보/릴리스가 있다는 사실만으로 실제 Tern 창 재연결·SDK ask·모델 전달을 입증하지 않습니다.

이 계획의 네이티브 root에는 v2 관찰이 구현되었지만 여전히 **`HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet`**을 패키징하고 updater **protocol 3 / observation_mode 2**를 보고하며 중립 설치의 `integration_api:1` 계약이 없습니다. 현재 플러그인 설치 정책은 서명된 **`DesktopPet.app/Contents/MacOS/desktop-pet`과 일치하는 중립 도우미**, **integration_api 1 / protocol 4 / observation_mode 2**를 요구합니다. 따라서 계획의 Herdr bundle은 호환 설치 경로가 아니라 **거절되는 대상**입니다. 통과시키려고 capability를 낮추거나 서명/bundle 검사를 우회하거나 실제 설정을 변경하지 마세요. 일치하는 실제 네이티브/플러그인 설치는 여전히 **차단되어 있으며 입증되지 않았습니다**.

별도의 실제 네이티브 도우미 fixture로 독립적인 로컬/A/B 호스트 키와 label, A만의 Offline/복구, 플러그인 관찰 generation이 같은 상태에서 만료 후 새 네이티브 generation, 이름 변경 시 키 유지, 명령 없는 원격 `session_read_only`를 확인했습니다. 로컬 명령 주입/수락 영수증은 `prompt_accepted`에 도달했지만 **실제 SDK ask나 모델 답변은 아닙니다**. 패키징된 네이티브 GUI는 격리 프로필에서 `ui_ready=true`로 실행됐으나 호스트 label/검색/정렬/읽기 전용 composer/4개 언어/레이아웃의 실제 화면 합격 증거는 얻지 못했습니다. 실제 Tern 창에는 로컬 host 0과 로컬 에이전트 5개만 보였고 원격 host CLI 목록은 비어 있었습니다. **실제 원격 SDK 에이전트 지원이나 중립 앱의 일치하는 설치를 통한 전체 연동 검증을 주장하지 않습니다.**

<details>
<summary>과거 0.1.0 안내와 관측 증거 (보존 자료이며 현재 설치 안내가 아님)</summary>

기존 사용자 README 편집을 포함한 아래 기록을 보존합니다. 아래의 “현재”, Herdr 실행 파일/기본 경로, protocol 3, 공개 v0.3.6, 자동 구형 키 채택, 44/44 검증은 모두 이전 구현에 관한 기록이며 플러그인 0.2.0의 호환성/검증 주장이 아닙니다. 현재 소비자 사용에는 위 안내를 따르세요.

[`tern-desktop-pet`](https://github.com/hanbong5938/tern-desktop-pet)은 공개된 별도 Tern 플러그인 소스 저장소입니다. 로컬 Tern 창의 에이전트를 공용 네이티브 Herdr Desktop Pet 앱에 연결합니다. 이 저장소에는 앱이 들어 있지 않으며 앱을 설치하거나 빌드하지 않습니다. 아래의 공개 GitHub URL로 플러그인을 설치하세요. OMP 확장, Herdr 서버, 패치된 호스트, 원격 Tern 에이전트, Tern 터미널/PTy 입력은 사용하지 않습니다. 이 플러그인에는 캐릭터 그림과 스크린샷이 없습니다.

## 준비 및 설치

Apple Silicon macOS 13+에서 별도로 설치한 [Herdr Desktop Pet 네이티브 앱](https://github.com/hanbong5938/herdr-desktop-pet) **0.3.6 이상**이 필요합니다. 기본 공개 설치 경로는 Homebrew의 사전 빌드 네이티브 앱을 설치한 뒤 공개 Tern 플러그인을 설치하는 **두 번의 명시적 설치**입니다. 플러그인은 앱을 몰래 다운로드하거나 앱 설치기를 실행하거나 앱을 빌드하지 않습니다. 이 바이너리 경로에는 네이티브 소스 체크아웃, Rust/Cargo, Bun, Node.js/npm이 필요하지 않습니다. 네이티브 CLI는 `tern-exchange`, `--host tern`과 `update-capabilities`의 `protocol: 3`, `observation_mode: 1`(공개 v0.3.6) 또는 `2`(현재 통합 네이티브 소스)를 지원해야 합니다. 구형 앱에서 `tern-exchange`가 알 수 없는 명령으로 나오면 이 플러그인과 작동하지 않습니다. Capability 2를 위해 새 플러그인 스키마나 API가 필요하지는 않습니다.

[v0.3.6](https://github.com/hanbong5938/herdr-desktop-pet/releases/tag/v0.3.6)은 검증된 공개 arm64 자산·체크섬과 갱신된 안정판 Homebrew 포뮬러를 갖춘 최신 공개 안정판입니다. 일치하는 앱·도우미 쌍은 `protocol: 3`, `observation_mode: 1`을 보고합니다. 과거 v0.3.5와 베타 자산은 변경하지 않습니다. 공개 플러그인 설치와 네이티브 앱 설치는 별개이며 기존 바이너리는 명시적으로 업그레이드해야 합니다.

**공개 소비자 경로 검증:** 실제 안정판 Brew 0.3.5 → 0.3.6 업그레이드가 성공했으며 공개 고정 `--prebuilt` 설치기는 시스템 도구만 있는 `PATH`에서 완료됐습니다(Cargo·Bun·Node.js·npm 없음). 두 설치 앱 모두 별도 비공개 Tern config/state 프로필에서 `app_version: 0.3.6`, `observation_mode: tern`, `ui_ready: true`로 시작했고 설정된 Herdr 소켓의 부모 디렉터리도 필요하지 않았습니다. 유효한 빈 exchange-v1 스냅샷은 `command: null`로 수락됐으며 일반 Stop으로 깨끗하게 종료됐습니다. 실제 공개 플러그인 URL로 격리 Tern 설정에 0.1.0을 설치했고 카탈로그는 문제 없이 준비됐습니다. 이는 해당 소비자 경로의 근거이며 GUI 플러그인 창 연결·에이전트 목록/모델 전달·전체 업데이트 거래·일반 인증의 근거는 아닙니다. 기존 사용자 프로필은 변경하지 않았습니다.

현재 Tern은 로그인이 필요한 비공개 베타입니다. 정당하게 부여받은 베타 접근 권한으로 호환 Tern을 설치·실행하고 정상적으로 로그인해야 하며 인증을 우회하지 마세요. 매니페스트 링크나 로그아웃 상태의 빈 창만으로 기능을 검증할 수는 없습니다. 여기서는 특정 최소 Tern 버전이나 공개 배포를 보장하지 않습니다.

**이전에 수행한 로컬 실제 에이전트 검증:** 로그인된 기존 Tern 0.6.1 창에서 분리된 검증 프로필을 사용해 로컬 에이전트 pane이 창 플러그인과 네이티브 펫에 표시되는 것을 확인했습니다. 임시 탭의 에이전트에게 의미 기반 질문을 보내자 네이티브 상태에 `prompt_accepted`, 전달 상태에 `accepted_may_be_queued`가 나타났습니다. 이후 실제 Tern 에이전트 대화 기록에서 요청한 `TERN_PET_SMOKE_OK` 답변을 확인했고, 에이전트 상태는 일치하는 마지막 메시지를 가진 idle이었습니다. 대화 기록은 이 특정 답변의 전달을 별도로 확인해 주지만, 접수 상태나 idle 상태만으로 완료를 확정할 수는 없습니다. 이 과거 관측은 아래의 현재 수정 회귀 검증과 별개입니다. 공개 릴리스나 최소 버전 보증이 아닌, 공개되지 않은 로컬 소스의 검증입니다.

네이티브 앱을 먼저 설치하고 플러그인을 설치하세요. formula가 이미 설치되어 있다면 첫 명령 대신 `brew update && brew upgrade hanbong5938/tap/herdr-desktop-pet`를 사용합니다. 아래 **공개 v0.3.6 Tern 전용 예시**는 기존 Herdr 펫에 영향을 주지 않도록 선택형 분리 프로필을 사용합니다. 모든 네이티브 명령과 Tern 명령 팔레트 설정에서 config/state 경로를 동일하게 유지하세요. 이 분리 경로는 새 필수 기본값이 아니며 기존 네이티브 프로필·환경설정은 유지됩니다.

```sh
brew install hanbong5938/tap/herdr-desktop-pet
tern plugin install https://github.com/hanbong5938/tern-desktop-pet

PET_BIN="$(command -v herdr-desktop-pet)"
PET_CONFIG="$HOME/.config/tern-desktop-pet/native"
PET_STATE="$HOME/.local/state/tern-desktop-pet/native"

"$PET_BIN" --version
"$PET_BIN" update-capabilities
# 공개 v0.3.6: 버전, protocol: 3, observation_mode: 1을 확인하세요.
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" settings set exit_with_herdr off
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" start
"$PET_BIN" --host tern --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" status

tern plugin reload
tern plugin list
```

앱을 시작하기 **전에** 버전이 **0.3.6 이상**이고 해당 빌드의 capability 필드가 맞는지 확인하세요. 위 명령 실행만으로 확인을 대신할 수는 없습니다. 공개 v0.3.6 앱의 기본 모드는 Herdr이므로 해당 바이너리에는 `--host tern`을 명시적으로 유지하세요. 이 공개 앱에는 아래에서 설명하는 현재 소스의 Auto 드롭다운이나 실시간 호스트 환경설정이 들어 있지 않습니다. 다음으로 로그인된 Tern 창의 명령 팔레트에서 **Configure desktop pet connection** (`configure`)으로 `PET_BIN`과 프로필 두 경로의 확장된 값을 저장한 뒤 **Connect to desktop pet** (`connect`)을 선택하세요. 셸 변수만으로 플러그인이 설정되지는 않습니다.

### 공개 네이티브 태그 빌드

선택형 네이티브 소스 개발에는 Rust/Cargo, Bun, Node.js/npm, Xcode Command Line Tools와 `codesign`이 필요하며 의존성을 내려받을 수 있습니다. **공개 capability-1 앱**을 재현하려면 `PET_SOURCE`를 실제 절대 경로로 지정하고 새 clone에는 미사용 디렉터리를 사용하세요. 아래 공개 v0.3.6 태그를 빌드하며, 이는 통합 capability-2 소스가 아닙니다:

```sh
PET_SOURCE=/absolute/path/to/herdr-desktop-pet-source
git clone https://github.com/hanbong5938/herdr-desktop-pet.git "$PET_SOURCE"
cd "$PET_SOURCE"
git fetch origin tag v0.3.6
git checkout --detach v0.3.6
bash scripts/install.sh --source
PET_BIN="$PET_SOURCE/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet"
"$PET_BIN" --version
"$PET_BIN" update-capabilities
```

기존 네이티브 체크아웃이라면 clone 명령만 건너뛰되, 자신의 변경이 있는 체크아웃을 공개 태그로 전환하지 마세요. 소스 설치기는 앱을 해당 체크아웃의 `dist/HerdrDesktopPet.app`에 패키징하며 플러그인 체크아웃에 복사하지 않습니다. 이 공개 태그 빌드에는 위의 선택형 분리 `PET_CONFIG`/`PET_STATE`, 명시적인 `--host tern` settings/start/status 명령과 공개 플러그인 설치를 사용하되 `PET_BIN`은 이 소스 빌드 경로로 바꾸세요.

### 과거 통합 네이티브 소스 (현재 플러그인 설치 안내 아님)

현재 네이티브 체크아웃의 통합 연결 기능은 **소스 전용**입니다. 일치하는 앱·도우미 쌍은 `protocol: 3`, `observation_mode: 2`를 보고합니다. 공개 v0.3.6을 설치하거나 해당 태그를 빌드해도 이 기능은 제공되지 않습니다. 통합 변경이 들어 있는 기존 네이티브 체크아웃에서 `bash scripts/install.sh --source`로 빌드하고, 구형 `PATH` 바이너리가 아닌 해당 체크아웃의 `dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet`을 사용하세요.

네이티브 **연결(Connection)** 카드에는 **Auto / Herdr / Tern** 드롭다운이 있습니다. **Auto**는 우선 공급자를 정하지 않고 Herdr와 로컬 Tern 연결을 함께 허용합니다. 설치만으로 연결을 확인할 수는 없습니다. 공급자별 **연결됨(Connected) / 대기 중(Waiting) / 비활성화됨(Disabled)** 상태는 실제 연결을 반영합니다. 모드를 선택하면 저장 후 재시작 없이 **같은 실행 중 앱에 즉시 적용**되며, 저장에 실패하면 이전 모드를 유지합니다. 비활성화된 공급자는 브리지로 전송할 수 없습니다. Auto에서 호스트 연결이 끊겨도 펫은 종료되지 않으며 대기 중 답장은 원래 공급자 식별자를 유지하고 다른 곳으로 재전송되지 않습니다.

새 네이티브 프로필의 기본값은 Auto이며, 명시적인 실행 옵션이나 앱이 사용하는 환경 설정이 있으면 그것이 우선합니다. 기존에 저장된 선택은 유지되며 호스트 필드가 없는 레거시 환경설정 파일은 Herdr를 유지합니다. 현재 소스는 `auto`, `herdr`, `tern`을 기록하고, 레거시 `both`는 마이그레이션 입력으로만 받습니다. 드롭다운이나 `preferences set --observation-host auto|herdr|tern`으로 실행 중 프로필을 변경하세요. 읽기/status 명령에는 `--host`를 반복할 필요가 없습니다.

플러그인은 이미 **네이티브와 동일한 기본 프로필 경로**를 사용하므로 이 통합 소스에는 별도 Tern 프로필이 필요하지 않습니다. 수동 명령에서는 주입된 `HERDR_PLUGIN_CONFIG_DIR` / `HERDR_PLUGIN_STATE_DIR`을 해제하거나 맞춘 뒤, 일치하는 실행 파일과 프로필을 사용하세요:

```sh
PET_SOURCE=/absolute/path/to/native-checkout-with-unified-changes
PET_BIN="$PET_SOURCE/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet"
PET_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/desktop-pet"
PET_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/desktop-pet"

"$PET_BIN" update-capabilities
# 이 소스 빌드의 protocol: 3, observation_mode: 2를 확인하세요.
"$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" start
# 기존 Herdr 프로필을 포함해 이 프로필에서 Auto를 명시적으로 선택:
"$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" preferences set --observation-host auto
"$PET_BIN" --config-dir "$PET_CONFIG" --state-dir "$PET_STATE" status
```

대신 **기존 기준 프로필**을 공유하려면 네이티브 연결 카드의 접힌 **연결 설정(Connection settings)**을 열고 실제 실행 파일·config 디렉터리·state 디렉터리를 아래 플러그인의 Configure 질문 세 개에 복사하세요. 서로 다른 프로필의 경로를 섞지 말고 사용할 프로필을 선택하세요. 세 값 전체를 검증·저장한 뒤 Connect를 선택합니다. 이는 플러그인 연결 대상만 바꾸며 네이티브 프로필 파일을 이동·병합·덮어쓰기·삭제하지 않습니다. 기존 분리 프로필과 저장된 플러그인 연결은 직접 다른 대상을 선택하지 않는 한 유지됩니다.

**관찰 범위(Observation scope)**, **연결 설정(Connection settings)**, **진단(Diagnostics)**은 처음에 접혀 있습니다. Tern 전용 모드에서는 Herdr 원격 머신 컨트롤을 숨기되 기존 선택을 지우지 않습니다. **앱 실행(App launch)** 카드의 자동 실행 옵션은 여전히 Herdr 전용이며, Herdr와 함께 종료하는 옵션은 Auto나 Tern이 아닌 Herdr 전용 모드에서만 사용할 수 있습니다. Tern 자동 시작 기능을 의미하지는 않습니다.

### 로컬 플러그인 체크아웃 대안

공개 `tern plugin install` 명령 대신 로컬 플러그인 소스 체크아웃을 연결할 수도 있습니다:

```sh
TERN_PLUGIN=/absolute/path/to/tern-desktop-pet
git clone https://github.com/hanbong5938/tern-desktop-pet.git "$TERN_PLUGIN"
tern plugin link "$TERN_PLUGIN"
tern plugin reload
tern plugin list
```

플러그인 체크아웃이 이미 있다면 해당 clone 명령을 건너뛰세요. 로컬 연결은 개발용 대안이며 별도의 네이티브 앱을 빌드하거나 설치하지 않습니다.

실제 경로로 바꿔 예시를 실행하세요. `PET_*` 셸 변수는 편의를 위한 것이며 Tern의 영구 설정이 아닙니다. capability JSON에서 해당 앱 버전/capability를 확인하고 `status`에서 실행 중인 실행 파일과 실제 `observation_mode`를 확인하세요(공개 예시는 `tern`). 다른 앱이나 구형 데몬이 선택한 프로필을 사용한다면 동일한 config/state 경로로 그 데몬을 먼저 중지한 뒤 의도한 실행 파일을 시작하세요. 이 바이너리 교체는 중지가 필요 없는 capability-2의 실시간 호스트 변경과 별개입니다. 선택형 분리 프로필은 구형 바이너리에 여전히 유용하며 통합 소스와 플러그인은 네이티브 기본 프로필을 공유할 수 있습니다. 네이티브 `--socket`은 **Herdr** 백엔드용이며 Tern 전용 실행에는 필요하지 않습니다. 공개 예시의 명시적인 `--host tern`은 상속된 호스트 모드 환경 설정에 의존하지 않게 하고, `exit_with_herdr off`는 Herdr 없이 독립 실행한 해당 구형 앱을 유지합니다. 셸에 `HERDR_PLUGIN_CONFIG_DIR` 또는 `HERDR_PLUGIN_STATE_DIR`이 설정되어 있다면 수동 명령 실행 시 해제하거나 의도한 프로필과 일치시키세요. 주입된 플러그인 경로가 CLI 경로보다 우선합니다.

`status.herdr_socket`은 Tern 전용 모드에서도 네이티브 앱의 업데이트 컨텍스트에 보존된 Herdr 소켓 설정 경로를 표시합니다. 실제 Herdr 엔드포인트가 살아 있다는 증거가 아닙니다. Tern 전용 실행에는 Herdr 등록도, 해당 경로의 소켓도, 그 부모 디렉터리도 필요하지 않습니다. 이 플러그인이 별도의 네이티브 앱을 도입하는 것은 아닙니다. 공개 v0.3.6의 Tern 업데이트에는 `protocol: 3`, `observation_mode: 1`을 지원하는 일치하는 서명된 앱·도우미 쌍이 필요합니다. 통합 소스의 Auto/실시간 호스트 계약에는 capability 2가 필요하며, 업데이터는 저장된/실제 호스트를 보존하고 호환되지 않는 대상을 거부해야 합니다. 선택한 동작을 잃는 capability-1 앱을 조용히 설치하는 것이 아닙니다.

`tern plugin link`는 이 체크아웃을 제자리에서 참조하며 공개하거나 복사하지 않습니다. `tern plugin reload`는 실행 중인 데몬의 플러그인을 다시 읽고 `tern plugin list`는 로딩 상태/오류를 표시합니다. `window.luau`를 수정했다면 다시 `tern plugin reload`를 실행하세요. 로그인 후 로컬 에이전트 pane이 있는 실제 Tern **창**을 여세요. 창이 없다면 데몬에서 독립적으로 계속 폴링하지 않습니다. 헤드리스 데몬의 플러그인 목록만으로는 플러그인 런타임을 실행·확인한 것이 아닙니다. Tern 명령 팔레트에서 **Connect to desktop pet** (`connect`)을 선택하면 즉시 교환을 요청합니다. 플러그인은 약 1.2초 간격으로도 폴링하고 관련 pane/tab/명령 변경에 반응합니다.

## 창 플러그인 설정

실제 Tern 창에서 사용할 네이티브 기준 프로필을 먼저 선택한 뒤 명령 팔레트의 **Configure desktop pet connection** (`configure`)을 선택하세요. 통합 소스에서는 네이티브 **연결 설정(Connection settings)**에 표시된 실제 값을 복사하고, 공개 분리 프로필 예시에서는 확장된 `PET_*` 값을 사용하세요. 다음 세 질문에 순서대로 답합니다.

1. **Desktop pet executable (path or command):** 실제 실행 파일의 전체 절대 경로를 입력합니다. 예를 들어 `printf '%s\n' "$PET_BIN"`으로 출력한 값이며, 변수명이나 `.app` 디렉터리가 아닙니다. 소스 빌드는 `/absolute/path/to/native-checkout/dist/HerdrDesktopPet.app/Contents/MacOS/herdr-desktop-pet`을 사용합니다.
2. **Absolute desktop pet config directory:** 선택한 기준 프로필의 실제 확장된 config 경로이며, 셸 예시를 사용한다면 `PET_CONFIG`와 일치해야 합니다.
3. **Absolute desktop pet state directory:** 같은 기준 프로필의 실제 확장된 state 경로이며 `PET_STATE`와 일치해야 합니다.

창 플러그인은 단일 정식 `tern.kv` 키 `connection`에 `{ version = 1, executable = "...", config_dir = "...", state_dir = "..." }` 객체를 저장합니다. 후보 전체(버전/필드, 비어 있지 않은 실행 파일, 절대 config/state 경로, NUL 바이트 없음)를 검증한 뒤 **한 번의 KV 쓰기**로 저장하고, 그 후 활성 프로필을 전환하고 소스 인스턴스를 초기화해 즉시 교환합니다. 어느 질문에서든 취소하거나, 질문/검증에 오류가 나거나, 저장이 실패하면 이전 저장 연결과 활성 연결을 유지합니다. 일부만 입력한 프로필은 활성화되지 않습니다.

세 값 전체를 검증하고 성공적으로 저장한 뒤 **Connect to desktop pet** (`connect`)을 선택해 해당 대상과 교환하세요. Configure는 저장된/활성 플러그인 연결만 바꾸며 네이티브 파일에는 손대지 않습니다. 이전 프로필이나 대상 프로필을 복사·이동·병합·삭제하지 않고 기존 별도 Tern 프로필도 계속 사용할 수 있습니다. 결과가 불확실한 ask를 새로 선택한 프로필에 재실행하지 않습니다.

`connection`이 없을 때에만 예전 세 키 `executable`, `config_dir`, `state_dir`를 함께 가져오고 누락된 값은 기본값으로 채웁니다. 이 일회성 마이그레이션은 정식 객체 전체를 검증·저장한 뒤 레거시 키 제거를 시도합니다. 제거 실패는 로그에 남지만 이미 저장한 객체를 되돌리지 않습니다. 기존 `connection`이 잘못된 형식이면 오류이며, 예전 키로 되돌아갈 근거가 **절대 아닙니다**. **Configure desktop pet connection**으로 수정하세요.

설정하지 않았을 때 기본값은 실행 파일 `herdr-desktop-pet`, config `${XDG_CONFIG_HOME}/herdr/plugins/config/desktop-pet` 또는 `~/.config/herdr/plugins/config/desktop-pet`, state `${XDG_STATE_HOME}/herdr/plugins/desktop-pet` 또는 `~/.local/state/herdr/plugins/desktop-pet`입니다. 이는 **네이티브 기본값과 같으며**, 필수 별도 Tern 프로필이 아닙니다. 기존에 저장된 `connection`은 자동으로 다른 대상으로 바꾸지 않고 보존합니다. 다른 기준 프로필이나 선택형 공개 분리 프로필 예시를 사용한다면 세 값을 모두 명시적으로 설정하세요. 구형 `PATH` 바이너리를 피하려면 실행 파일도 절대 경로로 지정하세요. 선택한 프로필에서 Tern을 활성화한 네이티브 펫이 이미 실행 중이어야 합니다(통합 소스에서는 Auto 또는 Tern). 플러그인은 `tern-exchange`를 호출할 뿐 펫을 시작하지 않습니다.

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

## 과거 프로덕션 코드 Luau 회귀 증거

이전 단일 대형 하네스 실행 예시는 더 이상 사용하지 않습니다. 위의 현재 작은 로더/모듈 안내를 따르세요. 아래 **Tern 0.6.1의 44/44** 결과는 이전 awaitable 리비전의 과거 증거로만 보존하며 현재 실행 결과나 현재 하네스 명령이 아닙니다.

각 사례는 실제 Tern 타이머 콜백으로 예약되고 실제 JSON 코덱을 사용했으나, 목록·KV·질문·목록 후속 실행 예약·하위 프로세스 결과·에이전트 ask는 **통제된 SDK 경계**로 대체했습니다. 실제 KV 쓰기·하위 프로세스·질문·`agents:ask`는 하네스 밖으로 나가지 않았습니다. **과거 awaitable 콜백 수정의 검증은 실제 Tern 0.6.1 창 Luau VM에서 44/44 통과**였으며 독립적인 모델이 아니라 당시 프로덕션 소스를 실행했습니다. 기존 35개 사례, 프로필/소스 식별자/pane/로컬 호스트 단계 경계, 최신 로컬 소속과 pane 식별자, 목록 API당 12 ms·콜백 예산 50 ms 사례, awaitable 실패 시 busy 정리 및 재실행 없는 명령 취소를 포함했습니다. 예약 사례는 **타이머 지연 1초와 마이크로태스크 후속 실행당 10 ms**를 모델링하고 통제된 영수증 소비자로 네이티브 **5초 기한** 전에 수락 영수증을 확인했으며 실제 네이티브 하위 프로세스 검증이 아니었습니다. 이전 43/43 타이머 청크 실행도 과거 증거입니다. 통제된 SDK 회귀 검증은 호스트 지연 시간의 보장이나 **전체 실제 에이전트/모델 전달 스모크 테스트가 아닙니다**. 대화 기록 수준의 검증을 대신하거나 위의 이전 실제 에이전트 관측과 혼동하지 마세요.

별도의 이전 창 검증에서는 7초 전후로 소스 관측이 계속 유지되고 의미 기반 `agents:ask`의 영수증이 제때 도착했습니다. 그러나 이후 타이머 청크 실행은 약 16분 뒤 50 ms 콜백 한도에 걸렸으며, 이것이 awaitable 방식으로 전환한 이유입니다. 이전 관측과 비공개 프로필의 시간 측정은 무기한 콜백 예산 준수의 보장이 아닙니다.

실제 설정된 창에서 최종 awaitable 리비전을 실행하자, 이전 소스에 대한 6.25초 유예 뒤 현재 프로필에 새 소스 하나가 관측되었습니다. 이후 실제 네이티브 `sessions.prompt` 작업은 종료 코드 0과 함께 `prompt_accepted`, `committed: false`, `native_applied: false`, 전달 상태 `accepted_may_be_queued`를 반환했습니다. 이어지는 GUI 프로필 전환 전에는 3초 간격 상태 표본 다섯 개 모두 연결된 소스 하나를 표시했습니다. 실제 GUI 설정 흐름에서 **A → B** 전환을 완료한 뒤, 추가 6.25초 유예 후 정식 연결 객체의 config/state 경로는 모두 B였고, 이전 프로필 A는 `connected: false`, 새 프로필 B는 `connected: true`를 보고했습니다. 확인한 로그 구간에는 새 프로덕션 콜백 예산 초과 오류가 없었습니다. 이는 유한한 시점의 관측이며 무기한 50 ms 예산 준수나 호스트 지연 시간의 보장이 아닙니다. 의미 기반 전달 수락과 완료된 설정 전환을 확인한 것이지, 네이티브 업데이터의 전체 GUI Apply 흐름을 검증한 것은 아닙니다.

**과거 특정 응답의 대화 기록 수준 전달 증거:** 소유한 실제 Tern 세션 JSONL에서 이후 assistant 역할 메시지의 정확한 텍스트 `TERN_MICROTASK_SMOKE_OK`를 확인했습니다. 이는 요청한 이 특정 모델 답변이 전달되었음을 별도로 확인합니다. 네이티브 수락 영수증만으로 확인한 것이 아니며, 일반적인 모델 작업 완료나 이후 영수증의 최종 답변 전달을 보장하는 관측도 아닙니다.

</details>

## 라이선스

**이 플러그인 저장소의 코드**는 [LICENSE.txt](LICENSE.txt)의 MIT 라이선스를 따릅니다. 네이티브 앱과 번들 캐릭터 그림은 별도의 앱 체크아웃에 남아 있으며 각자의 고유 고지를 따릅니다. 플러그인의 MIT 라이선스가 Rubelia 또는 다른 그림의 라이선스를 바꾸거나 이를 번들한다는 뜻은 아닙니다. 이곳에는 그림을 복사하지 않았습니다.
