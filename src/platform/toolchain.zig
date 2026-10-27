const std = @import("std");

pub const Family = enum { node_install, node_tool, python_install, python_tool, dotnet, cargo, go };

pub const families_hint = "npm|pnpm|yarn|bun install|i|ci|add|ls|list; npx|pnpx|bunx <tool>; tsc; eslint; pip install; python -m pip|pytest|mypy|ruff|venv|unittest; uv pip|sync|add|venv|lock; pytest; mypy; ruff check; dotnet restore|build|test|new|add|sln|list; cargo build|check|test|fetch|add|clippy|tree|metadata|generate-lockfile; go build|vet|test|mod|get|list; any of these --version; dotnet --info|--list-sdks|--list-runtimes";

const Rule = struct {
    tools: []const []const u8,
    family: Family,
    subcommands: ?[]const []const u8,
    bare: bool = false,
};

const node_managers = [_][]const u8{ "npm", "pnpm", "yarn", "bun" };
const node_runners = [_][]const u8{ "npx", "pnpx", "bunx" };
const node_checkers = [_][]const u8{ "tsc", "eslint" };
const pythons = [_][]const u8{ "python", "python3", "py" };
const pip_subcommands = [_][]const u8{ "install", "list", "freeze", "show", "check" };

const rules = [_]Rule{
    .{ .tools = &node_managers, .family = .node_install, .subcommands = &.{ "install", "i", "ci", "add" } },
    .{ .tools = &.{"yarn"}, .family = .node_install, .subcommands = &.{}, .bare = true },
    .{ .tools = &node_managers, .family = .node_tool, .subcommands = &.{ "ls", "list" } },
    .{ .tools = &node_runners, .family = .node_tool, .subcommands = null },
    .{ .tools = &node_checkers, .family = .node_tool, .subcommands = null, .bare = true },
    .{ .tools = &.{ "pip", "pip3" }, .family = .python_install, .subcommands = &pip_subcommands },
    .{ .tools = &.{"uv"}, .family = .python_install, .subcommands = &.{ "pip", "sync", "add", "remove", "venv", "lock", "tree" } },
    .{ .tools = &.{ "pytest", "mypy" }, .family = .python_tool, .subcommands = null, .bare = true },
    .{ .tools = &.{"ruff"}, .family = .python_tool, .subcommands = &.{"check"} },
    .{ .tools = &.{"dotnet"}, .family = .dotnet, .subcommands = &.{ "restore", "build", "test", "new", "add", "sln", "list" } },
    .{ .tools = &.{"cargo"}, .family = .cargo, .subcommands = &.{ "build", "check", "test", "fetch", "add", "clippy", "tree", "metadata", "generate-lockfile" } },
    .{ .tools = &.{"go"}, .family = .go, .subcommands = &.{ "build", "vet", "test", "mod", "get", "list" } },
};

const python_modules = [_][]const u8{ "pip", "pytest", "mypy", "ruff", "venv", "unittest" };

const forbidden_args = [_][]const u8{ "--fix", "--fix-only", "--unsafe-fixes", "--write", "-w", "--watch", "--watchAll" };

const runner_shell_args = [_][]const u8{ "-c", "--call" };

fn toolName(token: []const u8) []const u8 {
    var name = token;
    for ([_][]const u8{ ".cmd", ".exe", ".bat" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) {
            name = name[0 .. name.len - suffix.len];
            break;
        }
    }
    return name;
}

fn listed(list: []const []const u8, token: []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(item, token)) return true;
    }
    return false;
}

fn hasArg(command: []const u8, args: []const []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, command, " \t\"");
    while (tokens.next()) |token| {
        for (args) |arg| {
            if (std.mem.eql(u8, token, arg)) return true;
            if (std.mem.startsWith(u8, token, arg) and token.len > arg.len and token[arg.len] == '=' and arg[1] == '-') return true;
        }
    }
    return false;
}

fn firstSubcommand(tokens: *std.mem.TokenIterator(u8, .any)) ?[]const u8 {
    while (tokens.next()) |token| {
        if (token.len != 0 and token[0] != '-') return token;
    }
    return null;
}

pub fn classify(command: []const u8) ?Family {
    if (hasArg(command, &forbidden_args)) return null;
    var tokens = std.mem.tokenizeAny(u8, command, " \t\"");
    const first = tokens.next() orelse return null;
    if (std.mem.indexOfAny(u8, first, "\\/:") != null) return null;
    const tool = toolName(first);
    if (versionProbe(tool, tokens)) |family| return family;
    if (listed(&pythons, tool)) return pythonModule(&tokens);
    if (listed(&node_runners, tool) and hasArg(command, &runner_shell_args)) return null;
    for (rules) |rule| {
        if (!listed(rule.tools, tool)) continue;
        var rest = tokens;
        const subcommands = rule.subcommands orelse {
            if (rest.peek() == null and !rule.bare) continue;
            return rule.family;
        };
        const sub = firstSubcommand(&rest) orelse {
            if (rule.bare) return rule.family;
            continue;
        };
        if (listed(subcommands, sub)) return rule.family;
    }
    return null;
}

const version_args = [_][]const u8{ "--version", "-v", "-V", "version" };
const dotnet_info_args = [_][]const u8{ "--info", "--list-sdks", "--list-runtimes" };

