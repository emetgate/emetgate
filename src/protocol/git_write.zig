const std = @import("std");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const repo = @import("../platform/repo.zig");
const exe_path = @import("../platform/exe_path.zig");
const shadow = @import("../platform/shadow.zig");
const bounded_run = @import("../platform/bounded_run.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;

pub const description = "Runs git, args as for git, e.g. [\"switch\",\"-c\",\"x\"]; force:true for work-losing forms.";

pub const max_args = 32;
const max_output_lines = 40;
const max_output_bytes = 6 * 1024;
const max_read_lines = 200;
pub const max_read_bytes = 8 * 1024;
const local_timeout_ms = 120_000;
const network_timeout_ms = 180_000;
const max_git_output = 1024 * 1024;

pub const Error = error{ MissingGitArgs, TooManyGitArgs, InvalidGitArg };

const Mode = enum { none, reads, writes, unsets };

const Flag = struct {
    name: []const u8,
    value: bool = false,
    lossy: bool = false,
    path: bool = false,
    strategy: bool = false,
    mode: Mode = .none,
};

fn fl(comptime text: []const u8) []const Flag {
    comptime {
        @setEvalBranchQuota(200_000);
        var count = 0;
        var counter = std.mem.tokenizeScalar(u8, text, ' ');
        while (counter.next()) |_| count += 1;
        var out: [count]Flag = undefined;
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        var n = 0;
        while (it.next()) |word| {
            var end = word.len;
            var flag: Flag = .{ .name = "" };
            while (end > 2 and std.mem.indexOfScalar(u8, "=!@~<>%", word[end - 1]) != null) : (end -= 1) switch (word[end - 1]) {
                '=' => flag.value = true,
                '!' => flag.lossy = true,
                '@' => {
                    flag.value = true;
                    flag.path = true;
                },
                '~' => {
                    flag.value = true;
                    flag.strategy = true;
                },
                '<' => flag.mode = .reads,
                '>' => flag.mode = .writes,
                '%' => flag.mode = .unsets,
                else => unreachable,
            };
            flag.name = word[0..end];
            out[n] = flag;
            n += 1;
        }
        const final = out;
        return &final;
    }
}

fn words(comptime text: []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);
        var count = 0;
        var counter = std.mem.tokenizeScalar(u8, text, ' ');
        while (counter.next()) |_| count += 1;
        var out: [count][]const u8 = undefined;
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        var n = 0;
        while (it.next()) |word| : (n += 1) out[n] = word;
        const final = out;
        return &final;
    }
}

const Paths = enum { none, all, clone, worktree, submodule, remote, first_remote, config };

const Spec = struct {
    sub: []const u8,
    flags: []const Flag,
    network: bool = false,
    read: bool = false,
    numeric: bool = false,
    free_first: bool = false,
    default_rev: bool = false,
    actions: []const []const u8 = &.{},
    lossy_actions: []const []const u8 = &.{},
    lead: []const []const u8 = &.{},
    safe_with: []const []const u8 = &.{},
    keep_workspace: bool = false,
    paths: Paths = .none,
};

const common_flags = fl("-q --quiet");
const strategies = words("ort recursive resolve octopus ours subtree");
const no_external = words("--no-ext-diff --no-textconv");

