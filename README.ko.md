# codex-image-relay

[English](README.md)

**OpenAI Codex 데스크톱 앱에 내장된 GPT 이미지 생성 도구**를 다른 AI 코딩 에이전트도 쓸 수 있게 해주는 도구입니다. ChatGPT 로그인으로 동작하며 OpenAI API 키가 필요 없습니다.

Claude Code처럼 셸 명령을 실행할 수 있는 에이전트라면 PowerShell 스크립트 하나만 호출하면 됩니다. Codex는 이미지 생성 기능만 켠 최소 구성으로 실행되고, 지정한 경로에 PNG 이미지와 실행 기록(JSON)이 저장됩니다.

![예시: 이 도구로 생성한 웹툰 컷](examples/webtoon-panel.jpg)

*[`examples/webtoon-panel.prompt.txt`](examples/webtoon-panel.prompt.txt)로 `Final` 모드에서 생성, 48초.*

---

## AI 에이전트를 위한 안내

사용자가 이 저장소 주소를 줬다면 다음 순서로 진행하세요.

1. **실행 환경을 확인합니다.** **Windows**에 **Codex 데스크톱 앱**이 설치되어 있고 로그인된 상태여야만 동작합니다. 둘 중 하나라도 없으면 진행하지 말고 사용자에게 알리세요. 설치나 로그인을 대신하지 마세요.
2. **스킬로 설치합니다.** 스킬 폴더에 저장소를 그대로 받으면 됩니다. Claude Code는 다음과 같습니다.
   ```bash
   git clone https://github.com/Saeyeon-developer/codex-image-relay ~/.claude/skills/codex-image-relay
   ```
   `~/.agents/skills` 폴더를 읽는 에이전트라면 그 폴더에 받으세요. 설치하지 않고 받은 폴더에서 스크립트를 바로 실행해도 됩니다.
3. **[`SKILL.md`](SKILL.md)를 읽습니다.** 호출 방법, 모드 선택, 출력 형식, 종료 코드, 제약이 모두 정리된 사용 설명서입니다.
4. **테스트 이미지는 사용자가 이미지를 요청했을 때만 만듭니다.** 이미지 한 장마다 사용자의 ChatGPT 요금제 사용량이 소모됩니다.

---

## 요구 사항

