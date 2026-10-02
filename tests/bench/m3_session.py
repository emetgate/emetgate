import datetime
import json
import os
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PROJECT = os.path.dirname(ROOT)
M3 = os.path.join(PROJECT, "eval", "m3")
LEDGER = os.path.join(M3, "m3-ledger.jsonl")
BUDGET_USD = 15.0
CALL_CAP_USD = 1.5
CLAUDE = os.environ.get("CLAUDE_EXE") or os.path.join(os.environ.get("APPDATA", ""), "npm", "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe")
EXE = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", "emetgate.exe").replace("\\", "/")
SESSION_ENV_VARS = ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_ENTRYPOINT",
                    "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_BRIDGE_SESSION_ID")
SERENA = {"command": "C:/Users/ugur/Desktop/projects/emetgate/eval/session-map-serena/uv/bin/serena.exe",
          "args": ["start-mcp-server", "--context", "C:/Users/ugur/Desktop/projects/emetgate/eval/session-map-runs/serena-only/config/claude-code-only.yml",
                   "--project-from-cwd", "--open-web-dashboard", "False"],
          "env": {"SERENA_HOME": "C:/Users/ugur/Desktop/projects/emetgate/eval/session-map-serena/home"}}
CBM = {"command": "C:/Users/ugur/.local/bin/codebase-memory-mcp.exe"}


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def spent():
    if not os.path.exists(LEDGER):
        return 0.0
    total = 0.0
    with open(LEDGER, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                total += json.loads(line).get("total_cost_usd") or 0.0
    return total


def arm_config(arm, exe=EXE, args=None):
    if arm == "plain":
        return None, None
    if arm == "emetgate":
        return {"mcpServers": {"emetgate": {"command": exe, "args": args or ["mcp", "--test", "npm test"]}}}, "mcp__emetgate"
    if arm == "serena":
        return {"mcpServers": {"serena": SERENA}}, "mcp__serena"
    if arm == "cbm":
        return {"mcpServers": {"codebase-memory-mcp": CBM}}, "mcp__codebase-memory-mcp"
    raise ValueError(arm)


def child_env(tools_arm):
    env = {k: v for k, v in os.environ.items() if k.upper() not in SESSION_ENV_VARS}
    if tools_arm:
        env["ENABLE_TOOL_SEARCH"] = "false"
        env["MCP_TIMEOUT"] = "60000"
    return env


def argv_of(question, mcp_config_path, allowed):
    argv = [CLAUDE, "-p", question, "--output-format", "stream-json", "--verbose", "--setting-sources", "project,local", "--strict-mcp-config",
            "--no-session-persistence", "--max-budget-usd", str(CALL_CAP_USD)]
    if mcp_config_path:
        argv += ["--mcp-config", mcp_config_path, "--tools=", "--allowedTools", allowed]
    return argv


def parse(stdout):
    calls, sizes, turns_usage, result, init = [], [], [], {}, {}
    for line in stdout.splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = e.get("type")
        if kind == "system" and e.get("subtype") == "init":
            init = {"tools": e.get("tools"), "mcp_servers": e.get("mcp_servers"), "model": e.get("model")}
        if kind == "assistant":
            message = e.get("message") or {}
            usage = message.get("usage")
            if usage:
                turns_usage.append({k: usage.get(k, 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")})
            for c in message.get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    calls.append({"name": c.get("name"), "input": c.get("input")})
        if kind == "user":
            for c in (e.get("message") or {}).get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    content = c.get("content")
                    text = content if isinstance(content, str) else "".join(x.get("text", "") for x in (content or []) if isinstance(x, dict))
                    sizes.append(len(text))
        if kind == "result":
            result = e
    return calls, sizes, turns_usage, result, init


def tokens_of(usage):
    return sum(usage.get(k, 0) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"))


def run(label, qid, trial, cwd, question, arm, exe=EXE, args=None, extra_env=None, custom=None, config_file=None):
    out_dir = os.path.join(M3, "runs", label)
    os.makedirs(out_dir, exist_ok=True)
    record_path = os.path.join(out_dir, f"{qid}-{trial}.json")
    if os.path.exists(record_path):
        with open(record_path, encoding="utf-8") as f:
            return json.load(f)
    if spent() + CALL_CAP_USD > BUDGET_USD:
        raise SystemExit(f"model budget reached: spent {spent():.4f} of {BUDGET_USD} USD")
    config, allowed = custom if custom else arm_config(arm, exe, args)
    config_path = None
    if config_file:
        config_path = config_file
    elif config:
        config_path = os.path.join(out_dir, "mcp.json")
        with open(config_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(config, f)
    env = child_env(config is not None or config_file is not None)
    if extra_env:
        env.update(extra_env)
    started = time.perf_counter()
    proc = subprocess.run(argv_of(question, config_path, allowed), cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=1800)
    wall_ms = round((time.perf_counter() - started) * 1000)
    stdout = proc.stdout.decode("utf-8", "replace")
    calls, sizes, turns_usage, result, init = parse(stdout)
    usage = result.get("usage") or {}
    record = {"label": label, "qid": qid, "trial": trial, "arm": arm, "cwd": cwd, "question": question, "started_at": now(), "wall_ms": wall_ms,
              "exit_code": proc.returncode, "stderr": proc.stderr.decode("utf-8", "replace")[-2000:], "turns": result.get("num_turns"),
              "api_ms": result.get("duration_api_ms"), "duration_ms": result.get("duration_ms"), "cost": result.get("total_cost_usd"),
              "tokens": tokens_of(usage), "usage": usage, "turns_usage": turns_usage, "calls": calls, "result_chars": sizes,
              "answer": result.get("result"), "init": init, "is_error": result.get("is_error")}
    with open(record_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(record, f, ensure_ascii=False, indent=1)
    os.makedirs(M3, exist_ok=True)
    with open(LEDGER, "a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({"label": label, "qid": qid, "trial": trial, "arm": arm, "at": record["started_at"], "total_cost_usd": result.get("total_cost_usd"),
                            "tokens": record["tokens"], "api_ms": record["api_ms"], "turns": record["turns"]}) + "\n")
    return record