const write_specs = [_]Spec{
    .{ .sub = "branch", .flags = fl("-d --delete -m --move -c --copy -a --all -r --remotes -l --list -v -vv --verbose --show-current --merged --no-merged --contains --no-contains --points-at= --format= --sort= -u= --set-upstream-to= --unset-upstream --track --no-track -D! -M! -C! -f! --force!") },
    .{ .sub = "switch", .flags = fl("-c --create -d --detach -t --track --no-track --orphan -m --merge --guess --no-guess -C! --force-create! -f! --force! --discard-changes!") },
    .{ .sub = "checkout", .flags = fl("-b -t --track --no-track --detach -m --merge --orphan --ours --theirs -B! -f! --force!") },
    .{ .sub = "tag", .flags = fl("-a --annotate -m= --message= -d --delete -l --list -n --contains --no-contains --points-at --merged --no-merged --sort= --format= -f! --force!") },
    .{ .sub = "stash", .flags = fl("-m= --message= -u --include-untracked -a --all -k --keep-index --no-keep-index -S --staged --index --stat -p --patch"), .actions = words("push save list show pop apply branch"), .lossy_actions = words("drop clear") },
    .{ .sub = "add", .flags = fl("-A --all -u --update -N --intent-to-add -f --force --renormalize -v -n --dry-run --ignore-errors --sparse") },
    .{ .sub = "rm", .flags = fl("--cached -r -n --dry-run --ignore-unmatch -f! --force!") },
    .{ .sub = "mv", .flags = fl("-k -n --dry-run -v -f! --force!") },
    .{ .sub = "commit", .flags = fl("-m= --message= -F@ --file@ -a --all --amend --no-edit --allow-empty --allow-empty-message --author= --date= -s --signoff -o --only -i --include --fixup= --squash= -C= --reuse-message= --trailer= --reset-author --cleanup= --dry-run --short -v --verbose") },
    .{ .sub = "restore", .flags = fl("-S --staged -W --worktree -s= --source= --ours --theirs -m --merge --conflict=") },
    .{ .sub = "reset", .flags = fl("--soft --mixed -N --keep --merge --hard!") },
    .{ .sub = "merge", .flags = fl("--no-ff --ff --ff-only --squash --no-squash --commit --no-commit -m= --message= --abort --continue --quit --no-edit -X= --strategy-option= -s~ --strategy~ --allow-unrelated-histories --stat --no-stat --log --no-log --signoff --autostash --no-autostash") },
    .{ .sub = "rebase", .flags = fl("--onto= --abort --continue --skip --quit --autostash --no-autostash --keep-base --root --empty= --keep-empty --no-keep-empty --update-refs --no-update-refs --committer-date-is-author-date --reset-author-date --autosquash --no-autosquash --rebase-merges -r -i --interactive -X= --strategy-option= -s~ --strategy~ --signoff --fork-point --no-fork-point --force-rebase") },
    .{ .sub = "cherry-pick", .flags = fl("-x -n --no-commit -m= --mainline= --abort --continue --skip --quit --ff --allow-empty --allow-empty-message --keep-redundant-commits --empty= -X= --strategy-option= --strategy~ -s --signoff") },
    .{ .sub = "revert", .flags = fl("-n --no-commit --no-edit -m= --mainline= --abort --continue --skip --quit -X= --strategy-option= --strategy~ -s --signoff --reference") },
    .{ .sub = "fetch", .network = true, .paths = .first_remote, .flags = fl("--all -p --prune -P --prune-tags -t --tags --no-tags --depth= --deepen= --shallow-since= --unshallow --dry-run -v --recurse-submodules --no-recurse-submodules -j= --jobs= --set-upstream -f! --force!") },
    .{ .sub = "pull", .network = true, .paths = .first_remote, .flags = fl("--ff-only --ff --no-ff -r --rebase --no-rebase --autostash --no-autostash --no-edit --tags --no-tags -v --squash --no-squash --commit --no-commit -p --prune --all --depth= --recurse-submodules --no-recurse-submodules -s~ --strategy~ -X= --strategy-option= --allow-unrelated-histories --signoff") },
    .{ .sub = "push", .network = true, .paths = .first_remote, .flags = fl("-u --set-upstream --tags --follow-tags -n --dry-run -v --porcelain --atomic --all --branches -o= --push-option= -f! --force! --force-with-lease! --force-if-includes! -d! --delete! --mirror! --prune!") },
    .{ .sub = "init", .paths = .all, .flags = fl("-b= --initial-branch= --bare --object-format=") },
    .{ .sub = "clone", .network = true, .paths = .clone, .flags = fl("-b= --branch= --depth= --shallow-since= --single-branch --no-single-branch --no-tags --recurse-submodules --shallow-submodules --no-shallow-submodules -n --no-checkout --bare --mirror -o= --origin= --filter= --sparse -v -j= --jobs=") },
    .{ .sub = "remote", .network = true, .paths = .remote, .flags = fl("-v --verbose -f -t= -m= --tags --no-tags --push --add --delete -d --all -a --auto -n --dry-run -p --prune"), .actions = words("add rename set-url get-url set-head set-branches show prune update"), .lossy_actions = words("remove rm") },
    .{ .sub = "config", .paths = .config, .free_first = true, .flags = fl("--local --get< --get-all< --get-regexp< -l< --list< --unset% --unset-all% --add> --replace-all> --show-origin --show-scope --name-only --type= --bool --int --bool-or-int --path --default= -z --null --all --regexp --value= --fixed-value") },
    .{ .sub = "clean", .keep_workspace = true, .safe_with = words("-n --dry-run"), .flags = fl("-n --dry-run -d -x -X -e= --exclude= -f! --force!") },
    .{ .sub = "worktree", .paths = .worktree, .flags = fl("-b= -B=! --detach -d --checkout --no-checkout --lock --reason= --track --no-track --guess-remote --no-guess-remote --orphan --porcelain -v --verbose -z --expire= -n --dry-run -f! --force!"), .actions = words("add list lock unlock move prune repair"), .lossy_actions = words("remove") },
    .{ .sub = "submodule", .network = true, .paths = .submodule, .flags = fl("--init --recursive --remote --no-fetch -N --checkout --rebase --merge --depth= --recommend-shallow --no-recommend-shallow -b= --branch= --name= --cached --files --all --single-branch -j= --jobs= --default -d -f! --force!"), .actions = words("add status init update summary sync set-branch set-url absorbgitdirs"), .lossy_actions = words("deinit") },
    .{ .sub = "apply", .paths = .all, .flags = fl("--check --stat --numstat --summary --index --cached -3 --3way -R --reverse -p= -C= --reject --whitespace= --ignore-space-change --ignore-whitespace --recount --unidiff-zero --directory= --exclude= --include= -v --verbose --allow-empty -N --intent-to-add") },
    .{ .sub = "am", .paths = .all, .flags = fl("-3 --3way -s --signoff -k --keep --keep-non-patch --keep-cr --no-keep-cr -c --scissors --no-scissors -m --message-id -r --resolved --abort --continue --skip --quit --show-current-patch --committer-date-is-author-date --ignore-date --ignore-space-change --ignore-whitespace --whitespace= -p= -C= --directory= --exclude= --include= --reject --allow-empty --empty=") },
    .{ .sub = "format-patch", .numeric = true, .flags = fl("-o@ --output-directory@ --stdout -n --numbered -N --no-numbered --cover-letter --no-cover-letter -v= --reroll-count= --subject-prefix= --rfc --start-number= --base= --no-stat -k --keep-subject -s --signoff --zero-commit --root --suffix= --no-binary -M --find-renames --thread --no-thread --to= --cc= --from") },
    .{ .sub = "bisect", .flags = fl("--term-old= --term-new= --term-good= --term-bad= --no-checkout --first-parent"), .actions = words("start bad good new old skip reset log terms") },
};

const read_specs = [_]Spec{
    .{ .sub = "log", .read = true, .numeric = true, .lead = no_external, .flags = fl("-n= --max-count= --skip= --author= --committer= --since= --after= --until= --before= --grep= -i --regexp-ignore-case -E -F --all-match --invert-grep --all --branches --tags --remotes --no-merges --merges --first-parent --oneline --format= --pretty= --abbrev-commit --date= --graph --decorate --no-decorate --reverse --left-right --cherry-pick --cherry-mark --boundary --follow --stat --shortstat --numstat --name-only --name-status --summary -p -u --patch --no-patch -s -S= -G= --pickaxe-regex --diff-filter= -M --find-renames -L= --full-history --simplify-by-decoration --ancestry-path --source -w --ignore-all-space -b --ignore-space-change --word-diff -m --cc --relative --no-renames --topo-order --date-order --author-date-order -g --walk-reflogs -U --unified") },
    .{ .sub = "diff", .read = true, .numeric = true, .lead = no_external, .flags = fl("--cached --staged --stat --shortstat --numstat --name-only --name-status --summary --compact-summary --dirstat -p --patch -U --unified -w --ignore-all-space -b --ignore-space-change --ignore-blank-lines --ignore-space-at-eol --word-diff --diff-filter= -M -C --find-renames --find-copies -R --check --merge-base --no-renames --relative -z --exit-code --quiet --ours --theirs --base --cc -a --text --minimal --patience --histogram --diff-algorithm= --raw --abbrev --full-index --binary -S= -G= --pickaxe-all") },
    .{ .sub = "show", .read = true, .numeric = true, .lead = no_external, .flags = fl("--stat --shortstat --numstat --name-only --name-status --summary -s --no-patch --oneline --format= --pretty= --abbrev-commit --date= -p --patch -U --unified -w --ignore-all-space -b --ignore-space-change --word-diff -M --find-renames -m --cc --first-parent --no-renames --diff-filter= --raw") },
    .{ .sub = "status", .read = true, .flags = fl("-s --short -b --branch --porcelain --long -v --verbose -uno -uall -unormal --untracked-files --ignored --ahead-behind --no-ahead-behind --show-stash -z --renames --no-renames") },
    .{ .sub = "grep", .read = true, .flags = fl("-n --line-number -i --ignore-case -w --word-regexp -v --invert-match -l --files-with-matches -L --files-without-match -c --count -h -H --full-name -E --extended-regexp -F --fixed-strings -G --basic-regexp -P --perl-regexp -e= --and --or --not --all-match -o --only-matching --cached --untracked --recurse-submodules --max-depth= -A= -B= -C= --context= --after-context= --before-context= --heading --break -p --show-function -W --function-context -I -a --text -r --recursive -z --column -m= --max-count=") },
    .{ .sub = "ls-files", .read = true, .flags = fl("-c --cached -d --deleted -m --modified -o --others -i --ignored -s --stage -u --unmerged -k --killed --directory --no-empty-directory --exclude-standard -x= --exclude= --error-unmatch --full-name -t -v -f -z --eol --deduplicate --format= --recurse-submodules --sparse --abbrev") },
    .{ .sub = "reflog", .read = true, .numeric = true, .free_first = true, .actions = words("show list exists"), .lossy_actions = words("expire delete"), .flags = fl("-n= --max-count= --oneline --format= --pretty= --date= --all --abbrev-commit --stat -p --expire= --expire-unreachable= --stale-fix --rewrite --updateref --dry-run --verbose --single-worktree") },
    .{ .sub = "describe", .read = true, .flags = fl("--tags --all --always --long --abbrev --dirty --broken --contains --exact-match --match= --exclude= --candidates= --first-parent") },
    .{ .sub = "shortlog", .read = true, .default_rev = true, .flags = fl("-s --summary -n --numbered -e --email --format= --group= -c --committer --since= --after= --until= --before= --author= --no-merges --merges --all --first-parent") },
    .{ .sub = "rev-parse", .read = true, .flags = fl("--abbrev-ref --short --verify --symbolic --symbolic-full-name --show-toplevel --show-prefix --show-cdup --git-dir --git-common-dir --absolute-git-dir --is-inside-work-tree --is-inside-git-dir --is-bare-repository --is-shallow-repository --all --branches --tags --remotes --show-object-format --end-of-options") },
    .{ .sub = "rev-list", .read = true, .numeric = true, .flags = fl("-n= --max-count= --skip= --count --all --branches --tags --remotes --left-right --left-only --right-only --cherry-pick --cherry-mark --no-merges --merges --first-parent --reverse --since= --after= --until= --before= --author= --grep= --ancestry-path --topo-order --abbrev-commit --oneline --max-parents --min-parents") },
    .{ .sub = "merge-base", .read = true, .flags = fl("--is-ancestor --all -a --fork-point --octopus --independent") },
    .{ .sub = "cat-file", .read = true, .flags = fl("-p -t -s -e") },
    .{ .sub = "for-each-ref", .read = true, .flags = fl("--format= --sort= --count= --contains --no-contains --merged --no-merged --points-at= --ignore-case") },
    .{ .sub = "ls-remote", .read = true, .network = true, .paths = .first_remote, .flags = fl("--heads -h --branches -b --tags -t --refs --symref --exit-code --get-url --sort=") },
    .{ .sub = "cherry", .read = true, .flags = fl("-v --abbrev") },
    .{ .sub = "count-objects", .read = true, .flags = fl("-v --verbose -H --human-readable") },
};

