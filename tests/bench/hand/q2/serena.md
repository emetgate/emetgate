# Question 2: guards, interceptors and pipes: Serena

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:12:07.850Z to 2026-10-05T09:12:42.650Z
- Model calls: 6; tool calls: 16
- Tokens: 209,992 (input 12, cache written 14,677, cache read 190,966, output 4,337)
- Cost from the token counts at 2 USD per million base tokens: $0.140
- Answer-key items named in the answer: 6 of 6

## Question

In a NestJS HTTP app a route has a global guard, a controller-level guard and a method-level guard, plus an interceptor and a ValidationPipe on a @Body() parameter. (1) Which code builds the chain that runs for this route? (2) In which order are the global, controller and method guards collected and run, and which code decides that order? (3) What happens when the second guard returns false, do the remaining guards run, and what exactly does the client get? (4) In which order do guards, interceptors and pipes run relative to the handler, and where in the code is that order fixed?

## Tool calls, in order

1. `mcp__serena__initial_instructions` `{}`
   - reply: 9,181 characters
2. `mcp__serena__get_symbols_overview` `{"relative_path": "packages/core/router/router-execution-context.ts", "depth": 1}`
3. `mcp__serena__get_symbols_overview` `{"relative_path": "packages/core/guards/guards-context-creator.ts", "depth": 1}`
4. `mcp__serena__get_symbols_overview` `{"relative_path": "packages/core/guards/guards-consumer.ts", "depth": 1}`
   - reply: 461 characters
   - reply: 184 characters
   - reply: 91 characters
5. `mcp__serena__find_symbol` `{"name_path_pattern": "RouterExecutionContext/create", "relative_path": "packages/core/router/router-execution-context.ts", "include_body": true}`
   - reply: 3,701 characters
6. `mcp__serena__find_symbol` `{"name_path_pattern": "RouterExecutionContext/createGuardsFn", "relative_path": "packages/core/router/router-execution-context.ts", "include_body": true}`
   - reply: 830 characters
7. `mcp__serena__find_symbol` `{"name_path_pattern": "GuardsContextCreator", "relative_path": "packages/core/guards/guards-context-creator.ts", "include_body": true}`
   - reply: 3,224 characters
8. `mcp__serena__find_symbol` `{"name_path_pattern": "GuardsConsumer", "relative_path": "packages/core/guards/guards-consumer.ts", "include_body": true}`
   - reply: 1,461 characters
9. `mcp__serena__find_symbol` `{"name_path_pattern": "ContextCreator/createContext", "relative_path": "packages/core/helpers/context-creator.ts", "include_body": true}`
   - reply: 1,089 characters
10. `mcp__serena__search_for_pattern` `{"substring_pattern": "routerExecutionContext\\.create\\(|createRequestScopedHandler|createProxy\\(|FORBIDDEN_MESSAGE =", "relative_path": "packages/core", "paths_exclude_glob": "**/*.spec.ts", "context_lines_after": 3}`
   - reply: 2,078 characters
11. `mcp__serena__find_symbol` `{"name_path_pattern": "RouterExecutionContext/createPipesFn", "relative_path": "packages/core/router/router-execution-context.ts", "include_body": true}`
   - reply: 1,215 characters
12. `mcp__serena__read_file` `{"relative_path": "packages/core/router/router-explorer.ts", "start_line": 165, "end_line": 215}`
   - reply: 1,555 characters
13. `mcp__serena__read_file` `{"relative_path": "packages/core/router/router-explorer.ts", "start_line": 405, "end_line": 438}`
   - reply: 784 characters
14. `mcp__serena__find_symbol` `{"name_path_pattern": "InterceptorsConsumer/intercept", "relative_path": "packages/core/interceptors/interceptors-consumer.ts", "include_body": true}`
   - reply: 1,112 characters
15. `mcp__serena__find_symbol` `{"name_path_pattern": "RouterProxy/createProxy", "relative_path": "packages/core/router/router-proxy.ts", "include_body": true}`
   - reply: 648 characters
16. `mcp__serena__find_symbol` `{"name_path_pattern": "ExceptionsHandler/next", "relative_path": "packages/core/exceptions/exceptions-handler.ts", "include_body": true}`
   - reply: 372 characters

## Answer

All paths below are under `packages/core/`.

## (1) What builds the chain

