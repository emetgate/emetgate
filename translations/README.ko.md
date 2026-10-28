<p align="center">
  <img src="../assets/aleph.svg" alt="Emetgate" width="190">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20python%20%7C%20c%23%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Python, C#, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
  <a href="https://github.com/emetgate/emetgate/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/emetgate/emetgate/ci.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/emetgate/emetgate/releases/latest"><img src="https://img.shields.io/github/v/release/emetgate/emetgate?style=flat-square" alt="Latest release"></a>
</p>

<p align="center"><a href="../README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <b>한국어</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>

# Emetgate

LLM은 빠르고 유능합니다 — 몇 시간의 작업을 몇 분 만에. 하지만 그것이 당신의 규칙을 따르는지는 그들에게 달려 있습니다: 모델은 "이것을 절대 쓰지 말라"를 읽고도 그냥 쓸 수 있습니다.

흔한 해답은 더 나은 프롬프트, 더 긴 `AGENTS.md` — 모델에게 지키라고 *요청하는* 규칙입니다. Emetgate는 다른 길을 택합니다: 모델과 당신의 소스 트리 사이의 한 계층. 건너뛸 수 있는 지시가 아니라 — 반드시 통과해야 하는 게이트. 모델이 변경을 제안하고, 커널이 그것을 검증하며, 통과하지 못하면 아무것도 디스크에 도달하지 않습니다.

MCP 서버로 실행되며, Windows에서 TypeScript, JavaScript, Python, C#, Zig을 지원합니다. 아래에서는 각 기능을 부분으로 나눕니다 — 각 부분이 무엇이며, 여기서 무엇을 하는지. 코드와 그 아래의 실제 출력 없이는 어떤 주장도 하지 않습니다.

## 게이트

변경은 심볼과, 그 변경이 기반으로 삼은 코드의 해시를 지정합니다. Emetgate는 새 본문을 제자리에 넣고, 파일을 다시 파싱하고, 규칙을 실행한 다음, 샌드박스 안의 저장소 복사본에서 타입 검사와 테스트를 실행합니다. 모든 단계가 통과하면 변경이 기록되고 영수증에 묶입니다; 어느 단계든 실패하면 아무것도 기록되지 않습니다.

```
proposal ─▶ reparse ─▶ rules ─▶ typecheck ─▶ tests ─▶ write + receipt  (אמת)
                  └── any step fails ─▶ nothing is written (מת)
```

| 부분 | 무엇인지 | 여기서 하는 일 |
| --- | --- | --- |
| 섀도 워크스페이스 | 저장소의 격리된 복사본 | 제안된 쓰기가 먼저 여기에 적용되므로 테스트와 타입 검사가 실제 트리를 건드리지 않고 실행됩니다; 실패 시 디스크는 전혀 바뀌지 않았습니다 |
| tree-sitter | 증분 파서 | 변경이 실제로 파싱되고 트리를 깨뜨리지 않았음을 보이기 위해 파일을 다시 파싱합니다 |
| in-toto 영수증 | 공급망 출처(provenance) 형식 | 통과한 각 쓰기를, 무엇으로부터 무엇이 어떤 테스트로 만들어졌는지에 대한 서명된 기록에 묶습니다 — 나중에 검사 가능 |

## 검색

두 개의 엔진: 속도를 위한 리터럴 색인과, 증명을 위한 인증 엔진.

### `emetgate_find` — 리터럴 검색

디스크로 되돌아가지 않는 평문 및 색인 가능한 패턴 검색. 워밍 시 밀리초 미만.

| 부분 | 무엇인지 | 여기서 하는 일 |
| --- | --- | --- |
| 접미사 배열 (SA-IS) | 선형 시간에 구축되는, 텍스트 모든 접미사의 정렬 배열 | 리터럴을 단 한 번의 `O(m·log n)` 이진 검색으로, 모든 일치와 함께 찾습니다 |
| 두 개의 웨이블릿 트리 | 배열 위의 위치→파일 및 반복-체인 맵 | 어느 일치가 어느 파일에 있는지, 파일을 디스크에서 다시 읽지 않고 알려줍니다 |
| mmap된 `.emet` 색인 | 메모리 매핑된 단일 색인 파일 | 검색 중 파일이 다시 열리지 않습니다; 워밍 시 `~0.7–1 ms` |

### `emetgate_search` — 인증 검색

결과와 함께, 아무것도 놓치지 않았다는 증명을 함께 전달하는 검색.

