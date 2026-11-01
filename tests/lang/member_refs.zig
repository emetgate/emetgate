const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const cas = emetgate.cas;
const facts = emetgate.facts;
const facts_extract = emetgate.facts_extract;
const handlers = emetgate.handlers;
const skeleton = emetgate.skeleton;
const symbol = emetgate.symbol;
const telemetry = emetgate.telemetry;
const registry = emetgate.lang_registry;
const Profile = emetgate.lang_profile.Profile;
const Snapshot = emetgate.loader.Snapshot;
const Runtime = emetgate.runtime.Runtime;
const fixture = @import("../ts_fixture.zig");

const testing = std.testing;
const Value = std.json.Value;

const python = registry.forPath("a.py").?;
const csharp = registry.forPath("a.cs").?;
const typescript = registry.forPath("a.ts").?;

const Open = struct {
    runtime: *Runtime,
    snapshot: *Snapshot,

    fn init(profile: *const Profile, source: []const u8) !Open {
        const runtime = try Runtime.create(testing.allocator);
        errdefer runtime.destroy() catch @panic("live snapshots");
        return .{ .runtime = runtime, .snapshot = try Snapshot.fromSource(runtime, profile, try testing.allocator.dupe(u8, source)) };
    }

    fn deinit(self: Open) void {
        self.snapshot.destroy();
        self.runtime.destroy() catch @panic("live snapshots");
    }
};

const Member = struct { ref: []const u8, kind: symbol.Kind };

fn expectSymbols(profile: *const Profile, source: []const u8, expected: []const Member) !void {
    const open = try Open.init(profile, source);
    defer open.deinit();
    const table = try open.snapshot.symbols();
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (table.symbols) |entry| try writer.print("{f} {t}{s}\n", .{ entry.ref, entry.kind, if (entry.ambiguous) " ambiguous" else "" });
    var want: [2048]u8 = undefined;
    var want_writer: std.Io.Writer = .fixed(&want);
    for (expected) |entry| try want_writer.print("{s} {t}\n", .{ entry.ref, entry.kind });
    try testing.expectEqualStrings(want_writer.buffered(), writer.buffered());
}

fn textOf(open: Open, ref_text: []const u8) ![]const u8 {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    const found = try (try open.snapshot.symbols()).item(ref);
    const node = found.body orelse found.node;
    return open.snapshot.source[node.startByte()..node.endByte()];
}

fn edit(open: Open, ref_text: []const u8, body: []const u8) !cas.Applied {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    const found = try (try open.snapshot.symbols()).item(ref);
    return cas.apply(open.snapshot, .{ .ref = ref, .expected_hash = found.hash, .new_body = body });
}

fn expectEdit(profile: *const Profile, source: []const u8, ref_text: []const u8, body: []const u8, expected: []const u8) !void {
    const open = try Open.init(profile, source);
    defer open.deinit();
    const applied = try edit(open, ref_text, body);
    defer applied.snapshot.destroy();
    try testing.expectEqualStrings(expected, applied.snapshot.source);
    try testing.expect(!applied.snapshot.tree.root().hasError());
}

fn expectStable(profile: *const Profile, source: []const u8, ref_text: []const u8, shown: []const u8) !void {
    const open = try Open.init(profile, source);
    defer open.deinit();
    const before = try textOf(open, ref_text);
    try testing.expectEqualStrings(shown, before);
    const applied = try edit(open, ref_text, before);
    defer applied.snapshot.destroy();
    try testing.expectEqualStrings(source, applied.snapshot.source);
}

fn expectAmbiguous(profile: *const Profile, source: []const u8, ref_text: []const u8, expected: []const []const u8) !void {
    const open = try Open.init(profile, source);
    defer open.deinit();
    const table = try open.snapshot.symbols();
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    try testing.expectError(error.AmbiguousSymbol, table.item(ref));
    const candidates = try table.candidates(testing.allocator, ref);
    defer testing.allocator.free(candidates);
    try testing.expectEqual(expected.len, candidates.len);
    for (candidates, expected) |candidate, want| try testing.expectFmt(want, "{f}", .{candidate.ref});
}

