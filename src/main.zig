const std = @import("std");
const emetgate = @import("emetgate");

const ts = emetgate.tree_sitter;
const skeleton = emetgate.skeleton;
const symbol = emetgate.symbol;
const cas = emetgate.cas;
const stdio = emetgate.stdio;
const runner = emetgate.runner;
const wire = emetgate.wire;
const server = emetgate.server;
const disk = emetgate.disk;
const shadow = emetgate.shadow;
const shadow_root = emetgate.shadow_root;
const lockdown = emetgate.lockdown;
const lockdown_slash = emetgate.lockdown_slash;
const prompt_hook = emetgate.prompt_hook;
const scan_command = emetgate.scan_command;
const rule_command = emetgate.rule_command;
const receipts = emetgate.receipts;
const facts_command = emetgate.facts_command;
const map_command = emetgate.map_command;
const verify_run = emetgate.verify_run;
const Runtime = emetgate.runtime.Runtime;
const Snapshot = emetgate.loader.Snapshot;

const usage =
    \\usage: emetgate skeleton <file.ts>
    \\       emetgate symbols <file.ts> [--json]
    \\       emetgate stats <file.ts>...
    \\       emetgate mutate <file.ts> --symbol <ref> --hash (<hex> | absent) (--body <code> | --body-file <path>) [--json]
    \\       emetgate try <file.ts> --symbol <ref> --hash (<hex> | absent) (--body <code> | --body-file <path>) [--test <command>] [--typecheck <command>] [--shadow-root <dir>] [--shadow-tree (kept | copy)] [--shadow-private <path>] [--allow-repo-config] [--allow-repo-memory] [--json]
    \\       emetgate mcp [--test <command>] [--typecheck <command>] [--allow-run <command>]... [--shadow-root <dir>] [--shadow-tree (kept | copy)] [--shadow-private <path>]... [--read-budget <chars>] [--allow-repo-config] [--allow-repo-memory]
    \\       emetgate scan [--check <spec> [--in <where>]] [--allow-repo-memory] [--json]
    \\
++ rule_command.usage("       emetgate rule ") ++
    \\       emetgate hook prompt
    \\       emetgate recover [--shadow-root <dir>]
    \\       emetgate verify <commit> [--test <command>] [--typecheck <command>] [--skip-tests] [--json]
    \\       emetgate receipts attach [<commit>]
    \\       emetgate lockdown [--no-marks] [<claude args>...]
    \\       emetgate facts build [--threads <n>] [--no-store] [--json]
    \\       emetgate facts (callers | callees | refs) <symbol> [--file <path>] [--depth <n>] [--budget <chars>] [--json]
    \\       emetgate facts defined_at <name> [--file <path>] [--budget <chars>] [--json]
    \\       emetgate facts bench [--seed <n>] [--samples <n>] [--updates <n>] [--json]
    \\       emetgate facts modules [--file <prefix>]
    \\       emetgate facts defs [--file <prefix>]
    \\       emetgate facts evidence --intent <decides|callers|callees|flow|where_defined|explain> --target <path>#<symbol>... [--term <text>]... [--include <callers,callees,tests|none>] [--budget <chars>] [--repeat <n>] [--json]
    \\       emetgate map build [--budget-tokens <n>] [--region-chars <n>] [--term-value <x>] [--chars-per-token <x>] [--no-children] [--out <file>] [--no-store]
    \\       emetgate map region <r1> [--offset <n>] [--budget <chars>] [--no-store]
    \\       emetgate map files [--no-store]
    \\       emetgate map bench [--builds <n>] [--samples <n>] [--updates <n>] [--seed <n>] [--no-store]
    \\       emetgate map rank <r1> --question <text> [--limit <n>] [--no-store]
    \\       emetgate map explore <r1,r2,r3> --question <text> [--k <n>] [--list <n>] [--explore-budget <chars>] [--no-store]
    \\       emetgate map eval --set <file.json> [--limit <n>] [--k <n>] [--list <n>] [--explore-budget <chars>] [--with-text] [--no-store]
    \\
    \\rule writes to the ledger and is deliberately CLI-only: an audited model
    \\has no mcp tool for adopting, superseding or forgetting a rule.
    \\hook prompt is the UserPromptSubmit hook that lockdown gives claude: it reads
    \\the hook JSON on stdin and answers a prompt that starts with /rule itself, as
    \\emetgate rule would, so that prompt never reaches the model.
    \\
    \\A ledger committed to git (.emetgate/ledger.ndjson) came with the clone:
    \\its cmd: and q: rules never run unless try/mcp is started with --allow-repo-memory;
    \\a proposal they cover is refused with UntrustedRepoMemory instead.
    \\scan without --allow-repo-memory skips those q: rules and lists each one as not run.
    \\
    \\lockdown starts claude with no built-in tool and only the .mcp.json servers
    \\(--tools "" --mcp-config .mcp.json --strict-mcp-config, ENABLE_TOOL_SEARCH=false)
    \\and lets emetgate's read-only tools run without a permission prompt (--allowedTools).
    \\It refuses to start unless .mcp.json has exactly one emetgate server.
    \\It also gives claude the hook above and a /rule command (--settings, --add-dir),
    \\both from files under %LOCALAPPDATA%\emetgate\lockdown, none in the project.
    \\It also loads a plugin from the same place (--plugin-dir) that only draws: it marks
    \\each emetgate write in the transcript as passed or refused. /golem off, /golem on
    \\and /golem scene switch it inside claude; lockdown --no-marks starts without it.
    \\The lock is per launch: a claude started without emetgate lockdown is unlocked.
    \\
    \\For mutate/try with --hash <hex> (an existing symbol), --body/--body-file is
    \\only the replacement body block (e.g. "{ return 2; }"), not the whole
    \\declaration; a full "function f() { ... }" there is rejected as
    \\MutationSyntaxInvalid. With --hash absent, --body/--body-file is the whole
    \\new top-level declaration instead.
    \\
