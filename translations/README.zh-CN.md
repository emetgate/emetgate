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

<p align="center"><a href="../README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <b>简体中文</b> · <a href="README.es.md">Español</a></p>

# Emetgate

大语言模型既快又能干 —— 几小时的活儿几分钟就干完。但它们是否遵守你的规则，取决于它们自己：模型可以读到"绝不要用这个"，然后照用不误。

惯常的答案是更好的提示词、更长的 `AGENTS.md` —— 这些规则只是*请求*模型去遵守。Emetgate 走的是另一条路：在模型与你的源码树之间加一层。不是一条它可以跳过的指令 —— 而是一道它必须通过的闸门。模型提出一次修改；内核对其进行验证；除非通过，否则任何内容都不会落盘。

它作为 MCP 服务器运行，在 Windows 上，面向 TypeScript、JavaScript、Python、C# 和 Zig。下面把每项能力拆成各个部分 —— 每个部分是什么，以及它在这里做什么。没有代码和其下的真实输出，就没有任何主张。

## 闸门

一次修改要指明一个符号，以及它所基于代码的哈希。Emetgate 把新的函数体放到位，重新解析文件，运行你的规则，然后在沙箱内的仓库副本上运行你的类型检查和测试。如果每一步都通过，修改就被写入并绑定到一份收据；如果任何一步失败，就不会写入任何内容。

```
proposal ─▶ reparse ─▶ rules ─▶ typecheck ─▶ tests ─▶ write + receipt  (אמת)
                  └── any step fails ─▶ nothing is written (מת)
```

| 部分 | 它是什么 | 它在这里做什么 |
| --- | --- | --- |
| 影子工作区 | 仓库的一个隔离副本 | 提议的写入先在这里应用，于是测试和类型检查在不触碰真实目录树的情况下运行；失败时磁盘从未改变 |
| tree-sitter | 一个增量解析器 | 重新解析文件，表明修改确实能解析，且没有破坏语法树 |
| in-toto 收据 | 一种供应链溯源格式 | 把每一次通过的写入绑定到一条签名记录：由什么构建出什么、用了哪些测试 —— 之后可核验 |

## 搜索

两个引擎：求速度的字面量索引，和求证明的认证引擎。

### `emetgate_find` —— 字面量搜索

无需回到磁盘的纯文本与可索引模式搜索。热态时亚毫秒。

| 部分 | 它是什么 | 它在这里做什么 |
| --- | --- | --- |
| 后缀数组 (SA-IS) | 以线性时间构建的、文本所有后缀的有序数组 | 用一次 `O(m·log n)` 二分查找一次性找到某个字面量及其全部匹配 |
| 两棵小波树 (wavelet tree) | 数组之上的 位置→文件 与 重复链 映射 | 告诉你哪个匹配在哪个文件里，而无需从磁盘重新读取文件 |
| mmap 的 `.emet` 索引 | 一个内存映射的索引文件 | 搜索期间文件不会被重新打开；热态 `~0.7–1 ms` |

### `emetgate_search` —— 认证搜索

随结果一并给出“没有遗漏任何内容”之证明的搜索。

| 部分 | 它是什么 | 它在这里做什么 |
| --- | --- | --- |
| 三元组倒排 (trigram postings) | 一个压缩的倒排索引 (Elias-Fano / 位图) | 不扫描整个仓库就快速收窄候选文件 |
| RFC 9162 默克尔树 | 对读取的每个文件的 SHA-256 取根 | 回复携带该根，于是完整或部分的答案是可证明的，而非断言 |
| 失败即关闭 (fail-closed) | 若数字对不上，证书以 `InconsistentCertificate` 被拒 | 错误的“完整”绝不会被展示；存疑时保持沉默 |
| NTFS 变更屏障 | 经由 `ReadDirectoryChangesW` 的文件变更通知 | 只有变更过的文件才被重新读取（新鲜度）；基准测试中零遗漏 |
| 委托给 ripgrep | 索引无法服务的正则 (`\b`、lookaround…) | 交给 ripgrep；回复写明 `delegated: rg` —— 能力无损失 |

回复携带的是证明，而非主张 —— 真实输出：

```
$ search "InconsistentCertificate"
✓ 6 matches in 429 files            # complete, with the Merkle root
$ search "Allocator"
partial: matches 1-46 of 1617; next offset:46
$ search "zzzNeverOccurs"
✓ no match in 569 files              # even zero is proven
```

> 热态 ~1.5–3.5 ms · 冷态（构建索引）661 ms · 与 ripgrep 逐行一致

## 规则

你设定一次的策略，在每一次写入时都被坚持。模型读取规则，且无法更改它们。

| 部分 | 它是什么 | 它在这里做什么 |
| --- | --- | --- |
| tree-sitter 查询 | 语法树之上的结构化匹配 | 跨度/符号/注释检查：`no_comment`、`require_comment`、`max_function_lines`、`forbid_import`… |
| 正则引擎（带预算） | 一个带步数上限的匹配器 | `forbid_regex` / `no_todo`：在变更跨度内查找某个模式或标记 |
| `ledger.ndjson` | 一本只追加的规则簿 (`.emetgate/`) | 规则住在这里；模型能读却不能写 —— 策略归人所有 |
| 提交消息检查 | 一条消息面规则 | `message:conventional`：在提交时坚持 conventional commits |

```
emetgate rule add "ban lodash"        --check forbid_import:lodash --enforce
emetgate rule add "document exports"  --check require_comment --in src/ --enforce
```

## 已验证的 Git

`emetgate verify --branch base..head` 重放一个分支的全部历史，并返回一个可察觉篡改的裁决。

