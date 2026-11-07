import json
import os
from dataclasses import dataclass, field

PRICE = {
    "input": 1.0,
    "cache_write_1h": 2.0,
    "cache_write_5m": 1.25,
    "cache_read": 0.1,
    "output": 5.0,
}

BASE_USD_PER_MTOK = {
    "fable": 15.0,
    "opus": 5.0,
    "sonnet": 3.0,
    "haiku": 1.0,
}

BUILTIN_TOOLS = {"Read", "Edit", "Write", "Bash", "PowerShell", "Grep", "Glob", "NotebookEdit"}
IMAGE_CHARS = 6400
SKIPPED_TYPES = ('"type":"api-request', '"type":"file-history', '"type":"queue-operation', '"type":"last-prompt"')


def base_usd(model):
    name = (model or "").lower()
    for family, usd in BASE_USD_PER_MTOK.items():
        if family in name:
            return usd
    return BASE_USD_PER_MTOK["opus"]


def is_emetgate(name):
    return name.startswith("mcp__emetgate__") or name.startswith("emetgate_")


@dataclass
class ToolUse:
    name: str
    input: dict
    id: str
    result_text: str = ""
    result_chars: int = 0
    is_error: bool = False
    has_result: bool = False
    images: int = 0


@dataclass
class Call:
    id: str
    model: str
    input: int = 0
    cache_write_1h: int = 0
    cache_write_5m: int = 0
    cache_read: int = 0
    output: int = 0
    tool_uses: list = field(default_factory=list)
    text_chars: int = 0
    other_chars: int = 0
    segment: int = 0
    duplicate: bool = False
    prompt_after: bool = False

    @property
    def cache_write(self):
        return self.cache_write_1h + self.cache_write_5m

    @property
    def context(self):
        return self.input + self.cache_write + self.cache_read

    def units(self):
        return {
            "input": self.input * PRICE["input"],
            "cache_write_1h": self.cache_write_1h * PRICE["cache_write_1h"],
            "cache_write_5m": self.cache_write_5m * PRICE["cache_write_5m"],
            "cache_read": self.cache_read * PRICE["cache_read"],
            "output": self.output * PRICE["output"],
        }

    def usd(self):
        return sum(self.units().values()) * base_usd(self.model) / 1e6

    def set_usage(self, usage):
        self.input = usage.get("input_tokens") or 0
        self.cache_read = usage.get("cache_read_input_tokens") or 0
        self.output = usage.get("output_tokens") or 0
        total_write = usage.get("cache_creation_input_tokens") or 0
        split = usage.get("cache_creation")
        if isinstance(split, dict) and ("ephemeral_1h_input_tokens" in split or "ephemeral_5m_input_tokens" in split):
            self.cache_write_1h = split.get("ephemeral_1h_input_tokens") or 0
            self.cache_write_5m = split.get("ephemeral_5m_input_tokens") or 0
            rest = total_write - self.cache_write_1h - self.cache_write_5m
            if rest > 0:
                self.cache_write_5m += rest
        else:
            self.cache_write_1h = 0
            self.cache_write_5m = total_write


@dataclass
class Session:
    path: str
    project: str
    session_id: str
    is_subagent: bool
    model: str = ""
    calls: list = field(default_factory=list)
    cost_state: dict = None

    def tool_names(self):
        return {u.name for c in self.calls for u in c.tool_uses}

    @property
    def mode(self):
        names = self.tool_names()
        if not names:
            return "none"
        emet = any(is_emetgate(n) for n in names)
        builtin = bool(names & BUILTIN_TOOLS)
        if emet and not builtin:
            return "lockdown"
        if emet:
            return "mixed"
        return "plain"

    def billed_calls(self):
        return [c for c in self.calls if not c.duplicate]

    def usd(self):
        return sum(c.usd() for c in self.billed_calls())