;

const max_body_len = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) exitWithUsage();

    var buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(stdio.stdout(), init.io, &buffer);
    const out = &stdout_writer.interface;

    const runtime = try Runtime.create(init.gpa);
    defer runtime.destroy() catch |err| std.debug.panic("runtime closed with live allocations: {t}", .{err});

    const status = dispatch(init, runtime, args, out) catch |err| return fail(err);
    out.flush() catch |err| return fail(err);
    return status;
}

fn dispatch(init: std.process.Init, runtime: *Runtime, args: []const [:0]const u8, out: *std.Io.Writer) !u8 {
    const command = args[1];
    if (std.mem.eql(u8, command, "skeleton") and args.len == 3) {
        try printSkeleton(init, runtime, args[2], out);
        return 0;
    }
    if (std.mem.eql(u8, command, "symbols")) {
        if (args.len == 3) {
            try printSymbols(init, runtime, args[2], out);
            return 0;
        }
        if (args.len == 4 and std.mem.eql(u8, args[3], "--json")) {
            return symbolsJson(init, runtime, args[2], out);
        }
        exitWithUsage();
    }
    if (std.mem.eql(u8, command, "stats")) {
        const skipped = try printStats(init, runtime, args[2..], out);
        return if (skipped == 0) 0 else 1;
    }
    if (std.mem.eql(u8, command, "mutate")) {
        const parsed = extractFlags(init, args[2..]);
        const request = MutateRequest.parse(parsed.rest) orelse exitWithUsage();
        if (parsed.json) return mutateJson(init, runtime, request, out);
        try mutate(init, runtime, request, out);
        return 0;
    }
    if (std.mem.eql(u8, command, "try")) {
        const parsed = extractFlags(init, args[2..]);
        const request = TryRequest.parse(parsed.rest) orelse exitWithUsage();
        const trust: Trust = .{ .repo_config = parsed.allow_repo_config, .repo_memory = parsed.allow_repo_memory };
        if (parsed.json) return tryRunJson(init, runtime, request, out, trust);
        return tryRun(init, runtime, request, out, trust);
    }
    if (std.mem.eql(u8, command, "mcp") or std.mem.eql(u8, command, "serve")) {
        if (server.refusedRunEntry(args[2..])) |refused| exitWithRunRefusal(refused);
        const policy = server.parsePolicy(args[2..]) orelse exitWithUsage();
        try server.serve(runtime.gpa, init.io, runtime, out, policy);
        return 0;
    }
    if (std.mem.eql(u8, command, "scan")) {
        const options = scan_command.Options.parse(args[2..]) orelse exitWithUsage();
        return scanCmd(init, runtime, options, out);
    }
    if (std.mem.eql(u8, command, "rule")) {
        const request = rule_command.parse(args[2..]) orelse exitWithUsage();
        return ruleCmd(init, runtime, request, out);
    }
    if (args.len == 1 + lockdown_slash.hook_args.len and std.mem.eql(u8, command, lockdown_slash.hook_args[0]) and std.mem.eql(u8, args[2], lockdown_slash.hook_args[1])) {
        return hookPromptCmd(init, runtime, out);
    }
    if (std.mem.eql(u8, command, "recover")) {
        if (args.len == 2) return recoverCmd(init, runtime, null);
        if (args.len == 4 and std.mem.eql(u8, args[2], "--shadow-root")) return recoverCmd(init, runtime, args[3]);
        exitWithUsage();
    }
    if (std.mem.eql(u8, command, "verify")) {
        const options = parseVerify(args[2..]) orelse exitWithUsage();
        return verifyCmd(init, runtime, options.options, options.json, out);
    }
    if (std.mem.eql(u8, command, "receipts") and args.len >= 3 and std.mem.eql(u8, args[2], "attach") and args.len <= 4) {
        return attachCmd(init, runtime, if (args.len == 4) args[3] else "HEAD", out);
    }
    if (std.mem.eql(u8, command, "facts")) {
        const options = facts_command.parse(args[2..]) orelse exitWithUsage();
        return facts_command.run(runtime.gpa, init.io, runtime, options, out);
    }
    if (std.mem.eql(u8, command, "map")) {
        const options = map_command.parse(args[2..]) orelse exitWithUsage();
        return map_command.run(runtime.gpa, init.io, runtime, options, out);
    }
    if (std.mem.eql(u8, command, "lockdown")) {
        const passthrough = try init.arena.allocator().alloc([]const u8, args.len - 2);
        for (args[2..], 0..) |arg, i| passthrough[i] = arg;
        return lockdown.launch(runtime.gpa, init.io, init.environ_map, passthrough);
    }
    exitWithUsage();
}

