# Question 2: guards, interceptors and pipes

| Tool | Key items | Tokens | Cost | Model calls | Tool calls |
|---|---:|---:|---:|---:|---:|
| Claude Code (built-in tools) | 6/6 | 274,575 | $0.155 | 6 | 5 |
| Serena | 6/6 | 209,992 | $0.140 | 6 | 16 |
| codebase-memory-mcp | 6/6 | 248,493 | $0.229 | 7 | 16 |
| emetgate | 6/6 | 192,477 | $0.219 | 5 | 10 |

## Answer key, written before any tool answered

1. RouterExecutionContext.create builds the handler pipeline for each route (counted when the answer contains one of: `RouterExecutionContext`, `router-execution-context`)
2. ContextCreator.createContext merges global, then class, then method metadata in that order (counted when the answer contains one of: `createContext`, `getGlobalMetadata`, `context-creator`)
3. GuardsConsumer.tryActivate runs the guards in order and stops at the first false (counted when the answer contains one of: `tryActivate`)
4. a false result becomes ForbiddenException(FORBIDDEN_MESSAGE) in createGuardsFn (counted when the answer contains one of: `FORBIDDEN_MESSAGE`, `createGuardsFn`)
5. guards run first, then InterceptorsConsumer.intercept wraps the handler (counted when the answer contains one of: `interceptorsConsumer`, `InterceptorsConsumer`)
6. pipes are applied to the arguments by createPipesFn inside the interceptor chain, just before the handler (counted when the answer contains one of: `createPipesFn`, `PipesConsumer`, `pipesConsumer`)
