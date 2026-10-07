<p align="center">
  <img src="../assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
  <a href="https://github.com/emetgate/emetgate/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/emetgate/emetgate/ci.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/emetgate/emetgate/releases/latest"><img src="https://img.shields.io/github/v/release/emetgate/emetgate?style=flat-square" alt="Latest release"></a>
</p>

<p align="center"><a href="../README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <b>简体中文</b> · <a href="README.es.md">Español</a></p>

# Emetgate

位于编码模型与你的源码树之间的一道闸门。模型提出修改，Emetgate 进行检查，只有检查通过，修改才会落盘。

它作为 Claude Code 的 MCP 服务器运行，支持 Windows 上的 TypeScript 和 JavaScript 项目。

<p align="center">
  <img src="../assets/demo.gif" alt="A Claude Code session under emetgate lockdown: a rule is added from the prompt, the gate refuses a change that fails a test and one that breaks the rule, and commits the corrected one" width="900">
</p>

## 它做什么

**检查每一次写入。** 一次修改要指明符号，以及它所基于代码的哈希。Emetgate 把新的函数体放到位，重新解析文件，运行你的规则，然后在沙箱内的仓库副本上运行你的类型检查和测试。任何一步失败，都不会写入任何内容。每次提交都会留下一份收据，`emetgate verify` 之后可以重新检查它，而无需信任当初写入的进程。

**替模型读代码。** `emetgate_explore` 用完整的定义和行号回答关于代码库的问题。`emetgate_evidence` 返回你点名的符号的完整代码。另外还有针对符号、文件、搜索和 git 的工具；列表见 [REFERENCE.md](../REFERENCE.md#mcp-tools)。

**保存你的规则。** 规则只需从命令行添加一次。模型可以读取规则，但不能更改或删除。

```
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
```

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/gate-dark.svg">
    <img src="../assets/gate-light.svg" alt="A proposed change passes your rules, then the typecheck and tests in a sandbox copy. If both hold it is written with a receipt. If either fails nothing is written." width="780">
  </picture>
</p>

## 安装

每个版本都会在[发布页面](https://github.com/emetgate/emetgate/releases)上提供 `emetgate.exe` 及其 SHA-256。

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

该二进制文件没有代码签名，因此首次运行时 SmartScreen 会发出警告。请改为比对校验和。

`emetgate lockdown` 启动的 Claude Code 只带有 Emetgate 的工具，因此每次写入都要经过闸门。

在 lockdown 下，你也可以直接在提示符中输入规则。由 Emetgate 作答，这一行不会到达模型：

```
/rule add "no comments in source" --check no_comment --enforce
/rule list
```

此后每次写入都会在对话记录中标记：闸门放行时为绿色的 **אמת**，拒绝时为红色的 **מת**。

## 测量结果

我就四个仓库提了 15 个问题，分别通过 Emetgate、Serena、codebase-memory-mcp 和 Claude Code 自带工具来回答：同一模型（`claude-sonnet-5-5`），每次运行使用仓库的全新副本，没有额外提示词，每个问题运行三次。得分是答案要点中被回答点名的比例；答案要点是我在任何工具运行之前写好的。

| 工具 | 得分 | Token | 费用 |
|---|---:|---:|---:|
| Emetgate | 240/252 | 86.7k | $0.132 |
| Serena | 242/252 | 143.8k | $0.143 |
| Claude Code 自带工具 | 234/252 | 171.4k | $0.150 |
| codebase-memory-mcp | 246/252 | 178.5k | $0.204 |

在这组测试中，Emetgate 使用的 token 最少，费用也最低。它不是最准确的：有两个工具得分更高。252 分中两分的差距落在多次运行之间的波动范围内，所以这些运行并不能按得分给工具排名。

我还手动向四个工具各输入了另外三个问题，每个问题只运行一次。Emetgate 使用的 token 依然最少，而 Claude Code 自带工具更便宜也更快：

<p align="center">
  <img src="../tests/bench/hand/three-questions.png" alt="Three questions, four tools, one model: tokens, API time and cost of each tool" width="900">
</p>

记录下来的 345 个会话在费用方面说明了什么：

- 一个会话的费用由四个 token 计数决定，而写入缓存的一个 token 的价格是从缓存读取的一个 token 的 20 倍。token 更少并不总是意味着账单更低。
- 多一次模型调用的费用，大约相当于 8,000 个字符的工具输出。
- 模型会写下它自己要求的内容。它在自己的工具调用中点名的要点，有 98.5% 进入了回答；只在工具回复中看到的要点，为 90.5%。

会话、问题、答案要点以及生成这些数字的脚本见 [tests/bench/neutral](../tests/bench/neutral)。手动测试及其完整回答见 [tests/bench/hand](../tests/bench/hand)。单次读取、编辑和搜索的 token 数见 [REFERENCE.md](../REFERENCE.md)。

## 闸门如何被测试

- **变异测试。** 故意破坏每一项防护，并且必须至少有一个测试失败。引擎部分目前有 64 个变异体：57 个被杀死，4 个被证明等价，2 个是作为纵深防御保留的冗余防护，1 个未解决。清单见 [VERIFICATION.md](../VERIFICATION.md)。
- **模型检查。** 提交日志用 TLA+ 描述，并用 TLC 检查，包括恢复过程中的崩溃。
- **崩溃测试。** 批次在每一步之后被截断并恢复。
- **红队和模糊测试套件**，针对 MCP 接口、沙箱、日志和解析器。

针对闸门的发现及其修复列在 [REFERENCE.md](../REFERENCE.md#security-history) 中。

## 局限

- 仅支持 Windows。仅支持 TypeScript、JavaScript 和 Zig。
- 通过闸门意味着代码可以解析、没有越界，并且通过了你的测试。这并不意味着代码是正确的；测试闸门的强度取决于你的测试。
- 沙箱阻止向副本之外写入。它不阻止读取或网络访问。
- 在闸门之外所做的修改不在覆盖范围内。lockdown 正是为此而设。
- Node.js 24.15.0 及更早版本在 Windows 回环连接上会间歇性崩溃；请使用 24.16.0 或更高版本。

## 名字的由来

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/golem-ales-dark.jpg">
  <img src="../assets/golem-ales-light.jpg" alt="A pen drawing from 1899: Rabbi Loew raises his hand and the golem's face forms in smoke, Hebrew letters on its forehead" width="220" align="left">
</picture>

在布拉格魔像的传说中，拉比勒夫在泥人的额头上写下 **אמת**（*emet*，真理），泥人便活了过来。抹去第一个字母，剩下 **מת**（*met*，死亡），魔像随即停下。

Emetgate 用同一个词标记每一次写入：闸门放行时是完整的词，拒绝时第一个字母被抹去。

<sub>Mikoláš Aleš, <i>Rabbi Loew and the Golem</i>, 1899. Public domain.</sub>

<br clear="left">

## 构建

Zig 0.16.0。tree-sitter 和各语法随仓库一起提供。

```sh
zig build                  # zig-out/bin/emetgate
zig build test             # all tests
tools/accept.ps1 <ref>     # tests three times, then the mutants on lines changed since <ref>
```

## 许可证

MIT。`vendor/` 下随仓库附带的语法保留其各自的 MIT 许可证。

<p align="center"><a href="../README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <b>简体中文</b> · <a href="README.es.md">Español</a></p>
