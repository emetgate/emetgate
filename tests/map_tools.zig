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

const files = [_]File{
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

test "map tools: the explore reply reaches the functions that write the fields read by the matching functions" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo");
    for (files) |f| {
        const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{f.path});
        defer testing.allocator.free(sub);
        if (std.fs.path.dirnamePosix(sub)) |d| try tmp.dir.createDirPath(testing.io, d);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = f.data });
    }
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(base);
    const root = try std.fmt.allocPrint(testing.allocator, "{s}\\repo", .{base});
    defer testing.allocator.free(root);
    try git_fixture.initRepo(root);
    try git(root, &.{ "add", "." });
    const store_path = try std.fmt.allocPrint(testing.allocator, "{s}\\store\\facts.v{d}", .{ base, fact_file.version });
    defer testing.allocator.free(store_path);

    const session = try map_tools.Session.create(testing.allocator, testing.io, runtime, root);
    defer session.destroy();
    session.store_override = store_path;
    try session.build();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try session.answer(arena_state.allocator(), "in which order are module init hooks called", &.{});

    try testing.expect(text.len <= map_tools.reply_budget);
    try expectHas(text, "NestApplicationContext.getModulesToTriggerHooksOn");
    try expectHas(text, "const compareFn = (a: Module, b: Module) => b.distance - a.distance;");
    try expectHas(text, "getInstancesGroupedByLevel");
    try expectHas(text, "const level = wrapper.level;");
    try expectHas(text, "DependenciesScanner.calculateModulesDistance");
    try expectHas(text, "      moduleRef.distance = depth;");
    try expectHas(text, "    tree.walk((moduleRef, depth) => {");
    try expectHas(text, "NestContainer.addModule");
    try expectHas(text, "moduleRef.distance = Number.MAX_VALUE;");
    try expectHas(text, "Injector.loadInstance");
    try expectHas(text, "wrapper.level = depth + 1;");
    try testing.expect(std.mem.indexOf(u8, text, "emetgate_") == null);
}