fn versionProbe(tool: []const u8, after: std.mem.TokenIterator(u8, .any)) ?Family {
    var rest = after;
    const arg = rest.next() orelse return null;
    if (rest.next() != null) return null;
    if (std.ascii.eqlIgnoreCase(tool, "dotnet") and listed(&dotnet_info_args, arg)) return .dotnet;
    if (!listed(&version_args, arg)) return null;
    if (listed(&node_managers, tool) or listed(&node_runners, tool) or listed(&node_checkers, tool) or std.ascii.eqlIgnoreCase(tool, "node")) return .node_tool;
    if (listed(&pythons, tool) and std.mem.eql(u8, arg, "-v")) return null;
    if (listed(&pythons, tool) or listed(&.{ "pip", "pip3", "uv", "pytest", "mypy", "ruff" }, tool)) return .python_tool;
    if (std.ascii.eqlIgnoreCase(tool, "dotnet")) return .dotnet;
    if (std.ascii.eqlIgnoreCase(tool, "cargo")) return .cargo;
    if (std.ascii.eqlIgnoreCase(tool, "go")) return .go;
    return null;
}

fn pythonModule(tokens: *std.mem.TokenIterator(u8, .any)) ?Family {
    const flag = tokens.next() orelse return null;
    if (!std.mem.eql(u8, flag, "-m")) return null;
    const module = tokens.next() orelse return null;
    if (!listed(&python_modules, module)) return null;
    if (std.ascii.eqlIgnoreCase(module, "pip")) {
        const sub = firstSubcommand(tokens) orelse return null;
        return if (listed(&pip_subcommands, sub)) .python_install else null;
    }
    if (std.ascii.eqlIgnoreCase(module, "ruff")) {
        const sub = firstSubcommand(tokens) orelse return null;
        return if (std.ascii.eqlIgnoreCase(sub, "check")) .python_tool else null;
    }
    return .python_tool;
}

const testing = std.testing;

test "project toolchain commands are classified into their family" {
    const cases = [_]struct { []const u8, Family }{
        .{ "npm install", .node_install },
        .{ "npm i -D typescript", .node_install },
        .{ "npm ci", .node_install },
        .{ "pnpm add zod", .node_install },
        .{ "yarn", .node_install },
        .{ "yarn install --frozen-lockfile", .node_install },
        .{ "npx tsc --noEmit", .node_tool },
        .{ "npx eslint src", .node_tool },
        .{ "tsc", .node_tool },
        .{ "tsc -p tsconfig.json --noEmit", .node_tool },
        .{ "pip install -r requirements.txt", .python_install },
        .{ "python -m pip install pytest", .python_install },
        .{ "python -m venv .venv", .python_tool },
        .{ "py -m pytest -q", .python_tool },
        .{ "uv pip install requests", .python_install },
        .{ "uv sync", .python_install },
        .{ "pytest", .python_tool },
        .{ "mypy src", .python_tool },
        .{ "ruff check .", .python_tool },
        .{ "dotnet restore", .dotnet },
        .{ "dotnet build -c Release", .dotnet },
        .{ "dotnet test", .dotnet },
        .{ "dotnet new xunit -o Tests", .dotnet },
        .{ "dotnet add package Newtonsoft.Json", .dotnet },
        .{ "cargo build", .cargo },
        .{ "cargo test --all", .cargo },
        .{ "go test ./...", .go },
        .{ "go mod tidy", .go },
        .{ "npm.cmd install", .node_install },
        .{ "npm --version", .node_tool },
        .{ "node -v", .node_tool },
        .{ "python --version", .python_tool },
        .{ "go version", .go },
        .{ "dotnet --list-sdks", .dotnet },
        .{ "dotnet --list-runtimes", .dotnet },
        .{ "dotnet --info", .dotnet },
        .{ "npm ls", .node_tool },
        .{ "npm list --depth=0", .node_tool },
        .{ "pip list", .python_install },
        .{ "pip show requests", .python_install },
        .{ "cargo --version", .cargo },
        .{ "uv --version", .python_tool },
        .{ "tsc --version", .node_tool },
        .{ "npx tsc --version", .node_tool },
    };
    for (cases) |case| {
        errdefer std.debug.print("command: {s}\n", .{case[0]});
        try testing.expectEqual(@as(?Family, case[1]), classify(case[0]));
    }
}

test "git, shells, arbitrary runners, explicit paths and file-rewriting flags are not toolchain commands" {
    for ([_][]const u8{
        "git commit -m x",
        "git push",
        "cmd /c del x",
        "powershell -c x",
        "node script.js",
        "python script.py",
        "python -c print(1)",
        "python -m http.server",
        "python -m pip uninstall x",
        "npm run build",
        "npm exec x",
        "npm uninstall x",
        "npx",
        "npx -c whoami",
        "npx --call whoami",
        "npx eslint --fix src",
        "eslint --fix=true src",
        "ruff format .",
        "ruff check --fix .",
        "python -m ruff format",
        "dotnet run",
        "dotnet tool run x",
        "cargo run",
        "go run main.go",
        "go generate",
        "uv run x",
        "tsc -w",
        "C:\\tools\\npm.cmd install",
        ".\\npm install",
        "bin/pytest",
        "git --version",
        "python -v",
        "node --version x",
        "dotnet --list-sdks x",
        "npm --info",
        "dotnet --infox",
        "",
    }) |command| {
        errdefer std.debug.print("accepted: {s}\n", .{command});
        try testing.expectEqual(@as(?Family, null), classify(command));
    }
}