const python_members =
    \\from typing import overload
    \\
    \\def outer(x):
    \\    def inner(y):
    \\        return y
    \\    return inner(x)
    \\
    \\class A:
    \\    limit: int = 0
    \\
    \\    def __init__(self):
    \\        self.n = 1
    \\
    \\    @overload
    \\    def f(self, a: int) -> int: ...
    \\
    \\    @overload
    \\    def f(self, a: str) -> str: ...
    \\
    \\    def f(self, a):
    \\        return a
    \\
    \\    @property
    \\    def size(self):
    \\        return 1
    \\
    \\    @size.setter
    \\    def size(self, v):
    \\        self.n = v
    \\
    \\    @size.deleter
    \\    def size(self):
    \\        del self.n
    \\
    \\    @staticmethod
    \\    def make():
    \\        return A()
    \\
;

test "member refs: every Python member gets its own ref and its real kind" {
    try expectSymbols(python, python_members, &.{
        .{ .ref = "outer", .kind = .function },
        .{ .ref = "outer.inner", .kind = .function },
        .{ .ref = "A.__init__", .kind = .constructor },
        .{ .ref = "A.f(int)", .kind = .method },
        .{ .ref = "A.f(str)", .kind = .method },
        .{ .ref = "A.f", .kind = .method },
        .{ .ref = "A.size@get", .kind = .getter },
        .{ .ref = "A.size@set", .kind = .setter },
        .{ .ref = "A.size@delete", .kind = .method },
        .{ .ref = "A.make@static", .kind = .method },
    });
}

test "member refs: a Python overload stub and the implementation are edited apart" {
    const open = try Open.init(python, python_members);
    defer open.deinit();
    const applied = try edit(open, "A.f", "return [a]");
    defer applied.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, applied.snapshot.source, "    def f(self, a):\n        return [a]\n") != null);
    try testing.expect(std.mem.indexOf(u8, applied.snapshot.source, "def f(self, a: int) -> int: ...\n") != null);
    const stub = try edit(open, "A.f(int)", "return 0");
    defer stub.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, stub.snapshot.source, "def f(self, a: int) -> int: return 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, stub.snapshot.source, "def f(self, a: str) -> str: ...\n") != null);
}

test "member refs: a Python deleter is read and edited without touching its getter and setter" {
    const open = try Open.init(python, python_members);
    defer open.deinit();
    try testing.expectEqualStrings("del self.n", try textOf(open, "A.size@delete"));
    const applied = try edit(open, "A.size@delete", "self.n = 0");
    defer applied.snapshot.destroy();
    const after = applied.snapshot.source;
    try testing.expect(std.mem.indexOf(u8, after, "    @size.deleter\n    def size(self):\n        self.n = 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, after, "    def size(self, v):\n        self.n = v\n") != null);
}

test "member refs: a Python class field is read and replaced through its ref" {
    const open = try Open.init(python, python_members);
    defer open.deinit();
    try testing.expectEqualStrings("limit: int = 0", try textOf(open, "A.limit"));
    const applied = try edit(open, "A.limit", "limit: int = 9");
    defer applied.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, applied.snapshot.source, "    limit: int = 9\n") != null);
}

const csharp_members =
    \\namespace Shop;
    \\
    \\public class Box
    \\{
    \\    private int[] data = new int[3];
    \\    public Box(int n) { data[0] = n; }
    \\    public int this[int i] { get => data[i]; set => data[i] = value; }
    \\    public string this[string k] => k;
    \\    public event EventHandler Changed { add { } remove { } }
    \\    public static Box operator +(Box a, Box b) => a;
    \\    public static explicit operator int(Box a) => 0;
    \\    public int Area => data[0] * 2;
    \\    public int Width { get; set; }
    \\    public void Add(int a) { }
    \\    public void Add(string a) { }
    \\    int IComparable.CompareTo(object o) { return 0; }
    \\    public static Box Empty() => new Box(0);
    \\    ~Box() { }
    \\}
    \\
