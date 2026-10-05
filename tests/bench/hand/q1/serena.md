# Question 1: API versioning: Serena

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:01:20.970Z to 2026-10-05T09:04:53.557Z
- Model calls: 6; tool calls: 13
- Tokens: 224,819 (input 12, cache written 17,006, cache read 204,323, output 3,478)
- Cost from the token counts at 2 USD per million base tokens: $0.144
- Answer-key items named in the answer: 6 of 6

## Question

NestJS has app.enableVersioning({ type: VersioningType.HEADER, header: 'X-API-Version' }) on, with the Express adapter. A controller is declared as @Controller({ path: 'cats', version: '1' }) and one of its methods is marked @Version('2'). (1) When the method version and the controller version differ, which one wins and which code decides that? (2) Which code matches the version of an incoming request, and how does it read the header? (3) What happens when the request has no X-API-Version header at all, and in which case does the handler still run? (4) Where does the request go when the version does not match? (5) If the same app used URI versioning instead, where would the version be checked, how is the path built and what is the default prefix?

## Tool calls, in order

1. `mcp__serena__initial_instructions` `{}`
   - reply: 9,181 characters
2. `mcp__serena__search_for_pattern` `{"substring_pattern": "VersioningType\\.HEADER|VERSION_NEUTRAL", "relative_path": "packages/core", "restrict_search_to_code_files": true, "paths_exclude_glob": "**/test/**"}`
   - reply: 1,412 characters
3. `mcp__serena__search_for_pattern` `{"substring_pattern": "VersioningType\\.|isVersioned|applyVersionFilter|VERSIONING_DEFAULT|defaultPrefix|DEFAULT_VERSION|VERSION_METADATA", "relative_path": "packages/core/router", "paths_exclude_glob": "**/*.spec.ts", "context_lines_after": 2}`
   - reply: 2,610 characters
4. `mcp__serena__search_for_pattern` `{"substring_pattern": "VersioningType\\.HEADER|VERSION_METADATA", "relative_path": "packages", "paths_exclude_glob": "**/*.spec.ts", "restrict_search_to_code_files": true}`
   - reply: 1,281 characters
5. `mcp__serena__read_file` `{"relative_path": "packages/core/router/router-explorer.ts", "start_line": 175, "end_line": 235}`
   - reply: 1,837 characters
6. `mcp__serena__read_file` `{"relative_path": "packages/core/router/router-explorer.ts", "start_line": 396, "end_line": 415}`
   - reply: 463 characters
7. `mcp__serena__read_file` `{"relative_path": "packages/platform-express/adapters/express-adapter.ts", "start_line": 500, "end_line": 600}`
   - reply: 3,109 characters
8. `mcp__serena__read_file` `{"relative_path": "packages/core/router/route-path-factory.ts", "start_line": 15, "end_line": 175}`
   - reply: 4,469 characters
9. `mcp__serena__search_for_pattern` `{"substring_pattern": "methodVersion|controllerVersion", "relative_path": "packages/core/router", "paths_exclude_glob": "**/*.spec.ts", "context_lines_before": 2, "context_lines_after": 2}`
   - reply: 6,473 characters
10. `mcp__serena__read_file` `{"relative_path": "packages/platform-express/adapters/express-adapter.ts", "start_line": 440, "end_line": 500}`
   - reply: 2,136 characters
11. `mcp__serena__search_for_pattern` `{"substring_pattern": "callNextHandler", "relative_path": "packages/platform-express/adapters/express-adapter.ts", "context_lines_after": 3}`
   - reply: 708 characters
12. `mcp__serena__read_file` `{"relative_path": "packages/core/router/paths-explorer.ts", "start_line": 55, "end_line": 80}`
   - reply: 742 characters
13. `mcp__serena__read_file` `{"relative_path": "packages/platform-express/adapters/express-adapter.ts", "start_line": 412, "end_line": 442}`
   - reply: 754 characters

## Answer

Here is what the code does, traced through `packages/core` and `packages/platform-express`.

**1. Method version wins over controller version.**
- `RoutePathFactory.getVersion()` in `packages/core/router/route-path-factory.ts` returns `metadata.methodVersion || metadata.controllerVersion`. Your `@Version('2')` therefore beats the controller's `'1'`.
- `RouterExplorer.applyCallbackToRouter()` in `router/router-explorer.ts` uses the same precedence (`methodVersion ?? controllerVersion`) when it builds the route definition.
- The two values come from different places:
  - `PathsExplorer` reads the method version from `VERSION_METADATA` on the prototype method.
  - `RoutesResolver.getVersionMetadata()` reads the controller version from the class, falling back to `defaultVersion`.

**2. Matching and reading the header.**
- `RouterExplorer.applyVersionFilter()` calls `router.applyVersionFilter(handler, version, options)`. Express implements that in `ExpressAdapter.applyVersionFilter()` in `platform-express/adapters/express-adapter.ts`.
- The HEADER branch builds `handlerForHeaderVersioning`. It reads `req.headers?.[versioningOptions.header] || req.headers?.[versioningOptions.header.toLowerCase()]`, so it tries `X-API-Version` first and then `x-api-version`.
- If the header is present, the handler runs only when it matches. For a string route version that means `version === headerValue`. For an array it means `version.includes(headerValue)`.
- Your route has version `'2'`, so it runs only for `X-API-Version: 2`.

**3. No header at all.**
- The header value is `undefined`, and the handler runs only if the route's `version` is an array that includes `VERSION_NEUTRAL`.
- A plain `'2'` route does not run without the header.
- A route whose version is exactly `VERSION_NEUTRAL` skips the filter entirely, because the early-return branch at the top of `applyVersionFilter` passes straight through. It runs with or without the header.

**4. Mismatch.**
- The filter calls `callNextHandler`, defined at the top of `applyVersionFilter`, which just calls `next()`. The request moves on to the next matching Express route.
- That route might be another handler for the same path with a different version. If none matches, Nest's normal 404 handling applies.
- If the adapter gives no `next`, it throws `InternalServerErrorException('HTTP adapter does not support filtering on version')`.

**5. URI versioning instead.**
- **Where it's checked:** nowhere at request time. `applyCallbackToRouter` only applies the filter when `versioningOptions.type !== VersioningType.URI`, and Express's `applyVersionFilter` also passes URI straight through. The version is part of the registered path, so Express's own routing does the matching.
- **How the path is built:** `RoutePathFactory.create()` starts with `/${versionPrefix}${version}`. It then appends the module path, controller path and method path. A global prefix, if any, goes in front. Your route would be `/v2/cats`. `VERSION_NEUTRAL` adds no version segment, and an array of versions registers one path per version.
- **Default prefix:** `getVersionPrefix()` returns `'v'`. A `prefix` option overrides it, and `prefix: false` gives `''`.
