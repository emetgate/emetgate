<p align="center">
  <img src="assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <b>한국어</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>

# Emetgate

**모델이 쓴 것은 검증 없이는 디스크에 닿지 않습니다.**

코딩 모델과 소스 트리 사이에 놓이는 검증 게이트입니다. 모델이 변경을 제안하면 Emetgate가 검사하고, 검사를 통과한 경우에만 기록합니다.

<p align="center">
  <img src="assets/demo.gif" alt="The gate refusing a placeholder and a test-breaking body and committing a correct one; a search against rg; a node edit against Read and Edit" width="900">
</p>

MCP 서버로 실행됩니다. `emetgate lockdown`은 Emetgate의 도구만으로 Claude Code를 시작하므로 모든 쓰기가 게이트를 거칩니다.

## 쓰기는 어떻게 검사되는가

1. **주소 지정.** 변경은 심볼과, 그 변경이 기반으로 삼은 내용의 해시를 지정합니다. 그 뒤로 파일이 바뀌었다면 해시가 일치하지 않아 변경이 거부됩니다. 변경은 본문 안의 구문 노드 하나(예: `if` 블록이나 문장)를 내용 해시로 지정하고 그 노드의 새 텍스트만 보낼 수도 있습니다.
2. **접합과 재파싱.** 새 본문이 바이트 범위에 따라 기존 본문을 정확히 대체합니다. 파일은 tree-sitter로 다시 파싱됩니다. 구문 오류, 중괄호를 벗어나는 본문, 자리 표시자 본문, 범위 밖의 모든 변경은 거부됩니다.
3. **증명이 가능한 곳에서는 증명.** 이름 바꾸기는 이름을 추상화한(알파) 해시와, TypeScript 언어 서비스와 교차 검증하는 스코프 리졸버로 검사합니다. 이동은 옮겨진 코드의 해시를 유지하고 모든 import를 도출합니다. 새로 만들거나 삭제하는 심볼은 참조가 없어야 합니다.
4. **규칙.** CLI에서 추가한 규칙이 여기서 실행됩니다: 내장 검사, tree-sitter 쿼리(`q:`) 또는 직접 쓰는 린터(`cmd:`).
5. **샌드박스에서의 테스트.** 변경은 저장소 밖의 섀도 복사본에 적용됩니다. 타입 검사와 테스트 명령은 그곳에서 낮은 무결성 토큰으로, 시간·메모리·출력 제한이 걸린 Job Object 안에서 실행됩니다.
6. **원자적 커밋.** 배치마다 선행 기록 저널 하나, 원자적 교체, 디렉터리 플러시. 크래시가 난 뒤 `emetgate recover`는 배치를 전부 이전 상태이거나 전부 새 상태로 남깁니다.
7. **영수증.** 모든 커밋은 영수증을 받습니다: 이전과 이후의 해시, 사용된 증거, 실행된 테스트, 적용된 규칙.

검사를 끝낼 수 없으면 변경은 거부됩니다. 모델은 테스트 명령, 규칙, 샌드박스 설정을 바꿀 수 없습니다.

## 도구

