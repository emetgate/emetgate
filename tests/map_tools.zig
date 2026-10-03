const std = @import("std");
const emetgate = @import("emetgate");
const map_tools = emetgate.map_tools;
const fact_file = emetgate.fact_file;
const test_util = emetgate.test_util;
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;

const File = struct { path: []const u8, data: []const u8 };

const nest_application_context_ts =
    \\import { NestContainer } from './injector/container';
    \\import { Module } from './injector/module';
    \\import { callModuleInitHook } from './hooks/on-module-init.hook';
    \\import { Logger } from '../common/services/logger';
    \\
    \\export class NestApplicationContext {
    \\  private isInitialized = false;
    \\  private moduleRefsByDistance?: Module[];
    \\
    \\  constructor(
    \\    protected readonly container: NestContainer,
    \\    private readonly logger: Logger,
    \\  ) {}
    \\
    \\  public async init(): Promise<this> {
    \\    if (this.isInitialized) {
    \\      return this;
    \\    }
    \\    await this.callInitHook();
    \\    this.isInitialized = true;
    \\    this.logger.log('initialized');
    \\    return this;
    \\  }
    \\
    \\  protected async callInitHook(): Promise<void> {
    \\    const modulesSortedByDistance = this.getModulesToTriggerHooksOn();
    \\    for (const module of modulesSortedByDistance) {
    \\      await callModuleInitHook(module);
    \\    }
    \\  }
    \\
    \\  private getModulesToTriggerHooksOn(): Module[] {
    \\    if (this.moduleRefsByDistance) {
    \\      return this.moduleRefsByDistance;
    \\    }
    \\    const modulesContainer = this.container.getModules();
    \\    const compareFn = (a: Module, b: Module) => b.distance - a.distance;
    \\    const modulesSortedByDistance = Array.from(modulesContainer.values()).sort(
    \\      compareFn,
    \\    );
    \\    this.moduleRefsByDistance = modulesSortedByDistance;
    \\    return this.moduleRefsByDistance;
    \\  }
    \\}
    \\
;

const on_module_init_hook_ts =
    \\import { Module } from '../injector/module';
    \\import { getInstancesGroupedByLevel } from './utils/get-instances-grouped-by-level';
    \\
    \\function hasOnModuleInitHook(instance: unknown): instance is { onModuleInit: () => unknown } {
    \\  return typeof (instance as any)?.onModuleInit === 'function';
    \\}
    \\
    \\function callOperator(instances: unknown[]): Promise<unknown>[] {
    \\  return instances
    \\    .filter(instance => hasOnModuleInitHook(instance))
    \\    .map(async instance => (instance as any).onModuleInit());
    \\}
    \\
    \\export async function callModuleInitHook(module: Module): Promise<void> {
    \\  const groupedInstances = getInstancesGroupedByLevel(module.controllers, module.providers);
    \\  const levels = Array.from(groupedInstances.keys()).sort((a, b) => b - a);
    \\  for (const level of levels) {
    \\    await Promise.all(callOperator(groupedInstances.get(level)!));
    \\  }
    \\}
    \\
;

const get_instances_grouped_by_level_ts =
    \\import { InstanceWrapper } from '../../injector/instance-wrapper';
    \\
    \\export function getInstancesGroupedByLevel(
    \\  ...collections: Array<Map<string, InstanceWrapper>>
    \\): Map<number, unknown[]> {
    \\  const groupedByLevel = new Map<number, unknown[]>();
    \\  for (const collection of collections) {
    \\    for (const [_, wrapper] of collection) {
    \\      if (!wrapper.isDependencyTreeStatic()) {
    \\        continue;
    \\      }
    \\      const level = wrapper.level;
    \\      if (!groupedByLevel.has(level)) {
    \\        groupedByLevel.set(level, []);
    \\      }
    \\      const group = groupedByLevel.get(level);
    \\      if (wrapper.instance) {
    \\        group!.push(wrapper.instance);
    \\      }
    \\    }
    \\  }
    \\  return groupedByLevel;
    \\}
    \\
;