const all_specs = write_specs ++ read_specs;

const config_keys = words("user.name user.email core.autocrlf core.eol core.safecrlf core.ignorecase core.filemode core.quotepath core.whitespace init.defaultbranch pull.rebase pull.ff push.default push.autosetupremote push.followtags fetch.prune fetch.prunetags merge.ff merge.conflictstyle rebase.autostash rebase.autosquash rebase.updaterefs rerere.enabled rerere.autoupdate diff.renames diff.algorithm status.showuntrackedfiles tag.sort branch.sort log.date commit.cleanup");
const config_sub_keys = words("branch.remote branch.merge branch.rebase branch.pushremote branch.description remote.url remote.pushurl remote.fetch remote.push remote.prune remote.tagopt");
const config_actions = words("get set unset list");
const workspace_exclude = ":(exclude,top)" ++ shadow.workspace_dir;
const remote_schemes = words("https:// http:// ssh:// git:// git+ssh:// ssh+git://");

const prefix = [_][]const u8{
    "-c",         "core.editor=:",
    "-c",         "sequence.editor=:",
    "-c",         "core.pager=cat",
    "-c",         "credential.interactive=never",
    "-c",         "gc.auto=0",
    "-c",         "maintenance.auto=false",
    "-c",         "core.fsmonitor=false",
    "-c",         "color.ui=false",
    "-c",         "advice.detachedHead=false",
    "-c",         "core.longpaths=true",
    "-c",         "protocol.ext.allow=never",
    "--no-pager",
};

const read_prefix = [_][]const u8{
    "-c",                  "core.pager=cat",
    "-c",                  "credential.interactive=never",
    "-c",                  "core.fsmonitor=false",
    "-c",                  "color.ui=false",
    "-c",                  "diff.external=",
    "-c",                  "core.longpaths=true",
    "-c",                  "protocol.ext.allow=never",
    "--no-optional-locks", "--no-pager",
};

const forced_env = [_][2][]const u8{
    .{ "GIT_EDITOR", ":" },
    .{ "GIT_SEQUENCE_EDITOR", ":" },
    .{ "GIT_PAGER", "cat" },
    .{ "GIT_TERMINAL_PROMPT", "0" },
    .{ "GIT_MERGE_AUTOEDIT", "no" },
    .{ "GCM_INTERACTIVE", "never" },
};
const dropped_env = words("GIT_EXTERNAL_DIFF GIT_ASKPASS SSH_ASKPASS GIT_SSH_COMMAND GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT");

pub const Refusal = struct { reason: []const u8, arg: []const u8 };

pub const Ok = struct {
    spec: *const Spec,
    lossy: bool = false,
    reads: bool = false,
    writes: bool = false,
    unsets: bool = false,
    pos: [max_args][]const u8 = undefined,
    npos: usize = 0,
    npos_before: usize = 0,
    path_values: [max_args][]const u8 = undefined,
    npath: usize = 0,
    dashdash: ?usize = null,

    fn positionals(self: *const Ok) []const []const u8 {
        return self.pos[0..self.npos];
    }
};

pub const Check = union(enum) {
    ok: Ok,
    refused: Refusal,
};

fn refuse(reason: []const u8, arg: []const u8) Check {
    return .{ .refused = .{ .reason = reason, .arg = arg } };
}

fn findSpec(table: []const Spec, sub: []const u8) ?*const Spec {
    for (table) |*spec| if (std.mem.eql(u8, spec.sub, sub)) return spec;
    return null;
}

fn findExact(spec: *const Spec, arg: []const u8) ?Flag {
    for (spec.flags) |flag| if (std.mem.eql(u8, arg, flag.name)) return flag;
    for (common_flags) |flag| if (std.mem.eql(u8, arg, flag.name)) return flag;
    return null;
}

fn findFlag(spec: *const Spec, arg: []const u8) ?struct { flag: Flag, inline_value: bool } {
    if (findExact(spec, arg)) |flag| return .{ .flag = flag, .inline_value = false };
    for (spec.flags) |flag| {
        if (std.mem.startsWith(u8, flag.name, "--") and arg.len > flag.name.len and std.mem.startsWith(u8, arg, flag.name) and arg[flag.name.len] == '=') return .{ .flag = flag, .inline_value = true };
    }
    return null;
}

fn listed(list: []const []const u8, word: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, word)) return true;
    return false;
}

fn allDigits(text: []const u8, allow_percent: bool) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and !(allow_percent and c == '%')) return false;
    return true;
}

