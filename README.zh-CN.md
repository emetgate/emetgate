<p align="center">
  <img src="assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <b>简体中文</b> · <a href="README.es.md">Español</a></p>

# Emetgate

**模型写出的任何内容，未经验证都不会落盘。**

位于编码模型与你的源码树之间的一道验证闸门。模型提出修改；Emetgate 进行检查，只有检查通过才会写入。

<p align="center">
  <img src="assets/demo.gif" alt="The gate refusing a placeholder and a test-breaking body and committing a correct one; a search against rg; a node edit against Read and Edit" width="900">
</p>

它以 MCP 服务器的形式运行。`emetgate lockdown` 启动的 Claude Code 只带有 Emetgate 的工具，因此每次写入都要经过闸门。

## 一次写入如何被检查

1. **寻址。** 一次修改要指明符号，以及它所基于内容的哈希。如果文件在此之后发生了变化，哈希不匹配，修改被拒绝。修改也可以用内容哈希指明函数体内的单个语法节点，例如一个 `if` 块或一条语句，并且只发送该节点的新文本。
2. **拼接并重新解析。** 新的函数体按字节范围精确替换旧的函数体。文件用 tree-sitter 重新解析。语法错误、越出花括号的函数体、占位函数体以及范围之外的任何改动都会被拒绝。
3. **在可以证明之处给出证明。** 重命名通过抽象掉名称的（alpha）哈希和作用域解析器来检查，并与 TypeScript 语言服务交叉核对。移动操作保持被移动代码的哈希不变，并推导出每一条 import。新增和删除的符号必须没有任何引用。
4. **规则。** 你通过 CLI 添加的规则在这里运行：内置检查、tree-sitter 查询（`q:`）或你自己的 linter（`cmd:`）。
5. **在沙箱中运行测试。** 修改被应用到仓库之外的影子副本上。你的类型检查和测试命令在那里运行，使用低完整性令牌，并处于带有时间、内存和输出限制的 Job Object 中。
6. **原子提交。** 每个批次一份预写日志、原子替换、目录刷盘。崩溃之后，`emetgate recover` 使一个批次要么全部为旧内容，要么全部为新内容。
7. **收据。** 每次提交都有一份收据：前后的哈希、所用的证据、运行的测试、应用的规则。

如果某项检查无法完成，修改会被拒绝。模型无法更改测试命令、规则或沙箱设置。

## 工具

| 工具 | 作用 |
|---|---|
| `emetgate_explore` | 针对一个问题和可选的名称：每个被点名符号的全部定义，然后是按名称、路径和函数体上的词项统计排序的函数和顶层常量，每一个都完整给出，且每行带有行号；其余的按地址列出 |
| `emetgate_evidence` | 最多 6 个名称的完整代码；在多个文件中定义的名称会返回全部定义，不是符号的名称会连同最接近的符号一起报告 |
| `emetgate_symbols`、`emetgate_skeleton` | 带内容哈希的符号和签名 |
| `emetgate_read_symbol` | 一个或多个符号的函数体，或扩展到完整符号的行范围；超过读取预算（8,192 个字符）的函数体以折叠形式返回，每个被省略的行范围都在原处标明；`nodes:true` 会为每个语法节点的起始行加上哈希 |
| `emetgate_read_file` | JSON 键树或单个指针、Markdown 标题或单个章节、文本行范围（配合 `raw:true` 也可用于源文件） |
| `emetgate_list`、`emetgate_search` | 仓库内的文件列表和文本搜索 |
| `emetgate_git` | 只读的 `status`、`diff`、`log`、`show` |
| `emetgate_mutate` | 检查提议的函数体而不写入 |
| `emetgate_try`、`emetgate_try_batch` | 替换、创建或删除符号、单个语法节点和文件，可以是单次修改，也可以是原子批次 |
| `emetgate_write_doc` | 写入 JSON 指针、Markdown 章节或文本范围，可单独进行，也可与代码放在同一批次 |
| `emetgate_rename` | 在所有使用之处重命名函数、类、变量、类型或枚举 |
| `emetgate_move` | 把一个声明移动到另一个文件；import 由内核推导 |
| `emetgate_move_file` | 移动或重命名文件，并重写所有指向它和来自它的 import |
| `emetgate_run` | 在影子副本中运行你用 `--allow-run` 允许的命令 |
| `emetgate_scan` | 针对仓库度量一条规则 |