const module_ts =
    \\import { InstanceWrapper } from './instance-wrapper';
    \\import { NestContainer } from './container';
    \\
    \\export class Module {
    \\  private _distance = 0;
    \\  private _isGlobal = false;
    \\  private readonly _providers = new Map<string, InstanceWrapper>();
    \\  private readonly _controllers = new Map<string, InstanceWrapper>();
    \\  private readonly _imports = new Set<Module>();
    \\
    \\  constructor(
    \\    private readonly _metatype: Function,
    \\    private readonly container: NestContainer,
    \\  ) {}
    \\
    \\  get isGlobal(): boolean {
    \\    return this._isGlobal;
    \\  }
    \\
    \\  set isGlobal(global: boolean) {
    \\    this._isGlobal = global;
    \\  }
    \\
    \\  get distance(): number {
    \\    return this._distance;
    \\  }
    \\
    \\  set distance(value: number) {
    \\    this._distance = value;
    \\  }
    \\
    \\  get providers(): Map<string, InstanceWrapper> {
    \\    return this._providers;
    \\  }
    \\
    \\  get controllers(): Map<string, InstanceWrapper> {
    \\    return this._controllers;
    \\  }
    \\
    \\  get imports(): Set<Module> {
    \\    return this._imports;
    \\  }
    \\
    \\  public addProvider(token: string, wrapper: InstanceWrapper): string {
    \\    if (this._providers.has(token)) {
    \\      return token;
    \\    }
    \\    this._providers.set(token, wrapper);
    \\    return token;
    \\  }
    \\
    \\  public addImport(moduleRef: Module) {
    \\    if (moduleRef === this) {
    \\      return;
    \\    }
    \\    this._imports.add(moduleRef);
    \\  }
    \\}
    \\
;

const instance_wrapper_ts =
    \\export class InstanceWrapper<T = any> {
    \\  public readonly name: string;
    \\  public instance: T | undefined;
    \\  public isResolved = false;
    \\  public level = 0;
    \\  private readonly durable: boolean;
    \\
    \\  constructor(name: string, instance?: T, durable = false) {
    \\    this.name = name;
    \\    this.instance = instance;
    \\    this.durable = durable;
    \\  }
    \\
    \\  public isDependencyTreeStatic(): boolean {
    \\    return !this.durable;
    \\  }
    \\}
    \\
;

const injector_ts =
    \\import { InstanceWrapper } from './instance-wrapper';
    \\import { Module } from './module';
    \\import { Logger } from '../../common/services/logger';
    \\
    \\export class Injector {
    \\  constructor(private readonly logger: Logger) {}
    \\
    \\  public async loadInstance(wrapper: InstanceWrapper, moduleRef: Module, depth = 0): Promise<void> {
    \\    if (wrapper.isResolved) {
    \\      return;
    \\    }
    \\    const dependencies = this.resolveDependencies(wrapper, moduleRef);
    \\    for (const dependency of dependencies) {
    \\      await this.loadInstance(dependency, moduleRef, depth + 1);
    \\    }
    \\    wrapper.level = depth + 1;
    \\    wrapper.isResolved = true;
    \\    this.logger.log(wrapper.name);
    \\  }
    \\
    \\  private resolveDependencies(wrapper: InstanceWrapper, moduleRef: Module): InstanceWrapper[] {
    \\    const found = moduleRef.providers.get(wrapper.name);
    \\    return found ? [found] : [];
    \\  }
    \\}
    \\
;

const container_ts =
    \\import { Module } from './module';
    \\
    \\export class NestContainer {
    \\  private readonly modules = new Map<string, Module>();
    \\  private readonly globalModules = new Set<Module>();
    \\
    \\  constructor(private readonly applicationConfig: object) {}
    \\
    \\  public getModules(): Map<string, Module> {
    \\    return this.modules;
    \\  }
    \\
    \\  public async addModule(metatype: Function, token: string): Promise<Module> {
    \\    if (this.modules.has(token)) {
    \\      return this.modules.get(token)!;
    \\    }
    \\    const moduleRef = new Module(metatype, this);
    \\    this.modules.set(token, moduleRef);
    \\    if (this.isGlobalModule(metatype)) {
    \\      moduleRef.isGlobal = true;
    \\      moduleRef.distance = Number.MAX_VALUE;
    \\      this.globalModules.add(moduleRef);
    \\    }
    \\    return moduleRef;
    \\  }
    \\
    \\  public isGlobalModule(metatype: Function): boolean {
    \\    return Reflect.getMetadata('__module:global__', metatype) === true;
    \\  }
    \\}
    \\
