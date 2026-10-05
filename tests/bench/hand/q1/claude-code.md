# Question 1: API versioning: Claude Code (built-in tools)

- Model: `claude-sonnet-5-5`
- Session: 2026-10-05T09:01:21.741Z to 2026-10-05T09:04:46.720Z
- Model calls: 4; tool calls: 7
- Tokens: 175,438 (input 8, cache written 14,206, cache read 158,480, output 2,744)
- Cost from the token counts at 2 USD per million base tokens: $0.116
- Answer-key items named in the answer: 6 of 6

## Question

NestJS has app.enableVersioning({ type: VersioningType.HEADER, header: 'X-API-Version' }) on, with the Express adapter. A controller is declared as @Controller({ path: 'cats', version: '1' }) and one of its methods is marked @Version('2'). (1) When the method version and the controller version differ, which one wins and which code decides that? (2) Which code matches the version of an incoming request, and how does it read the header? (3) What happens when the request has no X-API-Version header at all, and in which case does the handler still run? (4) Where does the request go when the version does not match? (5) If the same app used URI versioning instead, where would the version be checked, how is the path built and what is the default prefix?

## Tool calls, in order

1. `Grep` `{"pattern": "VERSION_METADATA|VersioningType\\.HEADER|isVersioning|VersioningType\\.URI", "path": "C:\\benchmark\\plain-claude\\nest\\packages", "glob": "*.ts", "output_mode": "files_with_matches"}`
   - reply: 1,272 characters
2. `Grep` `{"pattern": "[Vv]ersion", "path": "C:\\benchmark\\plain-claude\\nest\\packages\\core\\router\\router-explorer.ts", "output_mode": "content"}`
   - reply: 1,895 characters
3. `Grep` `{"pattern": "[Vv]ersion", "path": "C:\\benchmark\\plain-claude\\nest\\packages\\platform-express\\adapters\\express-adapter.ts", "output_mode": "content"}`
   - reply: 3,336 characters
4. `Grep` `{"pattern": "[Vv]ersion", "path": "C:\\benchmark\\plain-claude\\nest\\packages\\core\\router\\route-path-factory.ts", "output_mode": "content"}`
   - reply: 2,254 characters
5. `Read` `{"file_path": "C:\\benchmark\\plain-claude\\nest\\packages\\platform-express\\adapters\\express-adapter.ts", "offset": 425, "limit": 145}`
   - reply: 5,219 characters
6. `Read` `{"file_path": "C:\\benchmark\\plain-claude\\nest\\packages\\core\\router\\route-path-factory.ts", "offset": 20, "limit": 80}`
   - reply: 2,623 characters
7. `Read` `{"file_path": "C:\\benchmark\\plain-claude\\nest\\packages\\core\\router\\router-explorer.ts", "offset": 195, "limit": 30}`
   - reply: 996 characters

## Answer

**Short answer:** the method's `@Version('2')` wins over the controller's `'1'`. The Express adapter matches the header against that version. A request with no header, or the wrong one, falls through to the next route and normally ends in a 404.

**1. Method vs. controller version**

The method version wins. `RoutePathFactory.getVersion()` is in `packages/core/router/route-path-factory.ts:80-84`:
```ts
return metadata.methodVersion || metadata.controllerVersion;
```
`RouterExplorer` puts both values into the route metadata (`router-explorer.ts:149-150` for the method, and the controller version when the controller is scanned). Both `applyVersionFilter` (`router-explorer.ts:405`) and path creation call `getVersion()`, so `'2'` is the version used. The handler is never registered under `'1'`.

**2. Matching the request version**

- **Where it's wired:** `RouterExplorer.applyVersionFilter` (`router-explorer.ts:400`) is used for every non-URI versioning type (`:210-220`). It calls `router.applyVersionFilter(...)`.
- **Where it's matched:** `ExpressAdapter.applyVersionFilter` in `packages/platform-express/adapters/express-adapter.ts:425-567`. The `VersioningType.HEADER` branch is at `:535-564`.
- **How it reads the header** (`:537-539`):
  ```ts
  req.headers?.[versioningOptions.header] || req.headers?.[versioningOptions.header.toLowerCase()]
  ```
  So it tries `X-API-Version` as configured, then `x-api-version`. Node already lowercases incoming header names, so the second lookup is the one that normally hits.
- **How it compares:** if the declared version is a string, it requires `version === headerValue` (`:553-555`). If it's an array, it requires `version.includes(headerValue)` (`:549-551`).

**4. Where a mismatch goes**

The filter calls `callNextHandler` (`:560`, defined at `:430-437`), which calls Express's `next()`. The request moves on to the next registered route that matches the same path and method. That could be another handler for the same path with a different version. If nothing else matches, it reaches Nest's not-found handler and returns a 404 (`Cannot GET /cats`). It does not return a 400 or a "version mismatch" error. If the adapter gave no `next`, it throws `InternalServerErrorException('HTTP adapter does not support filtering on version')`.

**3. No `X-API-Version` header**

The header value is `undefined`, so the code takes the "No version was supplied" branch (`:542-547`). The handler runs only if the declared version is an array that includes `VERSION_NEUTRAL`, for example `@Version([VERSION_NEUTRAL, '2'])`. For your plain `'2'` it falls to `callNextHandler` and you get the 404 above.

There is also an earlier exit (`:439-448`). If the version is exactly `VERSION_NEUTRAL`, the filter is a pass-through and the handler always runs, with or without the header.

**5. URI versioning instead**

- **Version check:** there is none at request time. `ExpressAdapter.applyVersionFilter` returns a pass-through for `VersioningType.URI` (`:439-448`), and `RouterExplorer` skips the filter for URI (`router-explorer.ts:210-212`). The version is baked into the registered route path, so Express's own path matching does the "check". A wrong version is just an unmatched path and a 404.
- **Path building:** `RoutePathFactory.create()` (`route-path-factory.ts:27-53`) prepends `/${prefix}${version}` before the module, controller and method paths. For an array of versions it registers one path per version. `VERSION_NEUTRAL` adds no segment. Your example would register `/v2/cats/...`. The global prefix is added in front of that (`:59-73`), unless it is excluded.
- **Default prefix:** `'v'` (`getVersionPrefix`, `:86-96`). Setting `prefix: false` gives `''` and a custom string replaces it.

I read the source but didn't run the app or the tests. The 404 detail in (4) is how Nest's not-found handler behaves in general, not something I traced in this repo.