开启 `--mirror` 时，同一会话内的读取不会重复任何内容：未变化的符号只返回带哈希的一行。

`emetgate lockdown` 启动的 Claude Code 不带任何内置工具，只有 `.mcp.json` 中的服务器，并关闭工具搜索。它把既不修改仓库也不运行命令的十一个工具传给 `--allowedTools`，因此 `emetgate_explore`、`emetgate_evidence`、`emetgate_symbols`、`emetgate_skeleton`、`emetgate_read_symbol`、`emetgate_read_file`、`emetgate_list`、`emetgate_search`、`emetgate_scan`、`emetgate_git` 和 `emetgate_mutate` 无需权限检查即可运行；会写入或运行命令的工具保持你选择的权限模式，只有当该模式为 `bypassPermissions` 时 lockdown 才会拒绝。在 n8n 上，一个简短的读取问题从 3 轮降到 2 轮，一次热搜索调用从约 640 ms 降到约 60 ms。每个工具的理由和测量结果见 [REFERENCE.md](REFERENCE.md#lockdown)。

## 规则

```
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
emetgate rule list
```

带 `--enforce` 的规则会在测试运行之前拒绝违反它的修改。规则只能通过 CLI 写入。模型可以读取规则，但不能更改或删除。

## 收据

```
emetgate receipts attach            # attach pending receipts to your last commit as git notes
emetgate verify HEAD --test "npm test"
```

收据是一份采用规范化 JSON（RFC 8785）的 in-toto 声明。`emetgate verify` 在不信任写入进程的前提下检查一次提交：它重新计算哈希和 alpha 哈希，并在沙箱中重新运行测试。没有收据的修改，或在闸门之后被编辑过的文件，会被报告为 `unverified`，绝不会显示为绿色。

检查器不导入任何会写入的代码。它信任的是 24 个文件中的 2,731 行非空 Zig 代码，其中 727 行位于 `src/verify/` 的 3 个文件中，另外还有 tree-sitter 和 Zig 标准库。另有一个仅根据收据格式用 Python 编写的检查器（383 行非空 Python 代码，外加随仓库附带的 BLAKE3 中的 298 行），它在每个 verify 测试中运行，并且必须与前者结论一致。

## 测量结果

关于代码库的问题，与 Serena、codebase-memory-mcp 以及 Claude Code 自带工具对比（`python tests/bench/neutral/laws.py`，2026-10-04，`claude-sonnet-5-5`，每次运行使用仓库的全新副本，没有额外提示词，每个问题运行三次）。得分是答案要点中出现在回答里的比例；答案要点在任何工具运行之前写好。

| 仓库 | 工具 | 得分 | Token | API 用时 | 费用 |
|---|---|---:|---:|---:|---:|
| nest、typeorm、actual（10 个问题） | Emetgate | 0.944 | 133k | 30.0 s | $0.147 |
| | Serena | 0.963 | 165k | 36.4 s | $0.158 |
| | Claude Code 自带工具 | 0.926 | 193k | 35.7 s | $0.168 |
| | codebase-memory-mcp | 0.975 | 199k | 42.0 s | $0.230 |
| OpenBot（5 个问题） | Emetgate | 0.956 | 97k | 22.7 s | $0.108 |
| | Serena | 0.956 | 102k | 24.5 s | $0.114 |
| | Claude Code 自带工具 | 0.933 | 129k | 24.3 s | $0.114 |
| | codebase-memory-mcp | 0.978 | 137k | 35.1 s | $0.152 |

Emetgate 在两组中的得分都低于 codebase-memory-mcp，在第一组中也低于 Serena。测试配置、记录下来的 300 个会话以及这项对比的局限见 [tests/bench/neutral](tests/bench/neutral)。

常见读取操作的 token 数，与 Claude Code 的 `Read` 对比（o200k_base，`python tests/bench/reader.py`，2026-09-26）：

| 任务 | Read | Emetgate |
|---|---:|---:|
| 在 1.6k 行的文件中找到并读取一个函数 | 13,313 | 2,819 |
| 读取 50 KB 的 `package-lock.json` 中的一个键 | 19,859 | 319 |
| 读取 README 的一个章节 | 15,432 | 1,541 |
| 在同一会话中再次读取同一符号 | 13,313 | 84 |
| 一个 3 行的符号变化后重新读取 | 18 | 74 |

最后一行更差：回复中带有下一次编辑所需的哈希。

完整编辑的 token 数，与 Claude Code 先 `Read` 再 `Edit` 对比（o200k_base，双方都按模型上下文中保存的 `tool_use` 和 `tool_result` 块计数，`python tests/bench/write_flow.py`，2026-09-27，同一个 1.6k 行的文件）：

| 任务 | Read + Edit | Emetgate |
|---|---:|---:|
| 修改大函数中的一行 | 24,646 | 2,145 |
| 替换一个 `if` 块 | 24,703 | 2,191 |
| 整体替换一个小函数 | 24,734 | 502 |
| 删除一个函数及其唯一的调用点 | 24,934 | 810 |
| 在同一文件中做两处编辑 | 24,813 | 2,213 |
| 修改已读文件中的一行 | 139 | 191 |

最后一行更差。文件已在上下文中时，`Edit` 只发送被修改的那一行并收到一行回复；emetgate 成功时的默认回复是状态和新的哈希（影子副本说明、收据 id 和旧哈希需要 `detail:"full"`），而仅它的参数就最多只允许 1.9x。Emetgate 还会在每次编辑时运行测试，这占了它每次编辑 200 到 420 ms 中的大部分。规则、查询和完整写入的测量结果见 [REFERENCE.md](REFERENCE.md)。

与 `rg` 和 `git grep` 对比的搜索（`python tests/bench/search.py`，ReleaseFast）：新会话的首次搜索为 5.5 到 22.7 ms，之后的搜索为 1.9 到 10.1 ms，而 rg 为 27.2 到 80.9 ms，git grep 为 29.1 到 65.7 ms；首次构建索引（每个仓库一次）用时 91 到 1,335 ms（2026-09-27，扫描带宽 3.13 GB/s）。每次搜索都先等待一个变更监视屏障，因此在调用之前已关闭或已刷盘的写入会出现在结果中；新会话会加载已保存的索引，只重新读取时间戳发生变化的文件。完整表格以及该屏障唯一覆盖不到的情况（写入方一直保持文件打开）见 [REFERENCE.md](REFERENCE.md#search)。

| 搜索 | rg | git grep | Emetgate，会话中首次 | Emetgate，之后 |
|---|---:|---:|---:|---:|
| 一条错误消息字符串 | 28.1 ms | 34.8 ms | 6.2 ms | 3.1 ms |
| 只出现在注释中的词 | 80.9 ms | 65.7 ms | 22.7 ms | 9.9 ms |
| 一个 JSON 键的值 | 27.2 ms | 29.1 ms | 8.1 ms | 4.8 ms |
| 一个常见的短词 | 33.3 ms | 35.9 ms | 11.4 ms | 6.5 ms |
| 一个正则表达式 | 31.3 ms | 47.2 ms | 10.1 ms | 5.9 ms |
| tryRender 的用法 | 36.8 ms | 36.6 ms | 5.9 ms | 1.9 ms |
| logerror 的用法 | 28.4 ms | 37.9 ms | 5.5 ms | 2.1 ms |
| 在一次已提交的写入和一次 git commit 之后立即搜索 | 32.0 ms | 29.2 ms | 13.6 ms | 10.1 ms |

rg 和 git grep 按一次工具调用所启动的进程计时，因为 Claude Code 的 Grep 每次调用都会启动 rg；Emetgate 按对其运行中的服务器的一次调用计时。每个会话启动一次服务器和每个仓库构建一次索引的时间不在表中；二者都在 REFERENCE.md 中。

## 闸门本身如何被测试

- **变异测试。** 对各项防护进行变异，每一个变异都必须至少让一个测试失败。引擎部分目前有 64 个变异体：57 个被杀死，4 个被证明等价，2 个是作为纵深防御保留的冗余防护，1 个未解决。每个已记录的变异体以及杀死它的测试见 [VERIFICATION.md](VERIFICATION.md)。
- **模型检查。** 提交日志用 TLA+ 描述，并用 TLC 针对两个和三个文件进行了检查，包括恢复过程中的崩溃和丢失的目录项。
- **崩溃测试。** 批次在每一步之后被截断并恢复。
- **红队和模糊测试套件**，针对 MCP 接口、沙箱、日志和解析器。

英文 README 中生成块里的数字由源码生成，并在 CI 中检查；CI 同时检查本页的数字与之一致。

## 安装

每个版本都会在[发布页面](https://github.com/emetgate/emetgate/releases)上提供 `emetgate.exe` 及其 SHA-256。

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

该二进制文件没有代码签名，因此首次运行时 SmartScreen 会发出警告。请改为比对校验和。

## 构建

Zig 0.16.0。tree-sitter 和各语法随仓库一起提供。

```sh
zig build                  # zig-out/bin/emetgate
zig build test             # all tests
tools/accept.ps1 <ref>     # tests three times, then the mutants on lines changed since <ref>
```

## 安全历史

针对闸门的发现。详情见 [REFERENCE.md](REFERENCE.md#security-history)。

**F1：写入工具没有被限制在所服务的仓库内。** 已在 v0.1.2 中修复。

**F2：git worktree 中的 `.git` 因错误的理由被拒绝。** 低严重性；已修复。

**F3：被拒绝的提议在其测试运行期间可以写入真实仓库。** 已在 v0.1.2 中用低完整性令牌修复。

**仓库账本：已提交账本中的 `cmd:` 规则未经同意就会运行。** 已在 PR #31 中修复。

**F4：批次过程中的崩溃可能使其只应用了一半。** 通过 TLA+ 发现；用批次提交记录修复。

**F5：测试命令无法通过 junction 看到 `node_modules`。** 功能性故障；用硬链接树修复。

**F6：替换文件时崩溃可能使其路径为空。** 通过 TLA+ 发现；用先复制再替换的方式修复。

**F7：断电可能使批次只应用了一半。** 通过 TLA+ 发现；通过刷盘四处目录变更修复。

## 局限

- 仅支持 Windows；沙箱使用 Job Object 和完整性级别。仅支持 TypeScript、JavaScript 和 Zig。
- 通过闸门意味着代码可以解析、没有越界，并且通过了你的测试。这并不意味着代码是正确的。
- 测试闸门的强度取决于你的测试。
- 沙箱阻止向影子副本之外写入。它不阻止读取或网络访问。存在一个 AppContainer 后端，但没有启用，因为真实项目目前还无法在其下运行。
- 在闸门之外所做的修改不在覆盖范围内。lockdown 正是为此而设。
- Node.js 24.15.0 及更早版本在 Windows 回环连接上会间歇性崩溃；请使用 24.16.0 或更高版本。

## 许可证

MIT。`vendor/` 下随仓库附带的语法保留其各自的 MIT 许可证。

<p align="center"><a href="README.md">English</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <b>简体中文</b> · <a href="README.es.md">Español</a></p>