const Extracted = struct { json: bool, allow_repo_config: bool, allow_repo_memory: bool, rest: []const [:0]const u8 };

const Trust = struct { repo_config: bool, repo_memory: bool };

fn isBoolFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--allow-repo-config") or std.mem.eql(u8, arg, "--allow-repo-memory");
}

fn extractFlags(init: std.process.Init, args: []const [:0]const u8) Extracted {
    var json = false;
    var allow_repo_config = false;
    var allow_repo_memory = false;
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true;
        if (std.mem.eql(u8, arg, "--allow-repo-config")) allow_repo_config = true;
        if (std.mem.eql(u8, arg, "--allow-repo-memory")) allow_repo_memory = true;
        if (!isBoolFlag(arg)) count += 1;
    }
    if (count == args.len) return .{ .json = false, .allow_repo_config = false, .allow_repo_memory = false, .rest = args };

    const rest = init.arena.allocator().alloc([:0]const u8, count) catch exitWithUsage();
    var i: usize = 0;
    for (args) |arg| {
        if (isBoolFlag(arg)) continue;
        rest[i] = arg;
        i += 1;
    }
    return .{ .json = json, .allow_repo_config = allow_repo_config, .allow_repo_memory = allow_repo_memory, .rest = rest };
}

fn fail(err: anyerror) u8 {
    std.debug.print("error: {t}\n", .{err});
    return exitCodeFor(err);
}

fn exitWithRunRefusal(refused: server.RunRefusal) noreturn {
    const why = switch (refused.reason) {
        error.RunCommandEmpty => "the command is empty",
        error.RunCommandTooLong => "the command is longer than 512 bytes",
        error.RunCommandShellMetacharacter => "the command has a shell metacharacter (& | < > ^ % ! ; ` $ ( ) or a line break); allow each command on its own",
        error.RunCommandOutOfScope => "installing dependencies and git commit or push are out of scope: an install fetches packages, runs their install scripts and rewrites the linked node_modules, and a commit or push changes history",
    };
    std.debug.print("refused --allow-run \"{s}\": {s}\n", .{ refused.entry, why });
    std.process.exit(2);
}

fn exitWithUsage() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

const exitCodeFor = wire.exitCode;

const rejected_exit_code: u8 = 10;

const try_flags = [_][]const u8{ "--symbol", "--hash", "--body", "--body-file", "--test", "--typecheck", "--shadow-root", "--shadow-tree", "--shadow-private" };