const Walker = struct {
    ok: Ok,
    args: []const []const u8,
    i: usize,
    staged: bool = false,
    worktree: bool = false,
    safe: bool,

    fn take(self: *Walker, flag: Flag, inline_value: ?[]const u8) ?Check {
        const arg = self.args[self.i];
        if (flag.lossy) self.ok.lossy = true;
        switch (flag.mode) {
            .none => {},
            .reads => self.ok.reads = true,
            .writes => self.ok.writes = true,
            .unsets => self.ok.unsets = true,
        }
        if (std.mem.eql(u8, flag.name, "--staged") or std.mem.eql(u8, flag.name, "-S")) self.staged = true;
        if (std.mem.eql(u8, flag.name, "--worktree") or std.mem.eql(u8, flag.name, "-W")) self.worktree = true;
        if (listed(self.ok.spec.safe_with, flag.name)) self.safe = true;
        if (!flag.value) return null;
        const value = inline_value orelse blk: {
            self.i += 1;
            if (self.i == self.args.len) return refuse("missing_value", arg);
            break :blk self.args[self.i];
        };
        if (flag.strategy and !listed(strategies, value)) return refuse("unsupported_value", value);
        if (flag.path) {
            self.ok.path_values[self.ok.npath] = value;
            self.ok.npath += 1;
        }
        return null;
    }

    fn short(self: *Walker, arg: []const u8) ?Check {
        if (findExact(self.ok.spec, arg[0..2])) |head| {
            if (head.value) return self.take(head, arg[2..]);
            if (allDigits(arg[2..], true)) return self.take(head, null);
        }
        for (arg[1..], 0..) |c, k| {
            const name = [_]u8{ '-', c };
            const flag = findExact(self.ok.spec, &name) orelse return refuse("unsupported_flag", arg);
            if (flag.value and k + 2 != arg.len) return refuse("unsupported_flag", arg);
            if (self.take(flag, null)) |why| return why;
        }
        return null;
    }
};

pub fn check(args: []const []const u8) Check {
    return checkIn(&all_specs, args);
}

pub fn checkRead(args: []const []const u8) Check {
    return checkIn(&read_specs, args);
}

fn checkIn(table: []const Spec, args: []const []const u8) Check {
    if (args.len == 0) return refuse("unsupported_subcommand", "");
    if (args.len > max_args + 1) return refuse("too_many_args", "");
    const spec = findSpec(table, args[0]) orelse return refuse("unsupported_subcommand", args[0]);
    var walk: Walker = .{ .ok = .{ .spec = spec }, .args = args, .i = 1, .safe = spec.safe_with.len == 0 };
    const has_actions = spec.actions.len != 0 or spec.lossy_actions.len != 0;
    while (walk.i < args.len) : (walk.i += 1) {
        const arg = args[walk.i];
        const before = walk.ok.dashdash == null;
        if (before and std.mem.eql(u8, arg, "--")) {
            walk.ok.dashdash = walk.i;
            continue;
        }
        if (before and arg.len > 1 and arg[0] == '-') {
            if (spec.numeric and allDigits(arg[1..], false)) continue;
            if (findFlag(spec, arg)) |found| {
                if (walk.take(found.flag, if (found.inline_value) arg[found.flag.name.len + 1 ..] else null)) |why| return why;
                continue;
            }
            if (arg[1] != '-' and arg.len > 2) {
                if (walk.short(arg)) |why| return why;
                continue;
            }
            return refuse("unsupported_flag", arg);
        }
        if (before and walk.ok.npos == 0 and has_actions) {
            if (listed(spec.lossy_actions, arg)) {
                walk.ok.lossy = true;
            } else if (!listed(spec.actions, arg) and !spec.free_first) {
                return refuse("unsupported_action", arg);
            }
        }
        if (before and spec.network and (arg[0] == '+' or arg[0] == ':')) walk.ok.lossy = true;
        walk.ok.pos[walk.ok.npos] = arg;
        walk.ok.npos += 1;
        if (before) walk.ok.npos_before = walk.ok.npos;
    }
    if (std.mem.eql(u8, spec.sub, "restore") and !(walk.staged and !walk.worktree)) walk.ok.lossy = true;
    if (!walk.safe) walk.ok.lossy = true;
    return .{ .ok = walk.ok };
}

fn insideRoot(arena: Allocator, root_abs: []const u8, path: []const u8) !bool {
    const abs = try std.fs.path.resolve(arena, &.{ root_abs, path });
    const rel = repo.relativeTo(arena, root_abs, abs) catch |err| switch (err) {
        error.FileOutsideRepo => return false,
        else => |e| return e,
    };
    repo.refuseInternal(rel) catch return false;
    return true;
}

fn isRemoteUrl(text: []const u8) bool {
    for (remote_schemes) |scheme| if (std.ascii.startsWithIgnoreCase(text, scheme)) return true;
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    if (colon < 2) return false;
    return std.mem.indexOfAny(u8, text[0..colon], "/\\") == null;
}

fn localPath(text: []const u8) []const u8 {
    if (!std.ascii.startsWithIgnoreCase(text, "file://")) return text;
    const rest = text["file://".len..];
    if (rest.len >= 3 and rest[0] == '/' and rest[2] == ':') return rest[1..];
    return rest;
}

fn remoteRefusal(arena: Allocator, root_abs: []const u8, text: []const u8) !?Refusal {
    if (std.mem.indexOf(u8, text, "::") != null) return .{ .reason = "unsupported_url", .arg = text };
    if (!std.ascii.startsWithIgnoreCase(text, "file:") and isRemoteUrl(text)) return null;
    if (try insideRoot(arena, root_abs, localPath(text))) return null;
    return .{ .reason = "outside_root", .arg = text };
}

fn pathRefusal(arena: Allocator, root_abs: []const u8, text: []const u8) !?Refusal {
    if (try insideRoot(arena, root_abs, text)) return null;
    return .{ .reason = "outside_root", .arg = text };
}

fn configKeyAllowed(key: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, key, '.') orelse return false;
    const last = std.mem.lastIndexOfScalar(u8, key, '.').?;
    var buf: [64]u8 = undefined;
    const section = key[0..first];
    const name = key[last + 1 ..];
    if (section.len + name.len + 1 > buf.len or name.len == 0) return false;
    const joined = std.ascii.lowerString(&buf, section);
    buf[joined.len] = '.';
    const lowered = buf[0 .. joined.len + 1 + name.len];
    _ = std.ascii.lowerString(lowered[joined.len + 1 ..], name);
    return listed(if (first == last) config_keys else config_sub_keys, lowered);
}

fn configRefusal(arena: Allocator, root_abs: []const u8, ok: *const Ok) !?Refusal {
    const pos = ok.positionals();
    var key: ?[]const u8 = null;
    var value: ?[]const u8 = null;
    if (pos.len != 0 and listed(config_actions, pos[0])) {
        const sets = std.mem.eql(u8, pos[0], "set");
        if (sets or std.mem.eql(u8, pos[0], "unset")) {
            if (pos.len > 1) key = pos[1];
            if (sets and pos.len > 2) value = pos[2];
        }
    } else if (!ok.reads) {
        if (pos.len != 0 and std.mem.indexOfScalar(u8, pos[0], '.') == null) return .{ .reason = "unsupported_action", .arg = pos[0] };
        if (ok.unsets or ok.writes or pos.len >= 2) {
            key = pos[0];
            if (!ok.unsets and pos.len > 1) value = pos[1];
        }
    }
    const name = key orelse return null;
    if (!configKeyAllowed(name)) return .{ .reason = "unsupported_config_key", .arg = name };
    const url_key = std.ascii.endsWithIgnoreCase(name, ".url") or std.ascii.endsWithIgnoreCase(name, ".pushurl");
    if (url_key) if (value) |text| return remoteRefusal(arena, root_abs, text);
    return null;
}