| 部分 | 它是什么 | 它在这里做什么 |
| --- | --- | --- |
| blake3 哈希链 | 每份证书 = blake3(parent ‖ oid ‖ verdict ‖ receipt) | 重放一个提交，链尖就会移动 —— 篡改可察觉 |
| CAS 引用 + 私有索引 | 不触碰工作目录树的 write-tree / commit-tree | 一次经过闸门、带收据的提交 —— 而不打扰你的编辑器 |
| TLA⁺ 模型检查 | 提交日志的一个形式模型 | 崩溃留下的半成品提交会回到一致状态 —— 已证明 |
| in-toto 收据 | 绑定到提交的溯源 (`refs/notes/emetgate`) | 没有收据 → `partial`（失败即关闭）；没有伪造的“verified” |
| git rev-list 重放 | 遍历 `base..head` 区间 | 对每个提交重跑单提交验证，织成那条链 |

```
$ emetgate verify --branch main..HEAD
branch partial: 48 commit(s)          # no receipt → fail-closed
  a179a7f unverified (no receipt)  cert 84c2…

# tamper with one receipt:
branch broken: 1 commit(s)
  3ff23a0 MISMATCH  cert ec79…         # the chain tip shifted → caught
```

## 如何测试

| 部分 | 它是什么 | 它在这里做什么 |
| --- | --- | --- |
| 变异测试 | 故意弄坏代码，看测试套件是否察觉 | 证明测试*抓得住*一个缺陷，而不只是能通过 |
| TLA⁺ | 对提交日志的一次模型检查 | 崩溃恢复的正确性，与代码分开论证 |
| 模糊测试与红队 | 随机变异加攻击语料 | 对意外或敌意输入不崩溃、不逃逸 |
| ripgrep 一致性闸门 | 每次运行都把命中集与 rg 比对 | 搜索不能“快却是错的”；逐行核对 |

就引擎而言：目前 69 个变异体：58 个被杀死，6 个被证明等价，4 个作为纵深防御保留的冗余守卫，1 个未解决。列表在 [VERIFICATION.md](../VERIFICATION.md) 中。

## 已测量

| 面 | 度量 | 结果 |
| --- | --- | --- |
| 完整测试套件 | 通过 / 失败 / 泄漏 | 2386 / 0 / 0 |
| 搜索一致性 | rg 行数 = emetgate | 1617=1617 · 6=6 · 2=2 |
| 搜索热态 | 中位数 | 1.5–3.5 ms |
| find 热态 | 中位数 | 0.7–1.0 ms |
| 验证（被篡改的收据） | 裁决 | broken（已抓住） |

```
python tests/bench/n8n_search.py   ·   zig build test
```

## 安装

第一次使用？按 [docs/QUICKSTART.md](../docs/QUICKSTART.md) 操作：安装，运行 `emetgate doctor`，然后运行 `emetgate lockdown`。

从[最新发布](https://github.com/emetgate/emetgate/releases/latest)下载 Windows 二进制文件，并把它所在的文件夹加入 `PATH`（PowerShell；之后打开一个新终端）：

```
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/emetgate.exe" -OutFile "$env:USERPROFILE\emetgate\emetgate.exe"
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:USERPROFILE\emetgate", "User")
```

然后，在项目文件夹中：

```
emetgate lockdown --test "npm test"
```

Windows · TypeScript / JavaScript / Python / C# / Zig。`emetgate lockdown` 让智能体仅带 emetgate 工具启动，失败即关闭。省略 `--test` 时，每次写入都会检测测试命令（`package.json` `scripts.test`、`build.zig`、`Cargo.toml`、`go.mod`、`pyproject.toml`、`.sln` 或 `.csproj`）。在空文件夹中 lockdown 会运行 `git init`，在项目有测试命令之前，写入记为 `unverified_no_tests`。

Lockdown 只读取项目自己的 `.mcp.json`，从不读取在用户范围注册的服务器。若要把 emetgate 作为服务器与其他工具并用，或给 lockdown 传入你自己的服务器参数，请为项目注册它：

```
claude mcp add --scope project emetgate -- emetgate mcp --test "npm test"
```

有了这个 `.mcp.json`，lockdown 会从中读取测试命令，而 `emetgate lockdown --test` 会被拒绝。

## 深入了解

- [REFERENCE.md](../REFERENCE.md) —— 每一个工具
- [VERIFICATION.md](../VERIFICATION.md) —— 收据与证明
- [docs/experiments/tla](../docs/experiments/tla) —— TLA⁺ 模型
- [tests/bench](../tests/bench) —— 基准测试

## 局限

仅 Windows；TypeScript、JavaScript、Python、C# 和 Zig。沙箱阻挡写入，而非读取或网络。通过闸门，证明的是一次修改能解析并通过*你的*测试 —— 它只和那些测试一样强。基准测试是我们自己的，出自一台机器，且可复现。

## 名字的由来

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/golem-ales-dark.jpg">
  <img src="../assets/golem-ales-light.jpg" alt="一幅 1899 年的钢笔画：拉比勒夫举起手，傀儡的脸在烟雾中成形，额上有希伯来字母" width="220" align="left">
</picture>

在布拉格传说中，傀儡（golem）因额上的 **אמת**（*emet*，“真理”）一词而获得生命。抹去第一个字母，**אמת** 便成了 **מת**（*met*，“死亡”）—— 傀儡静止下来。当一次修改成立时，闸门写下第一个字母；一次失败的测试则抹去它。

<br clear="left">

## 许可证

MIT。见 [LICENSE](../LICENSE)。
