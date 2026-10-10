import argparse
import json
import re
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_EXE = REPO_ROOT / "zig-out" / "bin" / "emetgate.exe"

INJECTION_PATTERNS = [
    r"ignore (all |any )?(previous|prior|above) instructions",
    r"disregard (the |your )?(system|previous) prompt",
    r"you must always",
    r"do not tell the user",
    r"without (asking|telling) the user",
    r"send (this|the|your) (data|output|contents?) to",
    r"exfiltrat",
    r"base64",
    r"curl http",
    r"http://[^\s\"]+",
    r"https://(?!github\.com)[^\s\"]+",
]

MAX_DESCRIPTION_CHARS = 2000
STDERR_TAIL_LINES = 20
MAX_ERROR_FIELD_CHARS = 600


def write_config(exe):
    config = {
        "mcpServers": {
            "emetgate": {
                "command": str(exe),
                "args": ["mcp", "--test", "cmd /c exit 0"],
            }
        }
    }
    handle = tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, encoding="utf-8"
    )
    json.dump(config, handle)
    handle.close()
    return Path(handle.name)


def run_inspect(config, verbose):
    result = subprocess.run(
        [
            "snyk-agent-scan",
            "inspect",
            str(config),
            "--dangerously-run-mcp-servers",
            "--json",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if verbose:
        print(result.stderr, file=sys.stderr)
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        report = None
    return report, result.stderr, result.returncode


def has_zero_width(text):
    return any(unicodedata.category(ch) == "Cf" for ch in text)


def find_injection(text):
    lowered = text.lower()
    hits = []
    for pattern in INJECTION_PATTERNS:
        if re.search(pattern, lowered):
            hits.append(pattern)
    return hits


def collect_tools(report):
    tools = []
    for entry in report.values():
        if not isinstance(entry, dict):
            continue
        for server in entry.get("servers", []) or []:
            signature = server.get("signature") or {}
            for tool in signature.get("tools", []) or []:
                tools.append(tool)
    return tools


def last_line(text):
    lines = [line for line in (text or "").splitlines() if line.strip()]
    return lines[-1].strip() if lines else ""


def clip(text):
    text = " ".join((text or "").split())
    if len(text) <= MAX_ERROR_FIELD_CHARS:
        return text
    return text[:MAX_ERROR_FIELD_CHARS] + " ..."


def describe_error(where, error):
    lines = [f"scanner error for {where}: {error.get('message') or '<no message>'}"]
    for label, value in (
        ("category", error.get("category")),
        ("exception", error.get("exception")),
        ("cause", last_line(error.get("traceback"))),
        ("server output", clip(error.get("server_output"))),
    ):
        if value:
            lines.append(f"  {label}: {value}")
    return lines


def collect_errors(report):
    lines = []
    for key, entry in report.items():
        if not isinstance(entry, dict):
            continue
        if isinstance(entry.get("error"), dict):
            lines.extend(describe_error(f"config {key}", entry["error"]))
        for server in entry.get("servers", []) or []:
            if isinstance(server.get("error"), dict):
                lines.extend(describe_error(f"server {server.get('name', '<unnamed>')}", server["error"]))
    return lines


def stderr_tail(stderr):
    lines = [line for line in (stderr or "").splitlines() if line.strip()]
    if not lines:
        return []
    tail = lines[-STDERR_TAIL_LINES:]
    return [f"scanner stderr, last {len(tail)} line(s):"] + [f"  {line}" for line in tail]


def evaluate(report, stderr, returncode, out, err):
    if report is None:
        print(f"the scanner printed no JSON report (exit code {returncode})", file=err)
        for line in stderr_tail(stderr):
            print(line, file=err)
        return 2

    tools = collect_tools(report)
    errors = collect_errors(report)
    for line in errors:
        print(line, file=err)
    if errors or not tools:
        for line in stderr_tail(stderr):
            print(line, file=err)
    if not tools:
        print("no tools discovered; the server did not start or advertised nothing", file=err)
        return 2

    findings = []
    for tool in tools:
        findings.extend(check_tool(tool))

    print(f"mcp tool scan: {len(tools)} tool(s) inspected", file=out)
    for tool in tools:
        print(f"  {tool.get('name')}", file=out)

    if findings:
        print(f"FINDINGS: {len(findings)}", file=out)
        for finding in findings:
            print(f"  {finding}", file=out)
        return 1

    print("no injection-style patterns, invisible characters or oversized descriptions found", file=out)
    return 0


def check_tool(tool):
    findings = []
    name = tool.get("name", "<unnamed>")
    description = tool.get("description") or ""

    if len(description) > MAX_DESCRIPTION_CHARS:
        findings.append(f"{name}: description is {len(description)} chars, over {MAX_DESCRIPTION_CHARS}")

    if has_zero_width(description):
        findings.append(f"{name}: description contains a zero-width or other invisible formatting character")

    for pattern in find_injection(description):
        findings.append(f"{name}: description matches an injection-style pattern: {pattern}")

    props = (tool.get("inputSchema") or {}).get("properties") or {}
    for prop_name, prop in props.items():
        prop_description = prop.get("description") or ""
        for pattern in find_injection(prop_description):
            findings.append(f"{name}.{prop_name}: argument description matches an injection-style pattern: {pattern}")
        if has_zero_width(prop_description):
            findings.append(f"{name}.{prop_name}: argument description contains an invisible formatting character")

    return findings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=str(DEFAULT_EXE))
    parser.add_argument("--config", default=None)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if args.config:
        config = Path(args.config)
        if not config.exists():
            print(f"config not found: {config}", file=sys.stderr)
            return 2
    else:
        exe = Path(args.exe)
        if not exe.exists():
            print(f"executable not found: {exe}", file=sys.stderr)
            return 2
        config = write_config(exe)

    report, stderr, returncode = run_inspect(config, args.verbose)
    return evaluate(report, stderr, returncode, sys.stdout, sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