| 도구 | 하는 일 |
|---|---|
| `emetgate_explore` | 질문과 선택적인 이름에 대해: 이름이 지정된 각 심볼의 모든 정의, 그다음 이름·경로·본문에 대한 용어 통계로 순위를 매긴 함수와 최상위 상수를 각각 통째로, 줄마다 번호를 붙여 반환합니다. 나머지는 주소로 나열됩니다 |
| `emetgate_evidence` | 최대 6개 이름의 전체 코드. 여러 파일에 정의된 이름은 모든 정의를 반환하고, 심볼이 아닌 이름은 가장 가까운 심볼과 함께 보고됩니다 |
| `emetgate_symbols`, `emetgate_skeleton` | 내용 해시가 붙은 심볼과 시그니처 |
| `emetgate_read_symbol` | 하나 이상의 심볼 본문, 또는 심볼 전체로 넓힌 줄 범위. 읽기 예산(8,192자)을 넘는 본문은 접힌 채로 돌아오며 생략된 줄 범위가 제자리에 표시됩니다. `nodes:true`는 구문 노드가 시작되는 모든 줄에 해시를 붙입니다 |
| `emetgate_read_file` | JSON 키 트리 또는 포인터 하나, Markdown 제목 또는 섹션 하나, 텍스트 줄 범위(`raw:true`를 쓰면 소스 파일도 가능) |
| `emetgate_list`, `emetgate_search` | 저장소 안의 파일 목록과 텍스트 검색 |
| `emetgate_git` | 읽기 전용 `status`, `diff`, `log`, `show` |
| `emetgate_mutate` | 제안된 본문을 기록하지 않고 검사 |
| `emetgate_try`, `emetgate_try_batch` | 심볼, 단일 구문 노드, 파일을 교체·생성·삭제. 변경 하나 또는 원자적 배치 |
| `emetgate_write_doc` | JSON 포인터, Markdown 섹션 또는 텍스트 범위 쓰기. 단독으로 또는 코드와 같은 배치로 |
| `emetgate_rename` | 함수, 클래스, 변수, 타입 또는 enum을 사용되는 모든 곳에서 이름 변경 |
| `emetgate_move` | 선언을 다른 파일로 이동. import는 커널이 도출합니다 |
| `emetgate_move_file` | 파일을 이동하거나 이름을 바꾸고, 그 파일로 들어오고 나가는 모든 import를 다시 씁니다 |
| `emetgate_run` | `--allow-run`으로 허용한 명령을 섀도 복사본에서 실행 |
| `emetgate_scan` | 규칙 하나를 저장소에 대해 측정 |

`--mirror`가 켜져 있으면 한 세션 안에서 읽기는 아무것도 반복하지 않습니다: 바뀌지 않은 심볼은 해시가 붙은 한 줄로 돌아옵니다.