const TryRequest = struct {
    path: []const u8,
    symbol: []const u8,
    hash: []const u8,
    body: union(enum) { inline_text: []const u8, file: []const u8 },
    test_command: []const u8,
    typecheck_command: []const u8,
    shadow_root: ?[]const u8,
    shadow_tree: shadow.TreeMode,
    shadow_private: ?[]const u8,

    fn treeChoice(self: *const TryRequest) shadow.Choice {
        return .{ .tree = self.shadow_tree, .private = if (self.shadow_private) |*prefix| prefix[0..1] else &.{} };
    }

    fn parse(args: []const [:0]const u8) ?TryRequest {
        if (args.len == 0 or args.len % 2 == 0) return null;
        var values: [try_flags.len]?[]const u8 = @splat(null);

        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const slot = flagIndex(&try_flags, args[i]) orelse return null;
            if (values[slot] != null or flagIndex(&try_flags, args[i + 1]) != null) return null;
            values[slot] = args[i + 1];
        }

        const tree: shadow.TreeMode = if (values[7]) |text| server.parseTree(text) orelse return null else shadow.default_tree;
        if (values[8]) |prefix| shadow.validateRelative(prefix) catch return null;
        const inline_body = values[2];
        const body_file = values[3];
        if ((inline_body == null) == (body_file == null)) return null;
        return .{
            .path = args[0],
            .symbol = values[0] orelse return null,
            .hash = values[1] orelse return null,
            .body = if (inline_body) |text| .{ .inline_text = text } else .{ .file = body_file.? },
            .test_command = values[4] orelse "",
            .typecheck_command = values[5] orelse "",
            .shadow_root = values[6],
            .shadow_tree = tree,
            .shadow_private = values[8],
        };
    }
};

fn tryRun(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer, trust: Trust) !u8 {
    const gpa = runtime.gpa;
    const expected = try symbol.parseExpected(request.hash);
    const target = try newFileTarget(init, gpa, request.path, expected);
    defer if (target) |place| place.deinit(gpa);
    const file_abs: [:0]const u8 = if (target) |place| try gpa.dupeZ(u8, place.abs) else try std.Io.Dir.cwd().realPathFileAlloc(init.io, request.path, gpa);
    defer gpa.free(file_abs);

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const test_command = try runner.resolveTestCommand(gpa, init.io, file_abs, request.test_command, trust.repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, init.io, file_abs, request.typecheck_command, trust.repo_config);
    defer if (typecheck_command) |command| gpa.free(command);

    var trace: runner.Trace = .{};
    const result = runner.tryMutate(gpa, init.io, runtime, .{
        .file_abs = file_abs,
        .ref_text = request.symbol,
        .expected_hash = expected,
        .new_body = body,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .allow_repo_memory = trust.repo_memory,
        .shadow_root = request.shadow_root,
        .gate_tree = request.treeChoice(),
        .trace = &trace,
    }) catch |err| {
        if (err == error.WrittenButNotIndexed) std.debug.print("error: WrittenButNotIndexed: {s}: {s}\nrun: git add -- {s}\n", .{ request.path, wire.not_indexed_message, request.path });
        return err;
    };
    defer result.deinit(gpa);

    _ = out;
    printShadowNote(gpa, request.shadow_root, trace);
    switch (result) {
        .committed => |new_hash| {
            var old_buf: [symbol.hash_hex_len]u8 = undefined;
            std.debug.print("committed {s}  {s} -> {s}\n", .{ request.symbol, expected.text(&old_buf), &symbol.formatHash(new_hash) });
            return 0;
        },
        .rule_violation => |report| {
            for (report.violations) |v| std.debug.print("rejected: rule {s} ({s}) at {s}:{d}:{d}: {s}\n", .{ v.rule, v.check, v.file, v.line, v.col, v.text });
            return rejected_exit_code;
        },
        .typecheck_failed => |report| {
            printStageRejected("typecheck", report.outcome);
            if (report.stdout.len != 0) std.debug.print("--- stdout ---\n{s}\n", .{report.stdout});
            if (report.stderr.len != 0) std.debug.print("--- stderr ---\n{s}\n", .{report.stderr});
            return rejected_exit_code;
        },
        .rejected => |report| {
            printStageRejected("tests", report.outcome);
            if (report.stdout.len != 0) std.debug.print("--- stdout ---\n{s}\n", .{report.stdout});
            if (report.stderr.len != 0) std.debug.print("--- stderr ---\n{s}\n", .{report.stderr});
            return rejected_exit_code;
        },
        .rule_check_failed => |crashed| {
            std.debug.print("rejected: {s}: rule {s} ({s}) on {s}: {s}: {s}\n", .{ wire.rule_check_crashed_reason, crashed.rule, crashed.check, crashed.file, crashed.detail, crashed.text });
            return rejected_exit_code;
        },
    }
}