;

const topology_tree_ts =
    \\import { Module } from './module';
    \\
    \\export class TopologyTree {
    \\  constructor(private readonly root: Module) {}
    \\
    \\  public walk(callback: (value: Module, depth: number) => void) {
    \\    const visit = (node: Module, depth: number) => {
    \\      callback(node, depth);
    \\      node.imports.forEach(child => visit(child, depth + 1));
    \\    };
    \\    visit(this.root, 1);
    \\  }
    \\}
    \\
;

const scanner_ts =
    \\import { NestContainer } from './injector/container';
    \\import { TopologyTree } from './injector/topology-tree';
    \\
    \\export class DependenciesScanner {
    \\  constructor(private readonly container: NestContainer) {}
    \\
    \\  public async scan(module: Function) {
    \\    await this.scanForModules(module);
    \\    this.calculateModulesDistance();
    \\  }
    \\
    \\  public async scanForModules(module: Function) {
    \\    await this.container.addModule(module, module.name);
    \\  }
    \\
    \\  public calculateModulesDistance() {
    \\    const modulesGenerator = this.container.getModules().values();
    \\    modulesGenerator.next();
    \\    const rootModule = modulesGenerator.next().value!;
    \\    if (!rootModule) {
    \\      return;
    \\    }
    \\    const tree = new TopologyTree(rootModule);
    \\    tree.walk((moduleRef, depth) => {
    \\      if (moduleRef.isGlobal) {
    \\        return;
    \\      }
    \\      moduleRef.distance = depth;
    \\    });
    \\  }
    \\}
    \\
;

const logger_ts =
    \\export class Logger {
    \\  private level = 'log';
    \\  private context = '';
    \\
    \\  constructor(context = '', level = 'log') {
    \\    this.context = context;
    \\    this.level = level;
    \\  }
    \\
    \\  public setLevel(level: string) {
    \\    this.level = level;
    \\  }
    \\
    \\  public log(message: string) {
    \\    if (this.level === 'silent') {
    \\      return;
    \\    }
    \\    console.log(`[${this.context}] ${message}`);
    \\  }
    \\}
    \\
;

const hooks_runner_ts =
    \\export function runHooks(names: string[]) {
    \\  return names.length;
    \\}
    \\
;

const shutdown_runner_ts =
    \\export const shutdownSignals = {
    \\  first: 'leftover-signal',
    \\};
    \\
    \\export async function runHooks(signal: string) {
    \\  if (signal === shutdownSignals.first) {
    \\    return 'stop';
    \\  }
    \\  return 'go';
    \\}
    \\
;

const files = [_]File{
    .{ .path = "packages/core/hooks/runner.ts", .data = hooks_runner_ts },
    .{ .path = "packages/core/shutdown/runner.ts", .data = shutdown_runner_ts },
    .{ .path = "packages/core/nest-application-context.ts", .data = nest_application_context_ts },
    .{ .path = "packages/core/hooks/on-module-init.hook.ts", .data = on_module_init_hook_ts },
    .{ .path = "packages/core/hooks/utils/get-instances-grouped-by-level.ts", .data = get_instances_grouped_by_level_ts },
    .{ .path = "packages/core/injector/module.ts", .data = module_ts },
    .{ .path = "packages/core/injector/instance-wrapper.ts", .data = instance_wrapper_ts },
    .{ .path = "packages/core/injector/injector.ts", .data = injector_ts },
    .{ .path = "packages/core/injector/container.ts", .data = container_ts },
    .{ .path = "packages/core/injector/topology-tree.ts", .data = topology_tree_ts },
    .{ .path = "packages/core/scanner.ts", .data = scanner_ts },
    .{ .path = "packages/common/services/logger.ts", .data = logger_ts },
};

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = root } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) != null) return;
    std.debug.print("missing: {s}\n--- reply ---\n{s}\n", .{ part, text });
    return error.TestExpectedEqual;
}