`emetgate lockdown`은 내장 도구 없이, `.mcp.json`의 서버만으로, 도구 검색을 끈 상태로 Claude Code를 시작합니다. 저장소를 바꾸지도 명령을 실행하지도 않는 열한 개의 도구를 `--allowedTools`에 넘기므로 `emetgate_explore`, `emetgate_evidence`, `emetgate_symbols`, `emetgate_skeleton`, `emetgate_read_symbol`, `emetgate_read_file`, `emetgate_list`, `emetgate_search`, `emetgate_scan`, `emetgate_git`, `emetgate_mutate`는 권한 확인 없이 실행됩니다. 쓰기를 하거나 명령을 실행하는 도구는 선택한 권한 모드를 그대로 따르며, lockdown은 그 모드가 `bypassPermissions`일 때만 거부합니다. n8n에서 짧은 읽기 질문은 3턴에서 2턴으로, 웜 상태의 검색 호출은 약 640 ms에서 약 60 ms로 줄었습니다. 각 도구의 이유와 측정은 [REFERENCE.md](REFERENCE.md#lockdown)에 있습니다.

## 규칙

```
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
emetgate rule list
```

`--enforce` 규칙은 자신을 어기는 변경을 테스트가 실행되기 전에 거부합니다. 규칙은 CLI에서만 작성됩니다. 모델은 규칙을 읽을 수 있지만 바꾸거나 제거할 수 없습니다.

## 영수증

```
emetgate receipts attach            # attach pending receipts to your last commit as git notes
emetgate verify HEAD --test "npm test"
```

영수증은 정규 JSON(RFC 8785)으로 된 in-toto 진술문입니다. `emetgate verify`는 커밋을 기록한 프로세스를 신뢰하지 않고 검사합니다: 해시와 알파 해시를 다시 계산하고 샌드박스에서 테스트를 다시 실행합니다. 영수증이 없는 변경이나 게이트 이후에 편집된 파일은 `unverified`로 보고되며, 결코 녹색으로 표시되지 않습니다.

검사기는 쓰기를 하는 코드를 전혀 import하지 않습니다. 검사기가 신뢰하는 것은 24개 파일에 있는 공백이 아닌 Zig 2,731줄(그중 727줄은 `src/verify/`의 3개 파일에 있음)과 tree-sitter, Zig 표준 라이브러리입니다. 영수증 형식만 보고 Python으로 작성한 두 번째 검사기(공백이 아닌 Python 383줄, 저장소에 포함된 BLAKE3의 298줄 별도)가 모든 verify 테스트에서 실행되며 첫 번째 검사기와 결과가 일치해야 합니다.

## 측정 결과

코드베이스에 대한 질문을 Serena, codebase-memory-mcp, Claude Code 자체 도구와 비교했습니다(`python tests/bench/neutral/laws.py`, 2026-10-04, `claude-sonnet-5-5`, 실행마다 저장소의 새 복사본, 추가 프롬프트 없음, 질문당 세 번 실행). 점수는 정답 키 항목 가운데 답변에 나타난 비율이며, 정답 키는 어떤 도구도 실행하기 전에 작성했습니다.

| 저장소 | 도구 | 점수 | 토큰 | API 시간 | 비용 |
|---|---|---:|---:|---:|---:|
| nest, typeorm, actual (질문 10개) | Emetgate | 0.944 | 133k | 30.0 s | $0.147 |
| | Serena | 0.963 | 165k | 36.4 s | $0.158 |
| | Claude Code 자체 도구 | 0.926 | 193k | 35.7 s | $0.168 |
| | codebase-memory-mcp | 0.975 | 199k | 42.0 s | $0.230 |
| OpenBot (질문 5개) | Emetgate | 0.956 | 97k | 22.7 s | $0.108 |
| | Serena | 0.956 | 102k | 24.5 s | $0.114 |
| | Claude Code 자체 도구 | 0.933 | 129k | 24.3 s | $0.114 |
| | codebase-memory-mcp | 0.978 | 137k | 35.1 s | $0.152 |

Emetgate의 점수는 두 세트 모두에서 codebase-memory-mcp보다 낮고, 첫째 세트에서는 Serena보다도 낮습니다. 실험 구성, 기록된 300개 세션, 이 비교의 한계는 [tests/bench/neutral](tests/bench/neutral)에 있습니다.

흔한 읽기 작업의 토큰 수, Claude Code의 `Read`와 비교 (o200k_base, `python tests/bench/reader.py`, 2026-09-26):

| 작업 | Read | Emetgate |
|---|---:|---:|
| 1.6k줄 파일에서 함수 하나를 찾아 읽기 | 13,313 | 2,819 |
| 50 KB `package-lock.json`에서 키 하나 읽기 | 19,859 | 319 |
| README의 섹션 하나 읽기 | 15,432 | 1,541 |
| 같은 세션에서 같은 심볼 다시 읽기 | 13,313 | 84 |
| 3줄짜리 심볼이 바뀐 뒤 다시 읽기 | 18 | 74 |

마지막 행은 더 나쁩니다: 응답에 다음 편집에 필요한 해시가 실려 있기 때문입니다.

편집 전체의 토큰 수, Claude Code의 `Read` 후 `Edit`와 비교 (o200k_base, 양쪽 모두 모델 컨텍스트가 보관하는 `tool_use`와 `tool_result` 블록으로 계산, `python tests/bench/write_flow.py`, 2026-09-27, 같은 1.6k줄 파일):

| 작업 | Read + Edit | Emetgate |
|---|---:|---:|
| 큰 함수에서 한 줄 바꾸기 | 24,646 | 2,145 |
| `if` 블록 교체 | 24,703 | 2,191 |
| 작은 함수를 통째로 교체 | 24,734 | 502 |
| 함수와 그 유일한 호출 지점 삭제 | 24,934 | 810 |
| 한 파일에서 두 군데 편집 | 24,813 | 2,213 |
| 이미 읽은 파일에서 한 줄 바꾸기 | 139 | 191 |

마지막 행은 더 나쁩니다. 파일이 이미 컨텍스트에 있으면 `Edit`는 바뀐 줄을 보내고 한 줄을 돌려받습니다. emetgate가 성공했을 때의 기본 응답은 상태와 새 해시이며(섀도 복사본 안내, 영수증 id, 이전 해시는 `detail:"full"`이 필요), 인자만으로도 최대 1.9x까지만 가능합니다. 또한 Emetgate는 편집마다 테스트를 실행하며, 이것이 편집당 200에서 420 ms의 대부분을 차지합니다. 규칙, 쿼리, 전체 쓰기 측정은 [REFERENCE.md](REFERENCE.md)에 있습니다.

`rg`와 `git grep` 대비 검색 (`python tests/bench/search.py`, ReleaseFast): 새 세션의 첫 검색은 5.5에서 22.7 ms, 이후 검색은 1.9에서 10.1 ms이고, rg는 27.2에서 80.9 ms, git grep은 29.1에서 65.7 ms입니다. 저장소마다 한 번 하는 최초 인덱스 구축에는 91에서 1,335 ms가 걸렸습니다(2026-09-27, 스캔 대역폭 3.13 GB/s). 모든 검색은 먼저 변경 감시 장벽을 기다리므로, 호출 전에 닫히거나 플러시된 쓰기는 결과에 포함됩니다. 새 세션은 저장된 인덱스를 불러오고 스탬프가 바뀐 파일만 다시 읽습니다. 전체 표와 그 장벽이 놓치는 단 하나의 경우(파일을 계속 열어 둔 채 쓰는 프로세스)는 [REFERENCE.md](REFERENCE.md#search)에 있습니다.

| 검색 | rg | git grep | Emetgate, 세션 내 첫 검색 | Emetgate, 이후 |
|---|---:|---:|---:|---:|
| 오류 메시지 문자열 | 28.1 ms | 34.8 ms | 6.2 ms | 3.1 ms |
| 주석에만 있는 용어 | 80.9 ms | 65.7 ms | 22.7 ms | 9.9 ms |
| JSON 키 값 | 27.2 ms | 29.1 ms | 8.1 ms | 4.8 ms |
| 흔한 짧은 단어 | 33.3 ms | 35.9 ms | 11.4 ms | 6.5 ms |
| 정규식 패턴 | 31.3 ms | 47.2 ms | 10.1 ms | 5.9 ms |
| tryRender 사용처 | 36.8 ms | 36.6 ms | 5.9 ms | 1.9 ms |
| logerror 사용처 | 28.4 ms | 37.9 ms | 5.5 ms | 2.1 ms |
| 커밋된 쓰기와 git 커밋 직후의 검색 | 32.0 ms | 29.2 ms | 13.6 ms | 10.1 ms |

Claude Code의 Grep은 호출마다 rg를 시작하므로, rg와 git grep은 도구 호출이 시작하는 프로세스로 시간을 쟀습니다. Emetgate는 실행 중인 서버에 대한 호출 한 번으로 쟀습니다. 세션마다 한 번 서버를 시작하는 시간과 저장소마다 한 번 인덱스를 구축하는 시간은 표에 없으며, 둘 다 REFERENCE.md에 있습니다.

## 게이트 자체는 어떻게 테스트되는가

- **변이 테스트.** 가드를 변이시키고, 각 변이마다 적어도 하나의 테스트가 실패해야 합니다. 엔진에는 현재 변이체 64개가 있습니다: 57개 제거됨, 4개는 동등함이 증명됨, 2개는 심층 방어로 유지하는 중복 가드, 1개 미해결. 기록된 모든 변이체와 그것을 제거하는 테스트: [VERIFICATION.md](VERIFICATION.md).
- **모델 검사.** 커밋 저널은 TLA+로 명세되어 있으며, 복구 중의 크래시와 사라진 디렉터리 항목을 포함해 두 개와 세 개 파일에 대해 TLC로 검사했습니다.
- **크래시 테스트.** 배치를 모든 단계 뒤에서 끊고 복구합니다.
- **레드팀 및 퍼즈 스위트**: MCP 표면, 샌드박스, 저널, 파서를 대상으로 합니다.

영어 README의 생성 블록에 있는 숫자는 소스에서 만들어지고 CI에서 검사됩니다. 이 페이지의 숫자가 그것과 같은지도 CI에서 검사됩니다.

## 설치

각 릴리스는 `emetgate.exe`와 그 SHA-256을 [릴리스 페이지](https://github.com/emetgate/emetgate/releases)에 게시합니다.

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

바이너리는 코드 서명이 되어 있지 않아 첫 실행 때 SmartScreen이 경고합니다. 대신 체크섬을 비교하십시오.

## 빌드

Zig 0.16.0. tree-sitter와 문법은 저장소에 포함되어 있습니다.

```sh
zig build                  # zig-out/bin/emetgate
zig build test             # all tests
tools/accept.ps1 <ref>     # tests three times, then the mutants on lines changed since <ref>
```

## 보안 이력

게이트에 대해 발견된 문제들입니다. 자세한 내용은 [REFERENCE.md](REFERENCE.md#security-history)에 있습니다.

**F1: 쓰기 도구가 서비스 중인 저장소로 한정되지 않았습니다.** v0.1.2에서 수정.

**F2: git worktree 안의 `.git`이 잘못된 이유로 거부되었습니다.** 낮은 심각도, 수정됨.

**F3: 거부된 제안이 테스트가 실행되는 동안 실제 저장소에 쓸 수 있었습니다.** v0.1.2에서 낮은 무결성 토큰으로 수정.

**저장소 원장: 커밋된 원장의 `cmd:` 규칙이 동의 없이 실행되었습니다.** PR #31에서 수정.

**F4: 배치 도중의 크래시가 배치를 절반만 적용된 상태로 남길 수 있었습니다.** TLA+로 발견, 배치 커밋 레코드로 수정.

**F5: 테스트 명령이 junction을 통해 `node_modules`를 볼 수 없었습니다.** 기능 결함, 하드링크 트리로 수정.

**F6: 파일을 교체하는 중의 크래시가 그 경로를 비어 있게 남길 수 있었습니다.** TLA+로 발견, 복사 후 교체 방식으로 수정.

**F7: 정전이 배치를 절반만 적용된 상태로 남길 수 있었습니다.** TLA+로 발견, 네 가지 디렉터리 변경을 플러시하여 수정.

## 한계

- Windows 전용입니다. 샌드박스는 Job Object와 무결성 수준을 사용합니다. TypeScript, JavaScript, Zig만 지원합니다.
- 게이트를 통과했다는 것은 코드가 파싱되고, 범위 안에 머물며, 테스트를 통과한다는 뜻입니다. 코드가 올바르다는 뜻은 아닙니다.
- 테스트 게이트는 여러분의 테스트만큼만 강합니다.
- 샌드박스는 섀도 복사본 밖으로의 쓰기를 막습니다. 읽기나 네트워크 접근은 막지 않습니다. AppContainer 백엔드가 있지만 실제 프로젝트가 아직 그 아래에서 실행되지 않아 사용하지 않습니다.
- 게이트 밖에서 이루어진 변경은 다루지 않습니다. lockdown은 그것을 위한 것입니다.
- Node.js 24.15.0 및 그 이전 버전은 Windows 루프백 연결에서 간헐적으로 크래시가 발생합니다. 24.16.0 이상을 사용하십시오.

## 라이선스

MIT. `vendor/` 아래에 포함된 문법은 각자의 MIT 라이선스를 유지합니다.

<p align="center"><a href="README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <b>한국어</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>