fn printLeftBehind(trace: runner.Trace) void {
    const tree = trace.tree orelse return;
    const err = tree.left_behind orelse return;
    std.debug.print("warning: the gate tree could not be removed and stays under the shadow root: {t}\n", .{err});
}

fn printShadowNote(gpa: std.mem.Allocator, override: ?[]const u8, trace: runner.Trace) void {
    printLeftBehind(trace);
    const root = shadow_root.displayRoot(gpa, override) catch return;
    defer gpa.free(root);
    if (trace.linked_files + trace.copied_files + trace.skipped_links != 0) {
        std.debug.print("shadow {s}: {d} linked file(s) hardlinked, {d} copied, {d} link(s) inside them skipped\\n", .{ root, trace.linked_files, trace.copied_files, trace.skipped_links });
    }
    if (trace.shadow_dotted) std.debug.print("warning: shadow_path_warning: {s}\\n", .{wire.shadow_path_warning});
}

fn printStageRejected(stage: []const u8, outcome: emetgate.sandbox.Outcome) void {
    switch (outcome) {
        .crashed => |code| std.debug.print("rejected: {s} crashed (0x{X:0>8})\n", .{ stage, code }),
        .exited, .timed_out, .output_limit => std.debug.print("rejected: {s} did not pass ({t})\n", .{ stage, outcome }),
    }
}

fn tryRunJson(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer, trust: Trust) u8 {
    var trace: runner.Trace = .{};
    return emitTryJson(init, runtime, request, out, trust, &trace) catch |err| {
        if (err == error.WrittenButNotIndexed) {
            wire.writeNotIndexed(out, request.path) catch {};
        } else {
            wire.writeFailure(out, err, &trace.blocked) catch {};
        }
        return exitCodeFor(err);
    };
}

fn newFileTarget(init: std.process.Init, gpa: std.mem.Allocator, path: []const u8, expected: symbol.Expected) !?runner.Jailed {
    if (expected != .absent) return null;
    std.Io.Dir.cwd().access(init.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try runner.jailNew(gpa, init.io, null, path),
        else => |e| return e,
    };
    return null;
}

fn emitTryJson(init: std.process.Init, runtime: *Runtime, request: TryRequest, out: *std.Io.Writer, trust: Trust, trace: *runner.Trace) !u8 {
    const gpa = runtime.gpa;
    const expected = try symbol.parseExpected(request.hash);
    const target = try newFileTarget(init, gpa, request.path, expected);
    defer if (target) |place| place.deinit(gpa);
    const file_abs: [:0]const u8 = if (target) |place| try gpa.dupeZ(u8, place.abs) else try std.Io.Dir.cwd().realPathFileAlloc(init.io, request.path, gpa);
    defer gpa.free(file_abs);

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const test_command = try runner.resolveTestCommand(gpa, init.io, file_abs, request.test_command, trust.repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, init.io, file_abs, request.typecheck_command, trust.repo_config);
    defer if (typecheck_command) |command| gpa.free(command);

    const result = try runner.tryMutate(gpa, init.io, runtime, .{
        .file_abs = file_abs,
        .ref_text = request.symbol,
        .expected_hash = expected,
        .new_body = body,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .allow_repo_memory = trust.repo_memory,
        .shadow_root = request.shadow_root,
        .gate_tree = request.treeChoice(),
        .trace = trace,
    });
    defer result.deinit(gpa);
    const note_root = try shadow_root.displayRoot(gpa, request.shadow_root);
    defer gpa.free(note_root);
    const note = wire.shadowNote(note_root, trace.*);

    switch (result) {
        .committed => |new_hash| {
            try wire.writeCommitted(out, request.symbol, expected, new_hash, note, true);
            return 0;
        },
        .rejected => |report| {
            try wire.writeRejected(gpa, out, test_command, report, note);
            return rejected_exit_code;
        },
        .typecheck_failed => |report| {
            try wire.writeTypecheckRejected(gpa, out, typecheck_command.?, report, note);
            return rejected_exit_code;
        },
        .rule_violation => |report| {
            try wire.writeRuleViolation(out, report);
            return rejected_exit_code;
        },
        .rule_check_failed => |crashed| {
            try wire.writeRuleCheckFailed(out, crashed, note);
            return rejected_exit_code;
        },
    }
}