pub fn confine(arena: Allocator, root_abs: []const u8, ok: *const Ok) !?Refusal {
    for (ok.path_values[0..ok.npath]) |path| if (try pathRefusal(arena, root_abs, path)) |why| return why;
    const pos = ok.positionals();
    const action = if (pos.len != 0) pos[0] else "";
    switch (ok.spec.paths) {
        .none => {},
        .all => for (pos) |path| if (try pathRefusal(arena, root_abs, path)) |why| return why,
        .clone => {
            if (pos.len > 0) if (try remoteRefusal(arena, root_abs, pos[0])) |why| return why;
            if (pos.len > 1) if (try pathRefusal(arena, root_abs, pos[1])) |why| return why;
        },
        .first_remote => if (pos.len > 0) return remoteRefusal(arena, root_abs, pos[0]),
        .remote => if (pos.len > 2 and (std.mem.eql(u8, action, "add") or std.mem.eql(u8, action, "set-url"))) return remoteRefusal(arena, root_abs, pos[2]),
        .submodule => {
            if (std.mem.eql(u8, action, "add")) {
                if (pos.len > 1) if (try remoteRefusal(arena, root_abs, pos[1])) |why| return why;
                if (pos.len > 2) return pathRefusal(arena, root_abs, pos[2]);
            }
            if (std.mem.eql(u8, action, "set-url") and pos.len > 2) return remoteRefusal(arena, root_abs, pos[2]);
        },
        .worktree => {
            if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "prune") or pos.len < 2) return null;
            const end = if (std.mem.eql(u8, action, "add")) 2 else pos.len;
            for (pos[1..end]) |path| if (try pathRefusal(arena, root_abs, path)) |why| return why;
        },
        .config => return configRefusal(arena, root_abs, ok),
    }
    return null;
}

fn checkoutTargets(args: []const []const u8) struct { refs: [2]?[]const u8 = .{ null, null }, count: usize = 0, paths: bool = false } {
    var out: @TypeOf(checkoutTargets(&.{})) = .{};
    const spec = findSpec(&write_specs, "checkout").?;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            out.paths = i + 1 < args.len;
            break;
        }
        if (arg.len > 1 and arg[0] == '-') {
            const found = findFlag(spec, arg) orelse continue;
            if (std.mem.eql(u8, found.flag.name, "-b") or std.mem.eql(u8, found.flag.name, "-B") or std.mem.eql(u8, found.flag.name, "--orphan")) i += 1;
            continue;
        }
        if (out.count < out.refs.len) out.refs[out.count] = arg;
        out.count += 1;
    }
    return out;
}

pub fn callGitWrite(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    event.label = "git_write";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try gitArgs(arena, args, null);
    if (argv.len != 0) event.file = argv[0];
    const force = if (args) |a| tool_result.getBool(a, "force") orelse false else false;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = render(arena, io, root, argv, force, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return tool_result.failure(gpa, &buffer, err, event);
    };
    return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = is_error };
}

pub fn wantsRead(sub: []const u8, args: ?Value) bool {
    if (args) |a| if (tool_result.getField(a, "args") != null) return true;
    for ([_][]const u8{ "status", "diff", "log", "show", "blame" }) |known| if (std.mem.eql(u8, sub, known)) return false;
    return true;
}

pub fn isReadSub(sub: []const u8) bool {
    return findSpec(&read_specs, sub) != null;
}

pub fn callRead(gpa: Allocator, io: std.Io, sub: []const u8, args: ?Value, event: *telemetry.Event, root: ?[]const u8, budget: usize) !ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = renderRead(arena, io, root, sub, args, budget, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return tool_result.failure(gpa, &buffer, err, event);
    };
    return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn renderRead(arena: Allocator, io: std.Io, root: ?[]const u8, sub: []const u8, args: ?Value, budget: usize, w: *Writer, event: *telemetry.Event) !bool {
    const argv = try gitArgs(arena, args, sub);
    const root_abs = try repo.servedRoot(arena, io, root);
    const git = try exe_path.git(arena, root_abs);
    var ok = switch (checkRead(argv)) {
        .refused => |why| {
            event.fail("GitReadRefused");
            try writeRefused(w, why.reason, why.arg);
            return true;
        },
        .ok => |ok| ok,
    };
    if (ok.lossy) {
        event.fail("GitReadRefused");
        try writeRefused(w, "not_read_only", argv[0]);
        return true;
    }
    if (try confine(arena, root_abs, &ok)) |why| {
        event.fail("GitReadRefused");
        try writeRefused(w, why.reason, why.arg);
        return true;
    }
    return runRead(arena, io, git, root_abs, &ok, argv, budget, w, event);
}

fn gitArgs(arena: Allocator, args: ?Value, sub: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (sub) |name| try list.append(arena, name);
    const object = args orelse return if (sub != null) list.items else error.MissingGitArgs;
    const field = tool_result.getField(object, "args") orelse return if (sub != null) list.items else error.MissingGitArgs;
    switch (field) {
        .array => |items| for (items.items) |item| switch (item) {
            .string => |s| try list.append(arena, s),
            .integer => |n| try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{n})),
            else => return error.InvalidGitArg,
        },
        .string => |s| try splitWords(arena, &list, s),
        .null => {},
        else => return error.MissingGitArgs,
    }
    if (list.items.len != 0 and std.mem.eql(u8, list.items[0], "git")) _ = list.orderedRemove(0);
    if (sub != null and list.items.len > 1 and std.mem.eql(u8, list.items[1], sub.?)) _ = list.orderedRemove(1);
    if (list.items.len == 0) return error.MissingGitArgs;
    if (list.items.len > max_args) return error.TooManyGitArgs;
    for (list.items) |a| if (std.mem.indexOfScalar(u8, a, 0) != null) return error.InvalidGitArg;
    return list.items;
}

fn splitWords(arena: Allocator, list: *std.ArrayList([]const u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i == text.len) break;
        var word: std.ArrayList(u8) = .empty;
        var quote: ?u8 = null;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (quote) |q| {
                if (c == q) quote = null else try word.append(arena, c);
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (std.ascii.isWhitespace(c)) {
                break;
            } else try word.append(arena, c);
        }
        try list.append(arena, word.items);
    }
}

fn gitEnv(arena: Allocator) !*std.process.Environ.Map {
    const env = try arena.create(std.process.Environ.Map);
    env.* = std.process.Environ.createMap(.{ .block = .global }, arena) catch return error.GitCommandFailed;
    for (dropped_env) |name| _ = env.swapRemove(name);
    for (forced_env) |pair| try env.put(pair[0], pair[1]);
    return env;
}