;

test "member refs: every C# member gets a ref, overloads apart" {
    try expectSymbols(csharp, csharp_members, &.{
        .{ .ref = "Shop.Box.Box", .kind = .constructor },
        .{ .ref = "Shop.Box.this(int)@get", .kind = .getter },
        .{ .ref = "Shop.Box.this@set", .kind = .setter },
        .{ .ref = "Shop.Box.this(string)@get", .kind = .getter },
        .{ .ref = "Shop.Box.Changed@add", .kind = .method },
        .{ .ref = "Shop.Box.Changed@remove", .kind = .method },
        .{ .ref = "Shop.Box.operator+@static", .kind = .method },
        .{ .ref = "Shop.Box.operator int@static", .kind = .method },
        .{ .ref = "Shop.Box.Area@get", .kind = .getter },
        .{ .ref = "Shop.Box.Add(int)", .kind = .method },
        .{ .ref = "Shop.Box.Add(string)", .kind = .method },
        .{ .ref = "Shop.Box.IComparable.CompareTo", .kind = .method },
        .{ .ref = "Shop.Box.Empty@static", .kind = .method },
        .{ .ref = "Shop.Box.~Box", .kind = .method },
    });
}

test "member refs: each C# member reads as the body it was declared with and writes back byte for byte" {
    for ([_][2][]const u8{
        .{ "Shop.Box.Area@get", "=> data[0] * 2" },
        .{ "Box.Area", "=> data[0] * 2" },
        .{ "Box.this(int)@get", "=> data[i]" },
        .{ "Box.this@set", "=> data[i] = value" },
        .{ "Box.this(int)@set", "=> data[i] = value" },
        .{ "Box.this(string)", "=> k" },
        .{ "Box.Changed@add", "{ }" },
        .{ "Box.operator+", "=> a" },
        .{ "Box.operator int", "=> 0" },
        .{ "Box.~Box", "{ }" },
        .{ "Box.Add(int)", "{ }" },
        .{ "Empty", "=> new Box(0)" },
    }) |pair| {
        errdefer std.debug.print("ref {s}\n", .{pair[0]});
        try expectStable(csharp, csharp_members, pair[0], pair[1]);
    }
}

test "member refs: a C# method body moves between => and a block in both directions" {
    const arrow = "class C\n{\n    int F() => 1;\n    int G() { return 2; }\n}\n";
    try expectEdit(csharp, arrow, "C.F", "{ return 3; }", "class C\n{\n    int F() { return 3; }\n    int G() { return 2; }\n}\n");
    try expectEdit(csharp, arrow, "C.G", "=> 4", "class C\n{\n    int F() => 1;\n    int G() => 4;\n}\n");
    try expectEdit(csharp, arrow, "C.F", "=> 5;", "class C\n{\n    int F() => 5;\n    int G() { return 2; }\n}\n");
    try expectEdit(csharp, "class C\n{\n    int P { get => 1; }\n}\n", "C.P@get", "{ return 2; }", "class C\n{\n    int P { get { return 2; } }\n}\n");
    try expectEdit(csharp, "class C\n{\n    int P { get { return 1; } }\n}\n", "C.P@get", "=> 2", "class C\n{\n    int P { get => 2; }\n}\n");
}

test "member refs: an expression bodied C# property takes a whole new declaration" {
    try expectEdit(csharp, "class C\n{\n    int P => 1;\n}\n", "C.P", "int P { get; set; }", "class C\n{\n    int P { get; set; }\n}\n");
    try expectEdit(csharp, "class C\n{\n    int P => 1;\n}\n", "C.P@get", "int P { get; set; }", "class C\n{\n    int P { get; set; }\n}\n");
    try expectEdit(csharp, "class C\n{\n    int P => 1;\n}\n", "C.P", "=> 2", "class C\n{\n    int P => 2;\n}\n");
    try expectEdit(csharp, "class C\n{\n    int P { get; set; }\n}\n", "C.P", "int P => 1;", "class C\n{\n    int P => 1;\n}\n");
}