fn mutateJson(init: std.process.Init, runtime: *Runtime, request: MutateRequest, out: *std.Io.Writer) u8 {
    emitMutateJson(init, runtime, request, out) catch |err| {
        wire.writeError(out, @errorName(err), exitCodeFor(err)) catch {};
        return exitCodeFor(err);
    };
    return 0;
}

fn emitMutateJson(init: std.process.Init, runtime: *Runtime, request: MutateRequest, out: *std.Io.Writer) !void {
    const gpa = runtime.gpa;
    const ref = try symbol.Ref.parse(gpa, request.symbol);
    defer ref.deinit(gpa);
    const expected = try symbol.parseExpected(request.hash);
    const target = try newFileTarget(init, gpa, request.path, expected);
    defer if (target) |place| place.deinit(gpa);

    const base: ?*Snapshot = if (target == null) try Snapshot.load(runtime, init.io, .cwd(), request.path) else null;
    defer if (base) |snapshot| snapshot.destroy();
    if (base) |snapshot| if (snapshot.tree.root().hasError()) return error.SourceHasErrors;

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const applied = if (target) |place|
        try runner.prepareCreate(gpa, init.io, runtime, place.root, place.abs, place.rel, ref, body)
    else
        try cas.propose(base.?, ref, expected, body);
    defer applied.snapshot.destroy();

    try wire.writeMutated(out, request.symbol, expected, applied.hash, applied.snapshot.source);
}

fn scanCmd(init: std.process.Init, runtime: *Runtime, options: scan_command.Options, out: *std.Io.Writer) !u8 {
    const gpa = runtime.gpa;
    const root = runner.repoRoot(gpa, init.io) catch |err| {
        if (options.json) {
            try wire.writeError(out, @errorName(err), exitCodeFor(err));
            return exitCodeFor(err);
        }
        return err;
    };
    defer gpa.free(root);
    var buffer: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .initStreaming(std.Io.File.stderr(), init.io, &buffer);
    const code = try scan_command.run(gpa, init.io, runtime, root, options, out, &stderr_writer.interface);
    try stderr_writer.interface.flush();
    return code;
}

fn ruleCmd(init: std.process.Init, runtime: *Runtime, request: rule_command.Request, out: *std.Io.Writer) !u8 {
    const gpa = runtime.gpa;
    const root = try runner.repoRoot(gpa, init.io);
    defer gpa.free(root);
    var buffer: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .initStreaming(std.Io.File.stderr(), init.io, &buffer);
    defer stderr_writer.interface.flush() catch {};
    try rule_command.run(gpa, init.io, root, request, out, &stderr_writer.interface);
    return 0;
}

fn hookPromptCmd(init: std.process.Init, runtime: *Runtime, out: *std.Io.Writer) u8 {
    answerPrompt(init, runtime, out) catch |err| {
        std.debug.print("error: {t}\n", .{err});
        return prompt_hook.blocking_exit_code;
    };
    return 0;
}

fn answerPrompt(init: std.process.Init, runtime: *Runtime, out: *std.Io.Writer) !void {
    const gpa = runtime.gpa;
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(stdio.stdin(), init.io, &buffer);
    const input = try reader.interface.allocRemaining(gpa, .limited(prompt_hook.max_input_bytes));
    defer gpa.free(input);
    const text = (try prompt_hook.ruleText(init.arena.allocator(), input)) orelse return;
    const root = runner.repoRoot(gpa, init.io);
    defer if (root) |path| gpa.free(path) else |_| {};
    try prompt_hook.respond(gpa, init.io, root, text, out);
    try out.flush();
}

const VerifyArgs = struct { options: verify_run.Options, json: bool };