fn fullArgv(arena: Allocator, git: []const u8, lead: []const []const u8, ok: *const Ok, args: []const []const u8) ![]const []const u8 {
    var full: std.ArrayList([]const u8) = .empty;
    try full.append(arena, git);
    try full.appendSlice(arena, lead);
    try full.append(arena, args[0]);
    try full.appendSlice(arena, ok.spec.lead);
    if (ok.spec.default_rev and ok.npos_before == 0) {
        const at = ok.dashdash orelse args.len;
        try full.appendSlice(arena, args[1..at]);
        try full.append(arena, "HEAD");
        try full.appendSlice(arena, args[at..]);
    } else try full.appendSlice(arena, args[1..]);
    if (ok.spec.keep_workspace) {
        if (ok.dashdash == null) try full.append(arena, "--");
        try full.append(arena, workspace_exclude);
    }
    return full.items;
}

const Ran = struct {
    outcome: []const u8 = "exited",
    exit_code: ?u32 = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

fn runGit(arena: Allocator, io: std.Io, root_abs: []const u8, argv: []const []const u8, network: bool) !Ran {
    var ran: Ran = .{};
    const timeout_ms: u64 = if (network) network_timeout_ms else local_timeout_ms;
    if (bounded_run.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = root_abs },
        .environ_map = try gitEnv(arena),
        .stdout_limit = .limited(max_git_output),
        .stderr_limit = .limited(max_git_output),
        .timeout = bounded_run.timeoutMs(timeout_ms),
    })) |result| {
        ran.stdout = result.stdout;
        ran.stderr = result.stderr;
        switch (result.term) {
            .exited => |code| ran.exit_code = code,
            else => ran.outcome = "crashed",
        }
    } else |err| switch (err) {
        error.Timeout => ran.outcome = "timed_out",
        error.StreamTooLong => ran.outcome = "output_limit",
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GitCommandFailed,
    }
    return ran;
}

fn runRead(arena: Allocator, io: std.Io, git: []const u8, root_abs: []const u8, ok: *const Ok, args: []const []const u8, budget: usize, w: *Writer, event: *telemetry.Event) !bool {
    const ran = try runGit(arena, io, root_abs, try fullArgv(arena, git, &read_prefix, ok, args), ok.spec.network);
    const code = ran.exit_code;
    const failed = code == null or (code.? != 0 and (code.? > 1 or std.mem.trim(u8, ran.stderr, " \r\n").len != 0));
    if (failed) event.fail("GitCommandFailed");
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write(if (failed) "failed" else "ok");
    try writeOutcome(&js, ran);
    const output = try headOf(arena, ran.stdout, ran.stderr, @max(budget, 512));
    if (output.len != 0) {
        try js.objectField("output");
        try js.write(output);
    }
    try js.endObject();
    try w.writeByte('\n');
    return failed;
}

fn writeOutcome(js: *std.json.Stringify, ran: Ran) !void {
    if (!std.mem.eql(u8, ran.outcome, "exited")) {
        try js.objectField("outcome");
        try js.write(ran.outcome);
    }
    if (ran.exit_code) |code| if (code != 0) {
        try js.objectField("exit_code");
        try js.write(code);
    };
}

fn render(arena: Allocator, io: std.Io, root: ?[]const u8, args: []const []const u8, force: bool, w: *Writer, event: *telemetry.Event) !bool {
    const root_abs = try repo.servedRoot(arena, io, root);
    const git = try exe_path.git(arena, root_abs);
    var ok = switch (check(args)) {
        .refused => |why| {
            event.fail("GitWriteRefused");
            try writeRefused(w, why.reason, why.arg);
            return true;
        },
        .ok => |ok| ok,
    };
    if (try confine(arena, root_abs, &ok)) |why| {
        event.fail("GitWriteRefused");
        try writeRefused(w, why.reason, why.arg);
        return true;
    }
    var lossy = ok.lossy;
    if (std.mem.eql(u8, ok.spec.sub, "checkout") and !lossy) lossy = try checkoutLosesWork(arena, io, git, root_abs, args);
    if (lossy and !force) {
        event.fail("WouldLoseWork");
        try writeRefused(w, "would_lose_work", args[0]);
        return true;
    }
    if (ok.spec.read) return runRead(arena, io, git, root_abs, &ok, args, max_read_bytes, w, event);

    const lock = try shadow.Lock.acquire(io, root_abs);
    defer lock.release();

    const before = try headOid(arena, io, git, root_abs);
    const ran = try runGit(arena, io, root_abs, try fullArgv(arena, git, &prefix, &ok, args), ok.spec.network);
    const after = try headOid(arena, io, git, root_abs);
    const branch = try capture(arena, io, git, root_abs, &.{ "branch", "--show-current" });
    var shortstat: ?[]const u8 = null;
    if (before != null and after != null and !std.mem.eql(u8, before.?, after.?)) {
        shortstat = try capture(arena, io, git, root_abs, &.{ "diff", "--shortstat", before.?, after.? });
    }

    const failed = ran.exit_code == null or ran.exit_code.? != 0;
    if (failed) event.fail("GitCommandFailed");
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write(if (failed) "failed" else "ok");
    try writeOutcome(&js, ran);
    if (after) |oid| {
        try js.objectField("head");
        try js.write(oid);
    }
    if (branch) |name| if (name.len != 0) {
        try js.objectField("branch");
        try js.write(name);
    };
    if (shortstat) |stat| if (stat.len != 0) {
        try js.objectField("from");
        try js.write(before.?);
        try js.objectField("shortstat");
        try js.write(stat);
    };
    const output = try tail(arena, ran.stdout, ran.stderr);
    if (output.len != 0) {
        try js.objectField("output");
        try js.write(output);
    }
    try js.endObject();
    try w.writeByte('\n');
    return failed;
}

fn checkoutLosesWork(arena: Allocator, io: std.Io, git: []const u8, root_abs: []const u8, args: []const []const u8) !bool {
    const targets = checkoutTargets(args);
    if (targets.paths or targets.count > 1) return true;
    if (targets.count == 0) return false;
    const spec = try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{targets.refs[0].?});
    const resolved = try capture(arena, io, git, root_abs, &.{ "rev-parse", "--verify", "--quiet", "--end-of-options", spec });
    if (resolved != null) return false;
    const remote = try capture(arena, io, git, root_abs, &.{ "for-each-ref", "--count=1", "--format=%(refname)", try std.fmt.allocPrint(arena, "refs/remotes/*/{s}", .{targets.refs[0].?}) });
    return remote == null or remote.?.len == 0;
}

fn headOid(arena: Allocator, io: std.Io, git: []const u8, root_abs: []const u8) !?[]const u8 {
    return capture(arena, io, git, root_abs, &.{ "rev-parse", "--verify", "--quiet", "HEAD" });
}