const Fixture = struct {
    runtime: *emetgate.runtime.Runtime,
    tmp: std.testing.TmpDir,
    base: [:0]u8,
    root: []u8,
    store_path: []u8,
    session: *map_tools.Session,

    fn open() !Fixture {
        const runtime = try test_util.openRuntime();
        var tmp = testing.tmpDir(.{});
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |f| {
            const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{f.path});
            defer testing.allocator.free(sub);
            if (std.fs.path.dirnamePosix(sub)) |d| try tmp.dir.createDirPath(testing.io, d);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = f.data });
        }
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        const root = try std.fmt.allocPrint(testing.allocator, "{s}\\repo", .{base});
        try git_fixture.initRepo(root);
        try git(root, &.{ "add", "." });
        const store_path = try std.fmt.allocPrint(testing.allocator, "{s}\\store\\facts.v{d}", .{ base, fact_file.version });
        const session = try map_tools.Session.create(testing.allocator, testing.io, runtime, root);
        session.store_override = store_path;
        try session.build();
        return .{ .runtime = runtime, .tmp = tmp, .base = base, .root = root, .store_path = store_path, .session = session };
    }

    fn close(self: *Fixture) void {
        self.session.destroy();
        testing.allocator.free(self.store_path);
        testing.allocator.free(self.root);
        testing.allocator.free(self.base);
        self.tmp.cleanup();
        test_util.closeRuntime(self.runtime);
    }
};

fn expectLacks(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) return;
    std.debug.print("unexpected: {s}\n--- reply ---\n{s}\n", .{ part, text });
    return error.TestExpectedEqual;
}

test "map tools: explore shows every definition of a named symbol whole, numbers each line and names the symbol it does not know" {
    var f = try Fixture.open();
    defer f.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try f.session.answer(arena_state.allocator(), "which hooks run", &.{ "runHooks", "nothingLikeThis" });

    try testing.expect(text.len <= map_tools.reply_budget);
    try expectHas(text, "packages/core/hooks/runner.ts:1 runHooks\n1 export function runHooks(names: string[]) {\n2   return names.length;\n3 }\n");
    try expectHas(text, "packages/core/shutdown/runner.ts:5 runHooks\n5 export async function runHooks(signal: string) {\n");
    try expectHas(text, "\n9   return 'go';\n10 }\n");
    try expectHas(text, "No symbol named nothingLikeThis.");
    try expectLacks(text, "emetgate_");
}

test "map tools: explore reaches a function and a top-level constant through words of their bodies" {
    var f = try Fixture.open();
    defer f.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try f.session.answer(arena_state.allocator(), "module distance depth leftover signal", &.{});

    try expectHas(text, "DependenciesScanner.calculateModulesDistance");
    try expectHas(text, "moduleRef.distance = depth;");
    try expectHas(text, "packages/core/shutdown/runner.ts:1 shutdownSignals\n1 export const shutdownSignals = {\n2   first: 'leftover-signal',\n3 };\n");
}

test "map tools: a qualified name picks the definition in the named file and a class is named, not expanded" {
    var f = try Fixture.open();
    defer f.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try f.session.answer(arena_state.allocator(), "how does it stop", &.{ "shutdown.runHooks", "Logger" });

    try expectHas(text, "packages/core/shutdown/runner.ts:5 runHooks\n");
    const wanted = std.mem.indexOf(u8, text, "packages/core/shutdown/runner.ts:5 runHooks\n") orelse return error.TestExpectedEqual;
    if (std.mem.indexOf(u8, text, "packages/core/hooks/runner.ts:1 runHooks\n")) |other| try testing.expect(wanted < other);
    try expectHas(text, "Named classes, shown through their matching members:\npackages/common/services/logger.ts:1 Logger\n");
}

test "map tools: evidence returns every definition of a name and names the symbols it does not know" {
    var f = try Fixture.open();
    defer f.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try f.session.evidenceText(arena_state.allocator(), &.{ "runHooks", "nothingLikeThis" }, map_tools.evidence_budget);

    try expectHas(text, "packages/core/hooks/runner.ts\n");
    try expectHas(text, "packages/core/shutdown/runner.ts\n");
    try expectHas(text, "export function runHooks(names: string[]) {");
    try expectHas(text, "export async function runHooks(signal: string) {");
    try expectHas(text, "No symbol named nothingLikeThis.");
}
