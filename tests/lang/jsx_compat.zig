const std = @import("std");
const registry = @import("emetgate").lang_registry;
const Profile = @import("emetgate").lang_profile.Profile;
const symbol = @import("emetgate").symbol;
const Runtime = @import("emetgate").runtime.Runtime;
const Snapshot = @import("emetgate").loader.Snapshot;

const testing = std.testing;

fn profileNamed(name: []const u8) *const Profile {
    for (registry.profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return profile;
    }
    @panic("profile not registered");
}

fn symbolCount(profile: *const Profile, source: []const u8) !usize {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const snapshot = try Snapshot.fromSource(runtime, profile, try testing.allocator.dupe(u8, source));
    defer snapshot.destroy();
    try testing.expect(!snapshot.tree.root().hasError());
    const table = try snapshot.symbols();
    return table.symbols.len;
}

const jsx_sources = [_][]const u8{
    "javascript",
    "tsx",
};

const function_returning_jsx =
    \\function Greeting(name) {
    \\  // a plain comment before the element
    \\  return <div className="box">Hello, {name}</div>;
    \\}
    \\
;

const component_function =
    \\function Card(props) {
    \\  return (
    \\    <div>
    \\      {/* a JSX comment inside the tree */}
    \\      <span>{"quoted string inside jsx"}</span>
    \\    </div>
    \\  );
    \\}
    \\
;

const arrow_component =
    \\const Label = (text) => <span title="hover text">{text}</span>;
    \\
;

test "jsx: a function returning a JSX element is a plain function symbol" {
    for (jsx_sources) |name| {
        errdefer std.debug.print("profile: {s}\n", .{name});
        const profile = profileNamed(name);
        try testing.expectEqual(@as(usize, 1), try symbolCount(profile, function_returning_jsx));
    }
}

test "jsx: a component function with a JSX comment and a nested string element parses cleanly" {
    for (jsx_sources) |name| {
        errdefer std.debug.print("profile: {s}\n", .{name});
        const profile = profileNamed(name);
        try testing.expectEqual(@as(usize, 1), try symbolCount(profile, component_function));
    }
}

test "jsx: an arrow function component is classified as an arrow symbol" {
    for (jsx_sources) |name| {
        errdefer std.debug.print("profile: {s}\n", .{name});
        const profile = profileNamed(name);
        const runtime = try Runtime.create(testing.allocator);
        defer runtime.destroy() catch @panic("live snapshots");
        const snapshot = try Snapshot.fromSource(runtime, profile, try testing.allocator.dupe(u8, arrow_component));
        defer snapshot.destroy();
        try testing.expect(!snapshot.tree.root().hasError());

        const ref = try symbol.Ref.parse(testing.allocator, "Label");
        defer ref.deinit(testing.allocator);
        const table = try snapshot.symbols();
        const found = try table.resolve(ref);
        try testing.expectEqual(symbol.Kind.arrow, found.kind);
    }
}