test "member refs: a lone C# method answers to its bare ref and its overload ref alike" {
    const open = try Open.init(csharp, "class C\n{\n    void F(int a) { }\n}\n");
    defer open.deinit();
    try testing.expectEqualStrings("{ }", try textOf(open, "C.F"));
    const edited = try edit(open, "C.F(int)", "{ a++; }");
    defer edited.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, edited.snapshot.source, "void F(int a) { a++; }") != null);
}

test "member refs: a new C# overload joins through its own ref and both stay addressable" {
    const open = try Open.init(csharp, "class C\n{\n    void F(int a) { }\n}\n");
    defer open.deinit();
    const ref = try symbol.Ref.parse(testing.allocator, "C.F(string)");
    defer ref.deinit(testing.allocator);
    const added = try cas.propose(open.snapshot, ref, .absent, "void F(string a) { }");
    defer added.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, added.snapshot.source, "void F(string a) { }") != null);
    const after = Open{ .runtime = open.runtime, .snapshot = added.snapshot };
    try testing.expectEqualStrings("{ }", try textOf(after, "C.F(int)"));
    try testing.expectEqualStrings("{ }", try textOf(after, "C.F(string)"));
    const bare = try symbol.Ref.parse(testing.allocator, "C.F");
    defer bare.deinit(testing.allocator);
    try testing.expectError(error.AmbiguousSymbol, (try added.snapshot.symbols()).item(bare));
}

test "member refs: overloads that differ only in generics or parameter shape stay apart" {
    try expectSymbols(csharp,
        \\class C
        \\{
        \\    void F<T>(List<T> a) { }
        \\    void F(List<int> a) { }
        \\    void F(int a, string b = "x") { }
        \\    void F(params int[] a) { }
        \\}
        \\
    , &.{
        .{ .ref = "C.F<T>(List<T>)", .kind = .method },
        .{ .ref = "C.F(List<int>)", .kind = .method },
        .{ .ref = "C.F(int,string)", .kind = .method },
        .{ .ref = "C.F(params int[])", .kind = .method },
    });
}

const two_classes =
    \\namespace Shop
    \\{
    \\    public class Cart
    \\    {
    \\        public static int Count() { return 0; }
    \\        public void Clear() { }
    \\        public void Twice(int a) { }
    \\        public void Twice(string a) { }
    \\    }
    \\    public class Store
    \\    {
    \\        public void Clear() { }
    \\    }
    \\}
    \\
;

test "member refs: a short C# ref reaches the one member it can mean" {
    const open = try Open.init(csharp, two_classes);
    defer open.deinit();
    for ([_][]const u8{ "Count", "Count@static", "Cart.Count", "Shop.Cart.Count", "Shop.Cart.Count@static" }) |short| {
        errdefer std.debug.print("ref {s}\n", .{short});
        try testing.expectEqualStrings("{ return 0; }", try textOf(open, short));
    }
    const applied = try edit(open, "Cart.Clear", "{ int a = 0; }");
    defer applied.snapshot.destroy();
    try testing.expect(std.mem.indexOf(u8, applied.snapshot.source, "public void Clear() { int a = 0; }\n        public void Twice(int a)") != null);
}

test "member refs: an ambiguous short C# ref lists every member it could mean" {
    try expectAmbiguous(csharp, two_classes, "Clear", &.{ "Shop.Cart.Clear", "Shop.Store.Clear" });
    try expectAmbiguous(csharp, two_classes, "Cart.Twice", &.{ "Shop.Cart.Twice(int)", "Shop.Cart.Twice(string)" });
    try expectAmbiguous(csharp, two_classes, "Twice", &.{ "Shop.Cart.Twice(int)", "Shop.Cart.Twice(string)" });
}