fn parseVerify(args: []const [:0]const u8) ?VerifyArgs {
    var parsed: VerifyArgs = .{ .options = .{ .commit = "" }, .json = false };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.eql(u8, arg, "--skip-tests")) {
            parsed.options.skip_tests = true;
        } else if (std.mem.eql(u8, arg, "--test") or std.mem.eql(u8, arg, "--typecheck")) {
            if (i + 1 >= args.len) return null;
            i += 1;
            if (arg[2] == 't' and arg[3] == 'e') parsed.options.test_command = args[i] else parsed.options.typecheck_command = args[i];
        } else if (parsed.options.commit.len == 0 and arg.len != 0 and arg[0] != '-') {
            parsed.options.commit = arg;
        } else return null;
    }
    if (parsed.options.commit.len == 0) return null;
    return parsed;
}

fn verifyCmd(init: std.process.Init, runtime: *Runtime, options: verify_run.Options, json: bool, out: *std.Io.Writer) !u8 {
    const gpa = runtime.gpa;
    const root = try runner.repoRoot(gpa, init.io);
    defer gpa.free(root);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const result = try verify_run.run(gpa, arena_state.allocator(), init.io, runtime, root, options);
    if (json) try verify_run.writeJson(out, result) else try verify_run.writeText(out, result);
    return verify_run.exitCode(result.report.verdict);
}

fn attachCmd(init: std.process.Init, runtime: *Runtime, commit: []const u8, out: *std.Io.Writer) !u8 {
    const gpa = runtime.gpa;
    const root = try runner.repoRoot(gpa, init.io);
    defer gpa.free(root);
    const attached = try receipts.attach(gpa, init.io, root, commit);
    try out.print("attached {d} receipt(s) to {s} under refs/notes/{s}\n", .{ attached.count, commit, receipts.notes_ref });
    return 0;
}

fn recoverCmd(init: std.process.Init, runtime: *Runtime, shadow_root_dir: ?[]const u8) !u8 {
    const gpa = runtime.gpa;
    const root = try runner.repoRoot(gpa, init.io);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(init.io, root);
    defer lock.release();

    var buffer: [4096]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .initStreaming(std.Io.File.stderr(), init.io, &buffer);
    const code = try disk.recoverWorkspace(gpa, init.io, root, shadow_root_dir, &stderr_writer.interface);
    try stderr_writer.interface.flush();
    return code;
}

fn printSkeleton(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) !void {
    const snapshot = try Snapshot.load(runtime, init.io, .cwd(), path);
    defer snapshot.destroy();
    const text = try skeleton.skeletonize(runtime.gpa, runtime.parser, snapshot.profile, snapshot.tree);
    defer runtime.gpa.free(text);
    try out.writeAll(text);
}

fn symbolsJson(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) u8 {
    emitSymbolsJson(init, runtime, path, out) catch |err| {
        wire.writeError(out, @errorName(err), exitCodeFor(err)) catch {};
        return exitCodeFor(err);
    };
    return 0;
}

fn emitSymbolsJson(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) !void {
    const snapshot = try Snapshot.load(runtime, init.io, .cwd(), path);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    try wire.writeSymbols(runtime.gpa, out, path, table.*);
}

fn printSymbols(init: std.process.Init, runtime: *Runtime, path: []const u8, out: *std.Io.Writer) !void {
    const snapshot = try Snapshot.load(runtime, init.io, .cwd(), path);
    defer snapshot.destroy();
    const table = try snapshot.symbols();

    for (table.symbols) |entry| {
        const point = entry.node.startPoint();
        try out.print("{s}  L{d}:{d}  {t}  {f}{s}\n", .{
            &symbol.formatHash(entry.hash),
            point.row + 1,
            point.column + 1,
            entry.kind,
            entry.ref,
            if (entry.ambiguous) "  (ambiguous)" else "",
        });
    }
}

const flags = [_][]const u8{ "--symbol", "--hash", "--body", "--body-file" };

const MutateRequest = struct {
    path: []const u8,
    symbol: []const u8,
    hash: []const u8,
    body: union(enum) { inline_text: []const u8, file: []const u8 },

    fn parse(args: []const [:0]const u8) ?MutateRequest {
        if (args.len == 0 or args.len % 2 == 0) return null;
        var values: [flags.len]?[]const u8 = @splat(null);

        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const slot = flagIndex(&flags, args[i]) orelse return null;
            if (values[slot] != null or flagIndex(&flags, args[i + 1]) != null) return null;
            values[slot] = args[i + 1];
        }

        const inline_body = values[2];
        const body_file = values[3];
        if ((inline_body == null) == (body_file == null)) return null;
        return .{
            .path = args[0],
            .symbol = values[0] orelse return null,
            .hash = values[1] orelse return null,
            .body = if (inline_body) |text| .{ .inline_text = text } else .{ .file = body_file.? },
        };
    }
};