def result_payload(content):
    if isinstance(content, str):
        return content, 0
    if not isinstance(content, list):
        return "", 0
    parts = []
    images = 0
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            parts.append(block.get("text") or "")
        elif block.get("type") == "image":
            images += 1
    return "".join(parts), images


def block_chars(block):
    kind = block.get("type")
    if kind == "text":
        return len(block.get("text") or "")
    if kind == "thinking":
        return len(block.get("thinking") or "")
    if kind == "tool_use":
        return len(json.dumps(block.get("input") or {}, ensure_ascii=False))
    return 0


def parse_session(path, root, seen_ids=None):
    rel = os.path.relpath(path, root)
    parts = rel.replace("\\", "/").split("/")
    is_subagent = "subagents" in parts
    session_id = parts[1] if is_subagent and len(parts) > 2 else os.path.splitext(parts[-1])[0]
    session = Session(path=path, project=parts[0], session_id=session_id, is_subagent=is_subagent)
    calls_by_id = {}
    uses_by_id = {}
    segment = 0
    models = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            head = line[:60]
            if any(t in head for t in SKIPPED_TYPES):
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            kind = record.get("type")
            if kind == "assistant":
                message = record.get("message") or {}
                mid = message.get("id")
                model = message.get("model") or ""
                if not mid or model == "<synthetic>":
                    continue
                call = calls_by_id.get(mid)
                if call is None:
                    call = Call(id=mid, model=model, segment=segment)
                    if seen_ids is not None:
                        call.duplicate = mid in seen_ids
                        seen_ids.add(mid)
                    calls_by_id[mid] = call
                    session.calls.append(call)
                    models[model] = models.get(model, 0) + 1
                usage = message.get("usage")
                if usage:
                    call.set_usage(usage)
                for block in message.get("content") or []:
                    if not isinstance(block, dict):
                        continue
                    call.text_chars += block_chars(block)
                    if block.get("type") == "tool_use" and block.get("id") not in uses_by_id:
                        use = ToolUse(name=block.get("name") or "", input=block.get("input") or {}, id=block.get("id") or "")
                        if not isinstance(use.input, dict):
                            use.input = {}
                        uses_by_id[use.id] = use
                        call.tool_uses.append(use)
            elif kind == "user":
                content = (record.get("message") or {}).get("content")
                prompt = not record.get("isMeta")
                if isinstance(content, str):
                    if session.calls:
                        session.calls[-1].other_chars += len(content)
                        session.calls[-1].prompt_after |= prompt
                    continue
                for block in content or []:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "tool_result":
                        use = uses_by_id.get(block.get("tool_use_id"))
                        text, images = result_payload(block.get("content"))
                        if use is None:
                            if session.calls:
                                session.calls[-1].other_chars += len(text)
                            continue
                        use.result_text = text
                        use.images = images
                        use.result_chars = len(text) + images * IMAGE_CHARS
                        use.is_error = bool(block.get("is_error"))
                        use.has_result = True
                    elif session.calls:
                        session.calls[-1].other_chars += len(block.get("text") or "")
                        session.calls[-1].prompt_after |= prompt and block.get("type") == "text"
            elif kind == "attachment":
                if session.calls:
                    session.calls[-1].other_chars += len(json.dumps(record.get("attachment") or {}, ensure_ascii=False))
            elif kind == "system":
                if record.get("subtype") == "compact_boundary":
                    segment += 1
            elif kind == "cost-state":
                best = session.cost_state
                if best is None or (record.get("totalCostUSD") or 0) >= (best.get("totalCostUSD") or 0):
                    session.cost_state = record
    if models:
        session.model = max(models, key=models.get)
    return session


def session_files(root):
    found = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".jsonl"):
                found.append(os.path.join(dirpath, name))
    found.sort(key=lambda p: (os.path.getmtime(p), p))
    return found


def iter_sessions(root, dedupe=True):
    seen = set() if dedupe else None
    for path in session_files(root):
        yield parse_session(path, root, seen)