test "member refs: a short ref that names nothing stays not found" {
    const open = try Open.init(csharp, two_classes);
    defer open.deinit();
    const table = try open.snapshot.symbols();
    for ([_][]const u8{ "Missing", "Store.Count", "Other.Cart.Clear", "Cart.Twice(bool)", "Count@get" }) |text| {
        const ref = try symbol.Ref.parse(testing.allocator, text);
        defer ref.deinit(testing.allocator);
        errdefer std.debug.print("ref {s}\n", .{text});
        try testing.expectError(error.SymbolNotFound, table.item(ref));
    }
}

test "member refs: a short Python ref leaves off @static and its accessor only where one member fits" {
    {
        const open = try Open.init(python, python_members);
        defer open.deinit();
        try testing.expectEqualStrings("return A()", try textOf(open, "A.make"));
        try testing.expectEqualStrings("return A()", try textOf(open, "make"));
    }
    try expectAmbiguous(python, python_members, "A.size", &.{ "A.size@get", "A.size@set", "A.size@delete" });
}

test "member refs: TypeScript keeps asking for its whole ref" {
    const open = try Open.init(typescript, "class A {\n  static f() { return 1; }\n}\n");
    defer open.deinit();
    const table = try open.snapshot.symbols();
    for ([_][]const u8{ "f", "A.f" }) |text| {
        const ref = try symbol.Ref.parse(testing.allocator, text);
        defer ref.deinit(testing.allocator);
        try testing.expectError(error.SymbolNotFound, table.item(ref));
    }
}

fn expectSkeleton(profile: *const Profile, source: []const u8, expected: []const u8) !void {
    const open = try Open.init(profile, source);
    defer open.deinit();
    const parser = open.runtime.parser;
    const text = try skeleton.skeletonize(testing.allocator, parser, profile, open.snapshot.tree);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
    const again = try Snapshot.fromSource(open.runtime, profile, try testing.allocator.dupe(u8, text));
    defer again.destroy();
    const twice = try skeleton.skeletonize(testing.allocator, parser, profile, again.tree);
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(text, twice);
}

test "member refs: the C# skeleton abbreviates every => body and keeps valid C#" {
    try expectSkeleton(csharp,
        \\public class Box
        \\{
        \\    int[] data = new int[3];
        \\    public int this[int i] { get => data[i]; set => data[i] = value; }
        \\    public string this[string k] => k;
        \\    public static Box operator +(Box a, Box b) => a;
        \\    public int Area => data[0] * 2;
        \\    public int Width { get; set; }
        \\    public int Twice(int a) => a * 2;
        \\    public int Block(int a) { return a; }
        \\    public int Commented(int a) // why
        \\        => a;
        \\    ~Box() => data = null;
        \\}
        \\
    ,
        \\public class Box
        \\{
        \\    int[] data = new int[3];
        \\    public int this[int i] { get; set; }
        \\    public string this[string k] { get; }
        \\    public static Box operator +(Box a, Box b);
        \\    public int Area { get; }
        \\    public int Width { get; set; }
        \\    public int Twice(int a);
        \\    public int Block(int a);
        \\    public int Commented(int a) // why
        \\        ;
        \\    ~Box();
        \\}
        \\
    );
}

test "member refs: the C# skeleton leaves top level local functions parsing" {
    try expectSkeleton(csharp, "int L(int a) => a;\nint M(int a) { return a; }\nL(M(1));\n", "int L(int a);\nint M(int a);\nL(M(1));\n");
}

