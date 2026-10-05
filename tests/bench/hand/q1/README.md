# Question 1: API versioning

| Tool | Key items | Tokens | Cost | Model calls | Tool calls |
|---|---:|---:|---:|---:|---:|
| Claude Code (built-in tools) | 6/6 | 175,438 | $0.116 | 4 | 7 |
| Serena | 6/6 | 224,819 | $0.144 | 6 | 13 |
| codebase-memory-mcp | 6/6 | 124,775 | $0.166 | 4 | 5 |
| emetgate | 6/6 | 86,413 | $0.086 | 3 | 5 |

## Answer key, written before any tool answered

1. method version wins over controller version: RoutePathFactory.getVersion returns methodVersion || controllerVersion (counted when the answer contains one of: `getVersion`, `methodVersion`)
2. RouterExplorer wraps the handler with the adapter's applyVersionFilter for every type except URI (counted when the answer contains one of: `applyVersionFilter`)
3. ExpressAdapter.applyVersionFilter, header branch handlerForHeaderVersioning reads req.headers[header] and its lower-case form (counted when the answer contains one of: `handlerForHeaderVersioning`, `toLowerCase`)
4. no header: the handler runs only when the version is an array that includes VERSION_NEUTRAL; a single VERSION_NEUTRAL version never gets a filter (counted when the answer contains one of: `VERSION_NEUTRAL`)
5. no match: callNextHandler calls next(), the request falls through to the next route (counted when the answer contains one of: `callNextHandler`, `next()`)
6. URI versioning: no filter; RoutePathFactory.create puts prefix + version in the path, getVersionPrefix defaults to 'v' (counted when the answer contains one of: `getVersionPrefix`, `versionPrefix`)