- Windows 10/11, Windows PowerShell 5.1 (기본 내장)
- [Codex 데스크톱 앱](https://openai.com/codex), ChatGPT 계정으로 로그인된 상태
  - 앱과 함께 설치된 `codex.exe`(`%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\`)를 사용합니다. 따로 설치해서 PATH에 등록한 `codex` CLI는 사용하지 않습니다.
- 이미지를 생성할 때마다 ChatGPT/Codex 요금제 사용량이 소모됩니다.

## 사용법

```powershell
.\imagen.ps1 -PromptFile prompt.txt -Output out\panel.png -PromptMode Final -Orientation portrait
.\imagen.ps1 -Prompt "크림색 배경의 빨간 여우 로고" -Output out\fox.png -Orientation landscape
.\imagen.ps1 -PromptFile prompt.txt -Reference char.png,style.png -Output out\scene.png -PromptMode Final
```

bash에서 실행할 때(예: Claude Code의 Bash 도구):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File ./imagen.ps1 -PromptFile prompt.txt -Output out/panel.png -PromptMode Final
```

| 옵션 | 설명 |
|---|---|
| `-PromptFile` / `-Prompt` | 프롬프트. 길거나 한글이 들어간 프롬프트는 UTF-8 텍스트 파일로 넘기는 것을 권장합니다. |
| `-Output` | 저장할 PNG 경로 (필수) |
| `-PromptMode` | `Final`: 프롬프트가 완성되어 있음. 고치지 않고 그대로 이미지 도구에 넘깁니다. `Draft`(기본값): Codex가 요청을 바탕으로 프롬프트를 먼저 작성합니다. |
| `-Orientation` | `auto`(기본값), `portrait`, `landscape`, `square`. 대략적인 방향 힌트입니다. 특정 비율이 필요하면 프롬프트에 적으세요(주의 사항 참고). |
| `-Reference` | 레퍼런스 이미지. 지정한 순서대로 이미지 1, 이미지 2가 됩니다. 프롬프트에 각 이미지의 역할을 적어주세요. |
| `-Model`, `-Effort` | 모드별로 정해진 Codex **에이전트** 모델 대신 다른 모델을 씁니다. 이미지 모델은 바꿀 수 없습니다. |
| `-TimeoutSec` | Codex 실행 1회당 제한 시간(초). 기본 600 |
| `-Retries` | 일시적인 Codex 오류(모델 용량 초과/서버 과부하, 요청 한도, 5xx)일 때 `codex exec`를 새로 실행해 다시 시도하는 횟수. 기본 2. 다른 오류는 다시 시도하지 않습니다. |
| `-RetryDelaySec` | 첫 재시도 전 대기 시간(초). 재시도할 때마다 두 배가 됩니다. 기본 20 |
| `-CodexExe` | 테스트 전용: 내장 `codex.exe` 대신 이 실행 파일(예: 정해진 JSONL을 출력하는 가짜 실행 파일)을 씁니다. |

### 프롬프트 모드

| 모드 | 이럴 때 | Codex 에이전트 모델 |
|---|---|---|
| `Final` | 사용자나 에이전트가 프롬프트를 이미 완성함 | `gpt-6-luna` / low |
| `Draft` | 대략적인 아이디어만 있음 | `gpt-6.1-sol` / high |

에이전트 모델은 이미지 도구를 호출하는 일(`Draft`에서는 프롬프트 작성까지)만 맡습니다. 이미지 품질에는 영향이 없습니다. 더 빠르고 사용량도 적은 `Final`을 권장합니다.

### 출력

- `out\panel.png`: 이미지
- `out\panel.json`: 원래 프롬프트, 실제로 쓰인 프롬프트(`prompt_used`, Draft 모드에서는 Codex가 작성한 것), 레퍼런스, 모델, Codex 실행 ID(`thread_id`), 토큰 사용량, 소요 시간
- 성공하면 마지막 줄에 `OK <경로> (<가로>x<세로>, <바이트> bytes, <초>s, <모델>/<강도>)`를 출력하고 종료 코드 0으로 끝납니다. 실패하면 표준 출력에 `FAIL <이유>` 한 줄(Codex 오류 메시지가 있으면 그 메시지)을 출력하고, 자세한 내용은 표준 오류로 보낸 뒤 종료 코드 1로 끝납니다. Windows PowerShell은 표준 오류를 콘솔 코드 페이지로 쓰므로, 호출하는 쪽은 표준 오류 대신 `FAIL` 줄을 읽으세요. 자동 재시도할 때마다 `retry <n>/<최대> after <초>s: <이유>`를 출력합니다.
- 여러 개를 동시에 실행해도 안전합니다. 각 실행은 자기 실행 폴더(`~/.codex/generated_images/<thread_id>/`)에서만 이미지를 가져옵니다.

## 최소 구성 모드: 사용량이 적은 이유

`codex exec`를 기본 설정으로 실행하면, 모델을 호출할 때마다 코딩 에이전트용 기본 내용이 전부 함께 들어갑니다. 기본 지시문, 권한과 환경 안내, 설치된 모든 스킬·플러그인 목록, 셸·브라우저·컴퓨터 제어 같은 도구 설명이 해당됩니다. 이 스크립트는 이것들을 **자기 실행에서만** 끕니다. `~/.codex/config.toml`은 수정하지 않습니다.

- `--ignore-user-config`, `--ignore-rules`: 사용자 설정 파일(config.toml), MCP 서버, 규칙 파일을 읽지 않습니다.
- `model_instructions_file` → [`codex-instructions.md`](codex-instructions.md): Codex 기본 지시문(약 18k자)을 세 줄짜리 중계 지시로 바꿉니다.
- `include_*_instructions=false`: 권한, 앱, 환경, 협업 모드, 스킬, 플러그인 안내를 뺍니다.
- 스킬: 기본 내장 스킬을 끄고, `~/.codex/skills`와 `~/.agents/skills`에 설치된 스킬도 이번 실행에서만 끕니다.
- `--disable …`: 브라우저, 컴퓨터 제어, 앱, 플러그인, 멀티에이전트, 셸, 파일 수정, `view_image`, 웹 검색 등을 끕니다.

같은 `Final` 프롬프트로 이미지를 한 장씩 생성해서 측정했습니다.

| | 모델 호출 | 입력 토큰 합계 |
|---|---|---|
| Codex 기본 설정 | 3회 | 58,615 |
| 최소 구성 (이 스크립트) | 2회 | **9,179** (−84%) |

남는 것은 Codex가 항상 넣는 멀티에이전트 안내(약 2.7k자)와 도구 정의입니다. 이것까지 끄는 옵션은 찾지 못했습니다.

## 주의 사항

- **현재는 Windows 전용입니다.** Windows에서 Codex 데스크톱 앱이 설치되는 위치를 기준으로 동작합니다.
- **이미지 모델과 품질은 고를 수 없습니다.** Codex 내장 도구가 이 설정을 제공하지 않습니다.
- **비율은 옵션이 아니라 프롬프트로 정합니다.** 프롬프트에 "이미지 전체의 가로:세로 비율은 정확히 4:5"처럼 적고 `-Orientation`은 `auto`로 두세요. 픽셀 수는 약 157만 화소로 일정하고, 비율에 따라 크기가 정해집니다.

  | 요청 | 결과 |
  |---|---|
  | 4:5 | 1122×1402 |
  | 2:1 | 1774×887 |
  | 2.4:1 | 1942×809 |
  | `-Orientation portrait` | 1024×1536 |

  정확한 픽셀 크기가 필요하면 비율을 맞춰 요청한 뒤 리사이즈하세요.
- **기본 에이전트 모델이 내 요금제에 없을 수 있습니다.** `gpt-6-luna`나 `gpt-6.1-sol`을 쓸 수 없다면, 앱에 포함된 `codex.exe`로 `debug models`를 실행해 쓸 수 있는 모델을 확인하고 `-Model`로 지정하세요.
- **Codex가 업데이트되면 최소 구성 모드가 멈출 수 있습니다.** 이 스크립트는 Codex 기능을 이름으로 끕니다. 업데이트로 이름이 바뀌거나 기능이 없어지면 Codex가 `Unknown feature flag: <이름>` 오류를 내고 스크립트도 종료 코드 1로 실패합니다. 몰래 무거운 기본 설정으로 돌아가지는 않습니다. `codex.exe features list`로 현재 이름을 확인한 뒤 `imagen.ps1`의 `--disable` 목록을 고치세요.
- **Codex 기록에 남습니다.** 실행마다 일반 Codex 세션으로 저장되어 Codex 기록에 보일 수 있습니다.
- **비공식 도구입니다.** 공개된 CLI 옵션으로 Codex를 실행하는 방식이라, Codex 내부 동작이 바뀌면 영향을 받을 수 있습니다.

## 문제 해결

| 메시지 | 해결 |
|---|---|
| `codex.exe not found` | Codex 데스크톱 앱을 설치하고 한 번 실행하세요. |
| `Codex is not logged in` | Codex 앱을 열고 로그인하세요. |
| `Unknown feature flag: …` | Codex 업데이트로 기능 이름이 바뀌었습니다. 주의 사항을 참고하세요. |
| `No image produced` | 요청이 거부됐거나 생성에 실패했습니다. 함께 출력된 로그에 Codex가 밝힌 이유가 있습니다. 프롬프트를 고쳐서 다시 시도하세요. |
| `Selected model is at capacity` | OpenAI 서버가 붐비는 상태입니다. 스크립트가 이미 다시 시도했습니다. 몇 분 뒤 다시 실행하거나 `-Retries` / `-RetryDelaySec`를 늘리세요. |
| `gpt-6-luna` / `gpt-6.1-sol` 관련 모델 오류 | 내 요금제에서 쓸 수 있는 모델을 `-Model <이름>`으로 지정하세요. |

## 라이선스

[Apache License 2.0](LICENSE)