const Docs = struct {
    open: Open,
    arena: std.heap.ArenaAllocator,
    found: facts.FileFacts,

    fn init(self: *Docs, profile: *const Profile, source: []const u8) !void {
        self.open = try Open.init(profile, source);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.found = try facts_extract.extract(self.arena.allocator(), self.open.snapshot);
    }

    fn deinit(self: *Docs) void {
        self.arena.deinit();
        self.open.deinit();
    }

    fn expectDoc(self: *Docs, qname: []const u8, doc: []const u8) !void {
        for (self.found.defs) |d| {
            if (std.mem.eql(u8, d.qname, qname)) return testing.expectEqualStrings(doc, d.doc);
        }
        for (self.found.defs) |d| std.debug.print("def {s}\n", .{d.qname});
        return error.DefNotFound;
    }
};

test "member refs: a Python docstring is the doc and wins over the comment above" {
    var docs: Docs = undefined;
    try docs.init(python,
        \\def triple(a):
        \\    """Runs the job.
        \\
        \\    More detail that stays out.
        \\    """
        \\    return a
        \\
        \\# Comment above.
        \\def both():
        \\    'Single quoted doc.'
        \\    return 1
        \\
        \\# Only a comment.
        \\def commented():
        \\    return 2
        \\
        \\def bare():
        \\    x = "not a doc"
        \\    return x
        \\
        \\class Holder:
        \\    r"""Raw class doc."""
        \\    def m(self):
        \\        """
        \\        Starts on the second line.
        \\        """
        \\
    );
    defer docs.deinit();
    try docs.expectDoc("triple", "Runs the job.");
    try docs.expectDoc("both", "Single quoted doc.");
    try docs.expectDoc("commented", "Only a comment.");
    try docs.expectDoc("bare", "");
    try docs.expectDoc("Holder", "Raw class doc.");
    try docs.expectDoc("Holder.m", "Starts on the second line.");
}

test "member refs: a C# XML doc comes back as its summary text" {
    var docs: Docs = undefined;
    try docs.init(csharp,
        \\class C
        \\{
        \\    /// <summary>
        \\    /// Adds <paramref name="a"/> to <see cref="T:Shop.Cart"/> &amp; returns &lt;it&gt;.
        \\    /// Second line stays out.
        \\    /// </summary>
        \\    /// <param name="a">the amount</param>
        \\    public int Add(int a) { return a; }
        \\
        \\    /// <summary>One line.</summary>
        \\    public int One() => 1;
        \\
        \\    /// Plain text with no tag.
        \\    public int Plain() => 1;
        \\
        \\    /// <inheritdoc/>
        \\    public int Inherited() => 1;
        \\
        \\    // An ordinary comment.
        \\    public int Ordinary() => 1;
        \\
        \\    /** <summary>Block form.</summary> */
        \\    public int Block() => 1;
        \\}
        \\
    );
    defer docs.deinit();
    try docs.expectDoc("C.Add", "Adds a to Shop.Cart & returns <it>.");
    try docs.expectDoc("C.One", "One line.");
    try docs.expectDoc("C.Plain", "Plain text with no tag.");
    try docs.expectDoc("C.Inherited", "");
    try docs.expectDoc("C.Ordinary", "An ordinary comment.");
    try docs.expectDoc("C.Block", "Block form.");
}