| 부분 | 무엇인지 | 여기서 하는 일 |
| --- | --- | --- |
| 트라이그램 포스팅 | 압축된 역색인 (Elias-Fano / 비트맵) | 저장소 전체를 스캔하지 않고 후보 파일을 빠르게 좁힙니다 |
| RFC 9162 머클 트리 | 읽은 모든 파일의 SHA-256 위의 루트 | 응답이 루트를 전달하므로, 완전하거나 부분적인 답이 주장이 아니라 증명 가능합니다 |
| 실패-시-닫힘(fail-closed) | 숫자가 맞지 않으면 인증서가 `InconsistentCertificate`로 거부됩니다 | 잘못된 "완전"은 결코 표시되지 않습니다; 의심스러우면 침묵합니다 |
| NTFS 변경 장벽 | `ReadDirectoryChangesW`를 통한 파일-변경 알림 | 변경된 파일만 다시 읽힙니다(신선도); 벤치마크에서 누락 없음 |
| ripgrep 위임 | 색인이 제공할 수 없는 정규식 (`\b`, lookaround…) | ripgrep에 넘겨집니다; 응답은 `delegated: rg`라고 말합니다 — 기능 손실 없음 |

응답은 주장이 아니라 증명을 전달합니다 — 실제 출력:

```
$ search "InconsistentCertificate"
✓ 6 matches in 429 files            # complete, with the Merkle root
$ search "Allocator"
partial: matches 1-46 of 1617; next offset:46
$ search "zzzNeverOccurs"
✓ no match in 569 files              # even zero is proven
```

> 워밍 ~1.5–3.5 ms · 콜드(색인 구축) 661 ms · ripgrep과 한 줄 한 줄 동일

## 규칙

한 번 설정한 정책이 모든 쓰기에서 지켜집니다. 모델은 규칙을 읽을 수 있고 바꿀 수 없습니다.

| 부분 | 무엇인지 | 여기서 하는 일 |
| --- | --- | --- |
| tree-sitter 쿼리 | 구문 트리 위의 구조적 일치 | 범위/심볼/주석 검사: `no_comment`, `require_comment`, `max_function_lines`, `forbid_import`… |
| 정규식 엔진(예산제) | 단계 제한이 있는 매처 | `forbid_regex` / `no_todo`: 변경된 범위에서 패턴 또는 마커 탐색 |
| `ledger.ndjson` | 추가 전용 규칙 장부 (`.emetgate/`) | 규칙이 여기에 있습니다; 모델은 읽지만 쓸 수 없습니다 — 정책은 사람의 것으로 남습니다 |
| 커밋-메시지 검사 | 메시지-표면 규칙 | `message:conventional`: conventional commit이 커밋 시점에 지켜집니다 |

```
emetgate rule add "ban lodash"        --check forbid_import:lodash --enforce
emetgate rule add "document exports"  --check require_comment --in src/ --enforce
```

## 검증된 Git

`emetgate verify --branch base..head`는 브랜치의 전체 이력을 다시 재생하고 변조가 드러나는 판정을 반환합니다.

| 부분 | 무엇인지 | 여기서 하는 일 |
| --- | --- | --- |
| blake3 해시 체인 | 각 인증서 = blake3(parent ‖ oid ‖ verdict ‖ receipt) | 커밋 하나를 다시 재생하면 체인 끝이 이동합니다 — 변조가 드러남 |
| CAS 참조 + 비공개 색인 | 작업 트리를 건드리지 않는 write-tree / commit-tree | 게이트를 통과한, 영수증이 붙은 커밋 — 편집기를 방해하지 않고 |
| TLA⁺ 모델 검사 | 커밋 저널의 형식 모델 | 충돌이 반쯤 남긴 커밋이 일관된 상태로 돌아옵니다 — 증명됨 |
| in-toto 영수증 | 커밋에 묶인 출처 (`refs/notes/emetgate`) | 영수증 없음 → `partial`(실패-시-닫힘); 조작된 "verified" 없음 |
| git rev-list 재생 | `base..head` 범위를 순회 | 각각에 대해 단일-커밋 검증을 다시 실행하며 체인을 엮습니다 |

```
$ emetgate verify --branch main..HEAD
branch partial: 48 commit(s)          # no receipt → fail-closed
  a179a7f unverified (no receipt)  cert 84c2…

# tamper with one receipt:
branch broken: 1 commit(s)
  3ff23a0 MISMATCH  cert ec79…         # the chain tip shifted → caught
```

## 어떻게 테스트되는가