- **Per-route entry point:** `RouterExplorer.applyCallbackToRouter` (`router/router-explorer.ts` ~l.165–200) picks `createCallbackProxy`. For request-scoped controllers it picks `createRequestScopedHandler`.
- **`createCallbackProxy`** (`router-explorer.ts:~411`) calls `RouterExecutionContext.create(...)` (`router/router-execution-context.ts:95–215`), which assembles the route's pipeline. It also builds the exception filter and wraps both in `routerProxy.createProxy`.
- **Inside `create`:**
  - `pipesContextCreator.create`, `guardsContextCreator.create` and `interceptorsContextCreator.create` collect the three lists.
  - `createGuardsFn` turns the guard list into `fnCanActivate`.
  - `createPipesFn` turns the pipes and `@Body()` param metadata into `fnApplyPipes`.
  - The `handler` closure runs the pipes, then the controller method.
  - The returned function runs per request: guards, then interceptors wrapping `handler`, then response handling.
- **`RouterProxy.createProxy`** (`router/router-proxy.ts:10`) wraps all of it in a try/catch that sends errors to `ExceptionsHandler`.

## (2) Guard collection order

`GuardsContextCreator.create` (`guards/guards-context-creator.ts:22`) calls the shared `ContextCreator.createContext` (`helpers/context-creator.ts:15–40`). That method builds the array as **global, then controller class, then method**:

```ts
[...createConcreteContext(globalMetadata), ...createConcreteContext(classMetadata), ...createConcreteContext(methodMetadata)]
```

- **Global guards** come from `getGlobalMetadata`, which reads `config.getGlobalGuards()`. These are `app.useGlobalGuards` and `APP_GUARD` providers. Request-scoped `APP_GUARD` providers are appended when a context id is present.
- **Class and method guards** come from `GUARDS_METADATA` through `reflectClassMetadata` and `reflectMethodMetadata`.
- **Within each level**, guards keep their `@UseGuards(A, B)` order.
- **Where the order is decided:** `createContext` in `context-creator.ts`. The same ordering applies to interceptors and pipes.
- **Execution order:** `GuardsConsumer.tryActivate` (`guards/guards-consumer.ts`) iterates the array in that order. It awaits Promise and Observable results through `pickResult`.

## (3) When the second guard returns false

- `tryActivate` hits `return false` inside the `for` loop (`guards-consumer.ts`). **Guards 3 and later never run**, because evaluation is sequential and short-circuits.
- The canActivate closure in `createGuardsFn` (`router-execution-context.ts:399–418`) sees `false` and throws `new ForbiddenException(FORBIDDEN_MESSAGE)`. `FORBIDDEN_MESSAGE` is `'Forbidden resource'`, defined in `guards/constants.ts`.
- This happens inside `fnCanActivate` at the top of the request function, before status and headers are set. The interceptors, pipes and handler never run.
- `RouterProxy`'s catch block passes the exception to `ExceptionsHandler.next`. Custom `@Catch` filters get the first chance. Otherwise `BaseExceptionFilter` responds.
- **The client gets** HTTP 403 with the body below. This is the standard `ForbiddenException` body, which I did not check against `HttpException`'s code in this repo:

```json
{"statusCode":403,"message":"Forbidden resource","error":"Forbidden"}
```

- A guard that *throws* instead of returning `false` skips the `ForbiddenException` and its own exception goes to the filter.

## (4) Order of guards, interceptors, pipes and handler

For this route the order is:

1. Guards: global, controller, then method.
2. Interceptors, before-handler part (global, controller, method).
3. Pipes, including the `ValidationPipe` on `@Body()`.
4. The controller method.
5. Interceptors, after-handler part, in reverse order.
6. Response handling (`fnHandleResponse`).
7. Exception filters, if anything threw.

This order is fixed in the function returned by `RouterExecutionContext.create` (`router-execution-context.ts:~150–215`):

- `await fnCanActivate(...)` runs first.
- `interceptorsConsumer.intercept(interceptors, ..., handler(...))` runs next. The interceptor chain is built in `InterceptorsConsumer.intercept` (`interceptors/interceptors-consumer.ts:9–34`). Each `intercept` receives a `CallHandler` whose `handle()` calls the next interceptor, and the last one calls `next`, which is the `handler` closure.
- The `handler` closure does `await fnApplyPipes(...)` and then `callback.apply(instance, args)`. **Pipes therefore run inside the interceptor chain, immediately before the handler.** A pipe failure, such as a validation 400, reaches interceptors that handle errors (for example with `catchError`), while a guard 403 does not.
- Pipe order for the `@Body()` param is global, controller, method, then param-level, because `createPipesFn` does `pipes.concat(paramPipes)` (`router-execution-context.ts:~445`). The `ValidationPipe` on the `@Body()` parameter runs last in that list.