const Repo = struct {
    repo: fixture.TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    const Reply = struct { is_error: bool, reply: Value };

    fn init(self: *Repo) !void {
        self.repo = try fixture.TsRepo.init(&.{
            .{ .rel = "a.py", .text = "class A:\n    def f(self, a: int) -> int:\n        return a\n\n    def g(self):\n        return 1\n\nclass B:\n    def g(self):\n        return 2\n" },
            .{ .rel = "C.cs", .text = "namespace Shop;\n\nclass C\n{\n    void F(int a) { }\n    void F(string a) { }\n    public int Area => 1;\n    public int Solid() { return 1; }\n}\n" },
            .{ .rel = ".gitignore", .text = ".emetgate/\n" },
        });
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Repo) void {
        self.arena_state.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn call(self: *Repo, tool: []const u8, file: []const u8, tail: []const u8) !Reply {
        const arena = self.arena_state.allocator();
        const path = try self.repo.abs(arena, file);
        const quoted = try std.mem.replaceOwned(u8, arena, path, "\\", "\\\\");
        const json = try std.fmt.allocPrint(arena, "{{\"file\":\"{s}\",{s}}}", .{ quoted, tail });
        const arguments = try std.json.parseFromSliceLeaky(Value, arena, json, .{ .allocate = .alloc_always });
        var event: telemetry.Event = .{ .tool = tool };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, arguments, &event, .{ .root = self.repo.root_abs, .test_command = "cmd /c exit 0" });
        defer testing.allocator.free(result.text);
        errdefer std.debug.print("{s}\n", .{result.text});
        const line_end = std.mem.indexOfScalar(u8, result.text, '\n') orelse result.text.len;
        const head = try arena.dupe(u8, result.text[0..line_end]);
        return .{ .is_error = result.is_error, .reply = try std.json.parseFromSliceLeaky(Value, arena, head, .{ .allocate = .alloc_always }) };
    }

    fn fix(self: *Repo, tool: []const u8, file: []const u8, tail: []const u8) ![]const u8 {
        const reply = try self.call(tool, file, tail);
        try testing.expect(reply.is_error);
        return reply.reply.object.get("fix").?.string;
    }

    fn print(self: *Repo, comptime format: []const u8, values: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena_state.allocator(), format, values);
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("missing {s} in {s}\n", .{ needle, haystack });
    try testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectLacks(haystack: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("unexpected {s} in {s}\n", .{ needle, haystack });
    try testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

test "member refs: an ambiguous ref is answered with the refs to send instead" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo: Repo = undefined;
    try repo.init();
    defer repo.deinit();
    const read = try repo.fix("emetgate_read_symbol", "C.cs", "\"symbol\":\"F\"");
    try expectContains(read, "Shop.C.F(int) (line 5)");
    try expectContains(read, "Shop.C.F(string) (line 6)");
    const write = try repo.fix("emetgate_try", "a.py", "\"symbol\":\"g\",\"hash\":\"0123456789abcdef0123456789abcdef\",\"body\":\"return 3\"");
    try expectContains(write, "A.g (line 5)");
    try expectContains(write, "B.g (line 9)");
    const rename = try repo.fix("emetgate_rename", "C.cs", "\"symbol\":\"F\",\"hash\":\"0123456789abcdef0123456789abcdef\",\"new_name\":\"G\"");
    try expectContains(rename, "Shop.C.F(int) (line 5)");
    try expectContains(rename, "Shop.C.F(string) (line 6)");
}

test "member refs: no reply about a Python body talks of braces" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo: Repo = undefined;
    try repo.init();
    defer repo.deinit();
    const read = try repo.call("emetgate_read_symbol", "a.py", "\"symbol\":\"A.f\"");
    const hash = read.reply.object.get("hash").?.string;
    for ([_][]const u8{
        "\"return a\\n  bad indent(\"",
        "\"return a }\"",
        "\"return a\\n\\ndef extra():\\n    return 1\\n\"",
    }) |body| {
        const fix = try repo.fix("emetgate_try", "a.py", try repo.print("\"symbol\":\"A.f\",\"hash\":\"{s}\",\"body\":{s}", .{ hash, body }));
        try expectLacks(fix, "brace");
        try expectLacks(fix, "\"}\"");
    }
}

test "member refs: a C# body reply names the block or the => expression" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo: Repo = undefined;
    try repo.init();
    defer repo.deinit();
    const read = try repo.call("emetgate_read_symbol", "C.cs", "\"symbol\":\"Solid\"");
    const hash = read.reply.object.get("hash").?.string;
    const fix = try repo.fix("emetgate_try", "C.cs", try repo.print("\"symbol\":\"Solid\",\"hash\":\"{s}\",\"body\":\"{{ return 1; }}\\nint Extra() {{ return 2; }}\"", .{hash}));
    try expectContains(fix, "=> expression");
}