fn capture(arena: Allocator, io: std.Io, git: []const u8, root_abs: []const u8, args: []const []const u8) !?[]const u8 {
    var full: std.ArrayList([]const u8) = .empty;
    try full.appendSlice(arena, &.{ git, "-c", "core.fsmonitor=false", "--no-optional-locks", "--no-pager" });
    try full.appendSlice(arena, args);
    const result = bounded_run.run(arena, io, .{
        .argv = full.items,
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (result.term) {
        .exited => |code| if (code == 0) std.mem.trim(u8, result.stdout, " \r\n") else null,
        else => null,
    };
}

fn joinOutput(arena: Allocator, stdout: []const u8, stderr: []const u8) ![]const u8 {
    return std.mem.trim(u8, try std.mem.concat(arena, u8, &.{ std.mem.trim(u8, stdout, "\r\n"), if (stdout.len != 0 and stderr.len != 0) "\n" else "", std.mem.trim(u8, stderr, "\r\n") }), "\r\n");
}

fn tail(arena: Allocator, stdout: []const u8, stderr: []const u8) ![]const u8 {
    const text = try joinOutput(arena, stdout, stderr);
    var start = text.len;
    var lines: usize = 0;
    while (start > 0) {
        const prev = std.mem.lastIndexOfScalar(u8, text[0 .. start - 1], '\n');
        const next_start = if (prev) |p| p + 1 else 0;
        if (lines == max_output_lines or text.len - next_start > max_output_bytes) break;
        start = next_start;
        lines += 1;
        if (prev == null) break;
    }
    if (start == 0) return text;
    const left = std.mem.count(u8, text[0..start], "\n");
    return std.fmt.allocPrint(arena, "[{d} earlier lines left out]\n{s}", .{ left, text[start..] });
}

fn headOf(arena: Allocator, stdout: []const u8, stderr: []const u8, max_bytes: usize) ![]const u8 {
    const text = try joinOutput(arena, stdout, stderr);
    var end: usize = 0;
    var lines: usize = 0;
    while (end < text.len) {
        const next = if (std.mem.indexOfScalarPos(u8, text, end, '\n')) |nl| nl + 1 else text.len;
        if (lines == max_read_lines or next > max_bytes) break;
        end = next;
        lines += 1;
    }
    if (end == text.len) return text;
    const left = std.mem.count(u8, text[end..], "\n") + 1;
    return std.fmt.allocPrint(arena, "{s}[{d} more lines left out]", .{ text[0..end], left });
}

fn writeRefused(w: *Writer, reason: []const u8, arg: []const u8) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write("refused");
    try js.objectField("reason");
    try js.write(reason);
    if (arg.len != 0) {
        try js.objectField("arg");
        try js.write(arg);
    }
    try js.objectField("fix");
    try js.write(fixFor(reason));
    try js.endObject();
    try w.writeByte('\n');
}

fn fixFor(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "would_lose_work")) return "this discards uncommitted work or rewrites a remote; pass force:true only when the user asked for exactly that";
    if (std.mem.eql(u8, reason, "unsupported_subcommand")) return "args[0] is one of " ++ sub_list;
    if (std.mem.eql(u8, reason, "missing_value")) return "give the flag its value as the next element or as --flag=value";
    if (std.mem.eql(u8, reason, "outside_root")) return "paths, clone targets and local remotes must be inside the served root";
    if (std.mem.eql(u8, reason, "unsupported_url")) return "use an https, ssh or git URL; a transport helper (::) does not run";
    if (std.mem.eql(u8, reason, "unsupported_config_key")) return "writable keys: " ++ config_list;
    if (std.mem.eql(u8, reason, "unsupported_value")) return "the strategy is one of ort, recursive, resolve, octopus, ours, subtree";
    if (std.mem.eql(u8, reason, "not_read_only")) return "this form changes the repository; run it with emetgate_git_write";
    if (std.mem.eql(u8, reason, "too_many_args")) return "give at most 32 arguments";
    return "use a supported flag; file edits go through the gate";
}

const sub_list = blk: {
    var text: []const u8 = "";
    for (all_specs, 0..) |spec, i| text = text ++ (if (i == 0) "" else ", ") ++ spec.sub;
    break :blk text;
};

const config_list = blk: {
    var text: []const u8 = "";
    for (config_keys) |key| text = text ++ key ++ ", ";
    for (config_sub_keys) |key| {
        const dot = std.mem.indexOfScalar(u8, key, '.').?;
        text = text ++ key[0..dot] ++ ".<name>" ++ key[dot..] ++ ", ";
    }
    break :blk text[0 .. text.len - 2];
};

const testing = std.testing;

fn expectReason(args: []const []const u8, reason: []const u8) !void {
    switch (check(args)) {
        .refused => |why| try testing.expectEqualStrings(reason, why.reason),
        .ok => return error.TestExpectedRefusal,
    }
}

fn expectLossy(args: []const []const u8, lossy: bool) !void {
    switch (check(args)) {
        .refused => |why| {
            std.debug.print("refused {s} {s}\n", .{ why.reason, why.arg });
            return error.TestUnexpectedRefusal;
        },
        .ok => |ok| try testing.expectEqual(lossy, ok.lossy),
    }
}

fn expectConfined(args: []const []const u8, reason: ?[]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const ok = switch (check(args)) {
        .refused => |why| {
            std.debug.print("refused {s} {s}\n", .{ why.reason, why.arg });
            return error.TestUnexpectedRefusal;
        },
        .ok => |ok| ok,
    };
    const why = try confine(arena_state.allocator(), "C:\\work\\repo", &ok);
    if (reason) |expected| {
        try testing.expect(why != null);
        try testing.expectEqualStrings(expected, why.?.reason);
    } else if (why) |got| {
        std.debug.print("confined {s} {s}\n", .{ got.reason, got.arg });
        return error.TestUnexpectedRefusal;
    }
}

test "git write accepts the local workflow and marks only work-losing forms" {
    try expectLossy(&.{ "switch", "-c", "release-11.3.0" }, false);
    try expectLossy(&.{ "branch", "feature" }, false);
    try expectLossy(&.{ "tag", "-a", "v1", "-m", "release" }, false);
    try expectLossy(&.{ "stash", "push", "-m", "wip" }, false);
    try expectLossy(&.{ "stash", "pop" }, false);
    try expectLossy(&.{ "commit", "-m", "Bump version to 11.3.0" }, false);
    try expectLossy(&.{ "merge", "--no-ff", "feature" }, false);
    try expectLossy(&.{ "rebase", "main" }, false);
    try expectLossy(&.{ "cherry-pick", "abc1234" }, false);
    try expectLossy(&.{ "restore", "--staged", "a.txt" }, false);
    try expectLossy(&.{ "reset", "--soft", "HEAD~1" }, false);
    try expectLossy(&.{ "push", "-u", "origin", "feature" }, false);
    try expectLossy(&.{ "reset", "--hard", "HEAD" }, true);
    try expectLossy(&.{ "restore", "a.txt" }, true);
    try expectLossy(&.{ "restore", "--staged", "--worktree", "a.txt" }, true);
    try expectLossy(&.{ "stash", "drop" }, true);
    try expectLossy(&.{ "branch", "-D", "feature" }, true);
    try expectLossy(&.{ "switch", "--discard-changes", "main" }, true);
    try expectLossy(&.{ "push", "--force", "origin", "main" }, true);
    try expectLossy(&.{ "push", "origin", "+main" }, true);
}