fn flagIndex(list: []const []const u8, arg: []const u8) ?usize {
    for (list, 0..) |flag, index| {
        if (std.mem.eql(u8, flag, arg)) return index;
    }
    return null;
}

fn mutate(init: std.process.Init, runtime: *Runtime, request: MutateRequest, out: *std.Io.Writer) !void {
    const gpa = runtime.gpa;
    const ref = try symbol.Ref.parse(gpa, request.symbol);
    defer ref.deinit(gpa);
    const expected = try symbol.parseExpected(request.hash);
    const target = try newFileTarget(init, gpa, request.path, expected);
    defer if (target) |place| place.deinit(gpa);

    const base: ?*Snapshot = if (target == null) try Snapshot.load(runtime, init.io, .cwd(), request.path) else null;
    defer if (base) |snapshot| snapshot.destroy();
    if (base) |snapshot| if (snapshot.tree.root().hasError()) return error.SourceHasErrors;

    const body_from_file: ?[]u8 = switch (request.body) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(max_body_len)),
        .inline_text => null,
    };
    defer if (body_from_file) |bytes| gpa.free(bytes);
    const body = body_from_file orelse request.body.inline_text;

    const applied = if (target) |place|
        try runner.prepareCreate(gpa, init.io, runtime, place.root, place.abs, place.rel, ref, body)
    else
        try cas.propose(base.?, ref, expected, body);
    defer applied.snapshot.destroy();

    try out.writeAll(applied.snapshot.source);
    try out.flush();
    var old_buf: [symbol.hash_hex_len]u8 = undefined;
    std.debug.print("mutated {f}  {s} -> {s}\n", .{ ref, expected.text(&old_buf), &symbol.formatHash(applied.hash) });
}

const Totals = struct {
    before: skeleton.Metrics = .{ .bytes = 0, .tokens = 0 },
    after: skeleton.Metrics = .{ .bytes = 0, .tokens = 0 },
    files: usize = 0,
    skipped: usize = 0,
};

fn printStats(init: std.process.Init, runtime: *Runtime, paths: []const [:0]const u8, out: *std.Io.Writer) !usize {
    var totals: Totals = .{};
    for (paths) |path| {
        const snapshot = Snapshot.load(runtime, init.io, .cwd(), path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.print("{s}  skipped: {t}\n", .{ path, err });
                totals.skipped += 1;
                continue;
            },
        };
        defer snapshot.destroy();

        const text = skeleton.skeletonize(runtime.gpa, runtime.parser, snapshot.profile, snapshot.tree) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.print("{s}  skipped: {t}\n", .{ path, err });
                totals.skipped += 1;
                continue;
            },
        };
        defer runtime.gpa.free(text);
        const reparsed = try runtime.parser.parseIn(snapshot.tree.language(), text);
        defer reparsed.deinit();

        const before = skeleton.measure(snapshot.tree);
        const after = skeleton.measure(reparsed);
        try printRow(out, path, before, after);
        totals.before.bytes += before.bytes;
        totals.before.tokens += before.tokens;
        totals.after.bytes += after.bytes;
        totals.after.tokens += after.tokens;
        totals.files += 1;
    }
    try out.print("\n{d} files, {d} skipped\n", .{ totals.files, totals.skipped });
    try printRow(out, "TOTAL", totals.before, totals.after);
    return totals.skipped;
}

fn printRow(out: *std.Io.Writer, label: []const u8, before: skeleton.Metrics, after: skeleton.Metrics) !void {
    try out.print("{s}  bytes {d} -> {d} (-{d:.1}%)  tokens {d} -> {d} (-{d:.1}%)\n", .{
        label,
        before.bytes,
        after.bytes,
        reduction(before.bytes, after.bytes),
        before.tokens,
        after.tokens,
        reduction(before.tokens, after.tokens),
    });
}

fn reduction(before: usize, after: usize) f64 {
    if (before == 0) return 0;
    const b: f64 = @floatFromInt(before);
    const a: f64 = @floatFromInt(after);
    return (b - a) / b * 100;
}