| 부분 | 무엇인지 | 여기서 하는 일 |
| --- | --- | --- |
| 뮤테이션 테스트 | 코드를 일부러 망가뜨리고 스위트가 알아채는지 확인 | 테스트가 단지 통과하는 것이 아니라 결함을 *잡아낸다*는 것을 증명합니다 |
| TLA⁺ | 커밋 저널의 모델 검사 | 충돌 복구의 정확성을, 코드와 별개로 논증 |
| 퍼즈 & 레드팀 | 무작위 뮤테이션과 공격 코퍼스 | 예상치 못하거나 적대적인 입력에서 충돌이나 탈출 없음 |
| ripgrep 동등성 게이트 | 매 실행마다 히트 집합을 rg와 비교 | 검색이 "빠르지만 틀릴" 수 없습니다; 한 줄 한 줄 검사 |

엔진의 경우: 69 mutant 오늘: 62 killed, 4 proven equivalent, 2 redundant guards kept as defense in depth, 1 open. 목록은 [VERIFICATION.md](../VERIFICATION.md)에 있습니다.

## 측정값

| 표면 | 측정 | 결과 |
| --- | --- | --- |
| 전체 테스트 스위트 | 통과 / 실패 / 누출 | 1908 / 0 / 0 |
| 검색 동등성 | rg 줄 = emetgate | 1617=1617 · 6=6 · 2=2 |
| 검색 워밍 | 중앙값 | 1.5–3.5 ms |
| find 워밍 | 중앙값 | 0.7–1.0 ms |
| 검증(변조된 영수증) | 판정 | broken (잡힘) |

```
python tests/bench/n8n_search.py   ·   zig build test
```

## 설치

처음이신가요? [docs/QUICKSTART.md](../docs/QUICKSTART.md)를 따르세요: 설치하고, `emetgate doctor`를 실행한 뒤, `emetgate lockdown`을 실행합니다.

[최신 릴리스](https://github.com/emetgate/emetgate/releases/latest)에서 Windows 바이너리를 내려받고 그 폴더를 `PATH`에 넣으세요 (PowerShell; 이후 새 터미널을 여세요):

```
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/emetgate.exe" -OutFile "$env:USERPROFILE\emetgate\emetgate.exe"
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:USERPROFILE\emetgate", "User")
```

그다음 프로젝트 폴더에서:

```
emetgate lockdown --test "npm test"
```

Windows · TypeScript / JavaScript / Python / C# / Zig. `emetgate lockdown`은 에이전트를 emetgate 도구만으로, 실패-시-닫힘으로 시작합니다. `--test`를 빼면 테스트 명령은 쓰기마다 감지됩니다 (`package.json` `scripts.test`, `build.zig`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `.sln` 또는 `.csproj`). 빈 폴더에서는 lockdown이 `git init`을 실행하고, 프로젝트에 테스트 명령이 생길 때까지 쓰기는 `unverified_no_tests`로 기록됩니다.

Lockdown은 프로젝트 자체의 `.mcp.json`만 읽으며, 사용자 범위에 등록된 서버는 절대 읽지 않습니다. emetgate를 다른 도구들 옆에서 서버로 쓰거나 lockdown에 직접 서버 인자를 주려면 프로젝트에 등록하세요:

```
claude mcp add --scope project emetgate -- emetgate mcp --test "npm test"
```

그 `.mcp.json`이 있으면 lockdown은 테스트 명령을 거기서 가져오고, `emetgate lockdown --test`는 거부됩니다.

## 더 깊이

- [REFERENCE.md](../REFERENCE.md) — 모든 도구
- [VERIFICATION.md](../VERIFICATION.md) — 영수증과 증명
- [docs/experiments/tla](../docs/experiments/tla) — TLA⁺ 모델
- [tests/bench](../tests/bench) — 벤치마크

## 한계

Windows 전용; TypeScript, JavaScript, Python, C#, Zig. 샌드박스는 읽기나 네트워크가 아니라 쓰기를 막습니다. 게이트를 통과한다는 것은 변경이 파싱되고 *당신의* 테스트를 통과함을 증명합니다 — 그 테스트만큼만 강합니다. 벤치마크는 우리 자신의 것이며, 한 대의 기계에서, 재현 가능합니다.

## 이름의 유래

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/golem-ales-dark.jpg">
  <img src="../assets/golem-ales-light.jpg" alt="1899년 펜 드로잉: 랍비 뢰브가 손을 들자 골렘의 얼굴이 연기 속에서 형성되고, 이마에 히브리 문자가 있다" width="220" align="left">
</picture>

프라하 전설에서 골렘은 이마의 **אמת**(*emet*, "진실")라는 단어로 생명을 얻습니다. 첫 글자를 지우면 **אמת**는 **מת**(*met*, "죽음")가 됩니다 — 골렘이 멈춥니다. 게이트는 변경이 유지될 때 첫 글자를 쓰고; 실패한 테스트가 그것을 지웁니다.

<br clear="left">

## 라이선스

MIT. [LICENSE](../LICENSE) 참조.