test "git write refuses execution and config flags and unknown subcommands" {
    try expectReason(&.{ "rebase", "-x", "calc.exe", "main" }, "unsupported_flag");
    try expectReason(&.{ "rebase", "--exec=calc.exe", "main" }, "unsupported_flag");
    try expectReason(&.{ "fetch", "--upload-pack=calc.exe", "origin" }, "unsupported_flag");
    try expectReason(&.{ "commit", "--no-verify", "-m", "x" }, "unsupported_flag");
    try expectReason(&.{ "clean", "-i" }, "unsupported_flag");
    try expectReason(&.{ "gc", "--prune=now" }, "unsupported_subcommand");
    try expectReason(&.{ "stash", "nuke" }, "unsupported_action");
    try expectReason(&.{ "commit", "-m" }, "missing_value");
}

test "a commit message that looks like a flag is a value, not a flag" {
    try expectLossy(&.{ "commit", "-m", "--hard" }, false);
    try expectLossy(&.{ "tag", "-m", "-f", "v2" }, false);
}

test "checkout targets separate a branch switch from a path checkout" {
    const branch = checkoutTargets(&.{ "checkout", "-b", "new", "main" });
    try testing.expectEqual(@as(usize, 1), branch.count);
    try testing.expectEqualStrings("main", branch.refs[0].?);
    try testing.expect(!branch.paths);
    const paths = checkoutTargets(&.{ "checkout", "HEAD", "--", "a.txt" });
    try testing.expect(paths.paths);
}

test "git write reads short flag clusters, attached values and counts flag by flag" {
    try expectLossy(&.{ "commit", "-am", "msg" }, false);
    try expectLossy(&.{ "clean", "-fd" }, true);
    try expectLossy(&.{ "clean", "-nd" }, false);
    try expectLossy(&.{ "clean", "-d" }, true);
    try expectLossy(&.{ "rm", "-rf", "dir" }, true);
    try expectLossy(&.{ "apply", "-p1", "fix.patch" }, false);
    try expectLossy(&.{ "log", "-5", "--oneline" }, false);
    try expectLossy(&.{ "diff", "-U1", "HEAD~1" }, false);
    try expectLossy(&.{ "tag", "-n5" }, false);
    try expectReason(&.{ "clean", "-fdi" }, "unsupported_flag");
    try expectReason(&.{ "grep", "-O", "x" }, "unsupported_flag");
    try expectReason(&.{ "commit", "-am" }, "missing_value");
    try expectLossy(&.{ "commit", "-mfix" }, false);
    try expectReason(&.{ "branch", "-5" }, "unsupported_flag");
}

test "git write marks the new destructive forms as work-losing" {
    try expectLossy(&.{ "worktree", "add", "-b", "x", "wt" }, false);
    try expectLossy(&.{ "worktree", "remove", "wt" }, true);
    try expectLossy(&.{ "worktree", "add", "-B", "x", "wt" }, true);
    try expectLossy(&.{ "remote", "add", "up", "https://example.com/r.git" }, false);
    try expectLossy(&.{ "remote", "remove", "up" }, true);
    try expectLossy(&.{ "submodule", "update", "--init", "--recursive" }, false);
    try expectLossy(&.{ "submodule", "deinit", "lib" }, true);
    try expectLossy(&.{ "reflog", "HEAD" }, false);
    try expectLossy(&.{ "reflog", "expire", "--expire=now", "--all" }, true);
    try expectLossy(&.{ "bisect", "start", "HEAD", "HEAD~3" }, false);
    try expectReason(&.{ "bisect", "run", "make" }, "unsupported_action");
    try expectReason(&.{ "submodule", "foreach", "rm -rf ." }, "unsupported_action");
    try expectReason(&.{ "merge", "-s", "evil", "x" }, "unsupported_value");
    try expectLossy(&.{ "merge", "-s", "ours", "x" }, false);
    try expectLossy(&.{ "rebase", "-i", "--autosquash", "main" }, false);
}

test "git write keeps paths, clone targets, local remotes and config keys inside the root" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try expectConfined(&.{ "init", "sub" }, null);
    try expectConfined(&.{ "init", "..\\elsewhere" }, "outside_root");
    try expectConfined(&.{ "init", ".git\\x" }, "outside_root");
    try expectConfined(&.{ "clone", "https://example.com/r.git", "vendor/r" }, null);
    try expectConfined(&.{ "clone", "git@github.com:o/r.git" }, null);
    try expectConfined(&.{ "clone", "C:\\other\\repo", "r" }, "outside_root");
    try expectConfined(&.{ "clone", "file:///C:/other/repo" }, "outside_root");
    try expectConfined(&.{ "clone", "ext::sh -c calc", "r" }, "unsupported_url");
    try expectConfined(&.{ "clone", "https://example.com/r.git", "C:\\elsewhere" }, "outside_root");
    try expectConfined(&.{ "fetch", "origin" }, null);
    try expectConfined(&.{ "fetch", "..\\..\\other" }, "outside_root");
    try expectConfined(&.{ "remote", "add", "up", "..\\..\\other" }, "outside_root");
    try expectConfined(&.{ "remote", "set-url", "origin", "https://example.com/r.git" }, null);
    try expectConfined(&.{ "worktree", "add", "wt", "main" }, null);
    try expectConfined(&.{ "worktree", "add", "..\\wt" }, "outside_root");
    try expectConfined(&.{ "apply", "C:\\Users\\x\\secret.patch" }, "outside_root");
    try expectConfined(&.{ "format-patch", "-o", "..\\out", "-1" }, "outside_root");
    try expectConfined(&.{ "format-patch", "--output-directory=patches", "-1" }, null);
    try expectConfined(&.{ "config", "user.email", "a@b.c" }, null);
    try expectConfined(&.{ "config", "--get", "core.hooksPath" }, null);
    try expectConfined(&.{ "config", "core.hooksPath", "x" }, "unsupported_config_key");
    try expectConfined(&.{ "config", "set", "core.sshCommand", "calc" }, "unsupported_config_key");
    try expectConfined(&.{ "config", "--add", "alias.x", "!calc" }, "unsupported_config_key");
    try expectConfined(&.{ "config", "Remote.Origin.URL", "ext::calc" }, "unsupported_url");
    try expectConfined(&.{ "config", "branch.main.remote", "origin" }, null);
    try expectConfined(&.{ "config", "edit" }, "unsupported_action");
}

test "git read table holds only read-only forms" {
    switch (checkRead(&.{ "commit", "-m", "x" })) {
        .refused => |why| try testing.expectEqualStrings("unsupported_subcommand", why.reason),
        .ok => return error.TestExpectedRefusal,
    }
    for (read_specs) |spec| try testing.expect(spec.read);
    for (write_specs) |spec| try testing.expect(!spec.read);
}
