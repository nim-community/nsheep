##
## HTTP server - Mummy-based, explicit error handling
## No async - one thread per request is fine for this workload
##

import std/[json, strutils, options, times, os, osproc, hashes, sets, tables, algorithm, sequtils]
import mummy, mummy/routers
import chronicles
import nsheep/[types, storage, config]
import minhash
from puppy import get

# --- State ---

type
  SimilarEntry* = tuple[name: string, jaccard: float]

  ServerState* = object
    cfg*: Config
    similarities*: TableRef[string, seq[SimilarEntry]]

proc openStore(state: ptr ServerState): DbStorage =
  ## Each request gets its own DB connection — SQLite connections are NOT thread-safe.
  ## Uses openStorage (not initStorage) to avoid schema creation on every request.
  openStorage(state.cfg.local.dbPath, state.cfg.local.tarballDir)

# --- Helpers ---

proc addSecurityHeaders(headers: var HttpHeaders) =
  headers["X-Content-Type-Options"] = "nosniff"
  headers["X-Frame-Options"] = "DENY"
  headers["Referrer-Policy"] = "strict-origin-when-cross-origin"

proc sendError(request: Request, status: int, error, message: string) =
  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Cache-Control"] = "no-store"
  addSecurityHeaders(headers)

  let body = %*{
    "error": error,
    "message": message,
    "timestamp": $now()
  }

  request.respond(status, headers, pretty(body))

proc sendJson(request: Request, data: JsonNode, cacheSeconds: int = 0) =
  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Access-Control-Allow-Origin"] = "*"
  addSecurityHeaders(headers)

  if cacheSeconds > 0:
    headers["Cache-Control"] = "public, max-age=" & $cacheSeconds
  else:
    headers["Cache-Control"] = "no-store"

  request.respond(200, headers, pretty(data))

# --- Handlers ---

proc baseUrl(state: ptr ServerState, request: Request): string =
  ## Resolve public base URL: config override, then Host header, then fallback
  if state.cfg.server.baseUrl.len > 0:
    return state.cfg.server.baseUrl
  if "Host" in request.headers:
    return "http://" & request.headers["Host"]
  return "http://" & state.cfg.server.bindAddr & ":" & $state.cfg.server.port

proc handlePackagesJson(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    let summaries = listPackageSummaries(store)
    let pubUrl = baseUrl(state, request)

    var arr = newJArray()
    for s in summaries:
      if s.latestVersion.len == 0:
        continue # Skip packages with no downloadable versions

      var tags = newJArray()
      for t in s.tags:
        tags.add( % t)

      arr.add(%*{
        "name": s.name,
        "url": pubUrl & "/download/" & s.name,
        "method": "http",
        "description": s.description,
        "license": s.license,
        "tags": tags,
        "web": s.url
      })

    var headers = emptyHttpHeaders()
    headers["Content-Type"] = "application/json"
    headers["Access-Control-Allow-Origin"] = "*"
    headers["Cache-Control"] = "public, max-age=300" # 5 min cache
    addSecurityHeaders(headers)
    request.respond(200, headers, pretty(arr))

proc handleHealth(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let body = %*{
      "status": "ok",
      "version": Version,
      "timestamp": $now()
    }
    sendJson(request, body)

proc handleGetPackage(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    let nameStr = request.pathParams["name"]

    # Validate name
    let name = try:
      nameStr
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return

    # Load from storage
    let pkg = try:
      loadPackage(store, name)
    except storage.NotFoundError:
      sendError(request, 404, "not_found", "package not found: " & nameStr)
      return
    except storage.StorageError as e:
      sendError(request, 500, "storage_error", e.msg)
      return

    # Build response
    var versionsJson = newJArray()
    for v in pkg.versions:
      versionsJson.add(%*{
        "version": versionStr(v),
        "size": v.size,
        "checksum": $v.checksum,
        "publishedAt": v.publishedAt.toTime.toUnix
      })

    let body = %*{
      "name": $pkg.name,
      "description": pkg.description,
      "author": pkg.author,
      "license": pkg.license,
      "url": pkg.url,
      "tags": pkg.tags,
      "versions": versionsJson
    }

    sendJson(request, body, cacheSeconds = 3600) # 1 hour cache

proc handleListPackages(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    var page = 1
    var limit = 50
    var sort = "updated_desc"
    var search = ""
    var author = ""
    var tag = ""

    try:
      if "page" in request.queryParams:
        page = parseInt(request.queryParams["page"])
      if "limit" in request.queryParams:
        limit = parseInt(request.queryParams["limit"])
      if "sort" in request.queryParams:
        sort = request.queryParams["sort"]
        if sort notin ["updated_desc", "published_desc"]:
          sendError(request, 400, "invalid_params", "sort must be updated_desc or published_desc")
          return
      if "q" in request.queryParams:
        search = request.queryParams["q"]
      if "author" in request.queryParams:
        author = request.queryParams["author"]
      if "tag" in request.queryParams:
        tag = request.queryParams["tag"]
    except ValueError:
      sendError(request, 400, "invalid_params", "page and limit must be integers")
      return

    if page < 1:
      page = 1
    if limit < 1:
      limit = 1
    elif limit > 200:
      limit = 200

    let offset = (page - 1) * limit

    let summaries = listPackageSummariesPaged(store, offset, limit, sort, search, author, tag)
    let total = countPackages(store, search, author, tag)

    var arr = newJArray()
    for s in summaries:
      var tags = newJArray()
      for t in s.tags:
        tags.add( % t)
      arr.add(%*{
        "name": s.name,
        "description": s.description,
        "author": s.author,
        "license": s.license,
        "url": s.url,
        "tags": tags,
        "latestVersion": s.latestVersion,
        "latestVersionPublishedAt": s.latestVersionPublishedAt
      })

    let body = %*{
      "packages": arr,
      "total": total,
      "page": page,
      "limit": limit
    }

    sendJson(request, body, cacheSeconds = 0)

proc handleValidations(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    let nameStr = request.pathParams["name"]

    # Parse name
    let name = try:
      nameStr
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return

    # Load validations
    let results = getLatestValidationResults(store, nameStr)

    var arr = newJArray()
    for r in results:
      arr.add(%*{
        "version": r.version,
        "success": r.success,
        "testedAt": r.testedAt.toTime.toUnix
      })

    sendJson(request, arr, cacheSeconds = 300)

proc handleReadme(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    let nameStr = request.pathParams["name"]

    # Parse name
    let name = try:
      nameStr
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return

    # Load package
    let pkg = try:
      loadPackage(store, name)
    except storage.NotFoundError:
      sendError(request, 404, "not_found", "package not found: " & nameStr)
      return
    except storage.StorageError as e:
      sendError(request, 500, "storage_error", e.msg)
      return

    # Determine version
    var versionStr = ""
    if "version" in request.queryParams:
      versionStr = request.queryParams["version"]
    else:
      if pkg.versions.len > 0:
        versionStr = types.versionStr(pkg.versions[0])

    if versionStr == "":
      sendError(request, 404, "not_found", "no versions found for package: " & nameStr)
      return

    # Load README from storage
    let readmeData = try:
      loadReadme(store, nameStr, versionStr)
    except storage.NotFoundError:
      sendError(request, 404, "not_found", "readme not found for version: " & versionStr)
      return
    except storage.StorageError as e:
      sendError(request, 500, "storage_error", e.msg)
      return

    var headers = emptyHttpHeaders()
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Access-Control-Allow-Origin"] = "*"
    addSecurityHeaders(headers)
    let json = %*{
      "filename": readmeData.filename,
      "content": readmeData.content
    }
    request.respond(200, headers, $json)

proc handleDownloads(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    let nameStr = request.pathParams["name"]

    # Parse name
    let name = try:
      nameStr
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return

    # Load download stats
    let stats = getDownloadStats(store, name)

    var arr = newJArray()
    for s in stats:
      arr.add(%*{
        "version": s.version,
        "downloads": s.downloads
      })

    sendJson(request, arr, cacheSeconds = 0)

proc handleStats(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    let stats = getPackageStats(store)
    let topDownloaded = getTopPackagesByDownloads(store, 10)
    let topAuthors = getTopAuthors(store, 10)
    let licenses = getLicenseDistribution(store)
    let hosts = getHostDistribution(store)
    let topTags = getTopTags(store, 20)
    let repoNotFound = getFailedPackages(store, "repo_not_found")
    let largestPackages = getLargestPackages(store, 20)

    var topDlJson = newJArray()
    for p in topDownloaded:
      topDlJson.add(%*{"name": p.name, "downloads": p.downloads})

    var authorsJson = newJArray()
    for a in topAuthors:
      authorsJson.add(%*{"name": a.name, "packageCount": a.packageCount})

    var licensesJson = newJArray()
    var othersCount = 0
    for l in licenses:
      if l.count < 20:
        othersCount += l.count
      else:
        licensesJson.add(%*{"license": l.license, "count": l.count})
    if othersCount > 0:
      licensesJson.add(%*{"license": "others", "count": othersCount})

    var hostsJson = newJArray()
    for h in hosts:
      hostsJson.add(%*{"host": h.host, "count": h.count})

    var tagsJson = newJArray()
    for t in topTags:
      tagsJson.add(%*{"tag": t.tag, "count": t.count})

    var repoNotFoundJson = newJArray()
    for fp in repoNotFound:
      repoNotFoundJson.add(%*{"name": fp.name, "url": fp.url})

    var largestJson = newJArray()
    for lp in largestPackages:
      largestJson.add(%*{"name": lp.name, "url": lp.url, "totalSize": lp.totalSize, "versionCount": lp.versionCount})

    let body = %*{
      "totalPackages": stats.totalPackages,
      "totalAuthors": stats.totalAuthors,
      "totalDownloads": stats.totalDownloads,
      "topDownloaded": topDlJson,
      "topAuthors": authorsJson,
      "licenses": licensesJson,
      "hosts": hostsJson,
      "topTags": tagsJson,
      "repoNotFoundCount": repoNotFound.len,
      "repoNotFound": repoNotFoundJson,
      "largestPackages": largestJson
    }

    sendJson(request, body, cacheSeconds = 300)

const
  UpstreamPackagesUrl = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
  UpstreamCachePath = "/tmp/nsheep-upstream-packages.json"
  PatchCachePath = "/tmp/nsheep-packages-patch.patch"
  CacheTtlSeconds = 24 * 60 * 60 # 24 hours

proc isCacheStale(path: string, ttl: int): bool =
  if not fileExists(path):
    return true
  let age = int(getTime().toUnix - getFileInfo(path).lastWriteTime.toUnix)
  return age > ttl

proc fetchUpstreamPackagesJson(): string =
  ## Fetch upstream packages.json, using disk cache if fresh.
  if not isCacheStale(UpstreamCachePath, CacheTtlSeconds):
    return readFile(UpstreamCachePath)

  info "Fetching upstream packages.json"
  let response = get(UpstreamPackagesUrl, timeout = 30)
  if response.code != 200:
    raise newException(IOError, "failed to fetch packages.json: HTTP " & $response.code)

  writeFile(UpstreamCachePath, response.body)
  return response.body

proc generatePackagesJsonPatch(state: ptr ServerState): string =
  ## Generate a git patch that removes repo_not_found packages from upstream packages.json
  let upstreamJson = fetchUpstreamPackagesJson()
  let store = openStore(state)
  defer: store.close()
  let failedPkgs = getFailedPackages(store, "repo_not_found")

  if failedPkgs.len == 0:
    return "# No repo_not_found packages to remove.\n"

  # Build a hash set for fast lookup
  var failedNames = initHashSet[string]()
  for fp in failedPkgs:
    failedNames.incl(fp.name)

  # Parse upstream JSON
  let parsed = parseJson(upstreamJson)
  if parsed.kind != JArray:
    raise newException(ValueError, "upstream packages.json is not an array")

  # Filter out repo_not_found entries
  var filtered = newJArray()
  for pkg in parsed:
    if pkg.hasKey("name") and failedNames.contains(pkg["name"].getStr()):
      continue
    filtered.add(pkg)

  # Write both versions to temp files for diff
  let originalPath = "/tmp/nsheep-packages-original.json"
  let filteredPath = "/tmp/nsheep-packages-filtered.json"
  writeFile(originalPath, upstreamJson)
  writeFile(filteredPath, pretty(filtered, 2))

  # Generate unified diff
  let (diffOutput, exitCode) = execCmdEx(
    "diff -u --label a/packages.json --label b/packages.json " & originalPath & " " & filteredPath
  )

  if exitCode != 0 and exitCode != 1:
    # diff returns 1 when files differ (normal), non-zero non-1 is an error
    warn "diff command failed", exitCode = exitCode, output = diffOutput
    raise newException(IOError, "diff command failed with exit code " & $exitCode)

  # Prepend git diff header
  result = "diff --git a/packages.json b/packages.json\n" & diffOutput

proc handlePackagesJsonPatch(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    try:
      let patch = generatePackagesJsonPatch(state)
      var headers = emptyHttpHeaders()
      headers["Content-Type"] = "text/plain; charset=utf-8"
      # Served as plain text so browsers can view it directly
      headers["Cache-Control"] = "public, max-age=3600" # 1 hour cache for the patch itself
      addSecurityHeaders(headers)
      request.respond(200, headers, patch)
    except CatchableError as e:
      error "Failed to generate packages.json patch", error = e.msg
      sendError(request, 500, "patch_error", "failed to generate patch: " & e.msg)

proc handleDownload(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    let nameStr = request.pathParams["name"]
    let versionStr = request.pathParams["version"]

    # Parse name
    let name = try:
      nameStr
    except ValueError as e:
      sendError(request, 400, "invalid_name", e.msg)
      return

    # Parse version (semver or branch/ref like head, main, etc.)
    var version: SemVer
    var refName = ""
    let optVer = parseSemVer(versionStr)
    if optVer.isSome:
      version = optVer.get()
    else:
      refName = versionStr
      version = initSemVer(0, 0, 0)

    # Record download
    try:
      recordDownload(store, nameStr, versionStr)
    except storage.StorageError as e:
      error "Failed to record download", package = nameStr, version = versionStr, error = e.msg

    # Look up tarball path
    let tarPath = try:
      getTarballPath(store, name, version, refName)
    except storage.NotFoundError:
      sendError(request, 404, "not_found", "tarball not found: " & nameStr & "@" & versionStr)
      return
    except storage.StorageError as e:
      sendError(request, 500, "storage_error", e.msg)
      return

    # Read file directly as string (avoid seq[byte] -> string copy)
    let strData = try:
      readFile(tarPath)
    except CatchableError as e:
      sendError(request, 500, "read_error", "cannot read tarball: " & e.msg)
      return

    # Serve with appropriate headers
    var headers = emptyHttpHeaders()
    headers["Content-Type"] = "application/gzip"
    headers["Content-Disposition"] = "attachment; filename=\"" & $name & "-" & versionStr & ".tar.gz\""
    headers["Cache-Control"] = "public, max-age=31536000, immutable" # 1 year
    headers["Access-Control-Allow-Origin"] = "*"
    addSecurityHeaders(headers)

    request.respond(200, headers, strData)

proc handleDownloadLatest(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let store = openStore(state)
    defer: store.close()
    let nameStr = request.pathParams["name"]

    # Record download as head
    try:
      recordDownload(store, nameStr, "#head")
    except storage.StorageError as e:
      error "Failed to record download", package = nameStr, version = "#head", error = e.msg

    # Look up head tarball path
    let tarPath = try:
      getTarballPath(store, nameStr, initSemVer(0, 0, 0), "head")
    except storage.NotFoundError:
      sendError(request, 404, "not_found", "tarball not found: " & nameStr)
      return
    except storage.StorageError as e:
      sendError(request, 500, "storage_error", e.msg)
      return

    # Read file directly as string (avoid seq[byte] -> string copy)
    let strData = try:
      readFile(tarPath)
    except CatchableError as e:
      sendError(request, 500, "read_error", "cannot read tarball: " & e.msg)
      return

    # Serve with appropriate headers
    var headers = emptyHttpHeaders()
    headers["Content-Type"] = "application/gzip"
    headers["Content-Disposition"] = "attachment; filename=\"" & $nameStr & "-#head.tar.gz\""
    headers["Cache-Control"] = "public, max-age=31536000, immutable" # 1 year
    headers["Access-Control-Allow-Origin"] = "*"
    addSecurityHeaders(headers)

    request.respond(200, headers, strData)

# --- Static Files ---

proc serveStaticFile(state: ptr ServerState, fileName: string): RequestHandler =
  result = proc(request: Request) =
    let filePath = state.cfg.server.publicDir / fileName
    if not fileExists(filePath):
      var headers = emptyHttpHeaders()
      addSecurityHeaders(headers)
      request.respond(404, headers, "not found")
      return

    let ext = splitFile(filePath).ext
    let contentType = case ext
    of ".js": "application/javascript"
    of ".css": "text/css"
    of ".html": "text/html"
    of ".txt": "text/plain; charset=utf-8"
    of ".svg": "image/svg+xml"
    else: "application/octet-stream"

    let data = readFile(filePath)
    var headers = emptyHttpHeaders()
    headers["Content-Type"] = contentType
    addSecurityHeaders(headers)
    request.respond(200, headers, data)

proc serveIndex(state: ptr ServerState): RequestHandler =
  result = serveStaticFile(state, "index.html")

# --- Setup ---

proc initSimilarities*(state: ptr ServerState) =
  ## Pre-compute package similarities from version_hashes at startup
  state.similarities = newTable[string, seq[SimilarEntry]]()
  let store = openStore(state)
  defer: store.close()

  let hashes = try:
    getVersionHashes(store)
  except CatchableError:
    warn "Failed to load version hashes for similarity computation"
    return

  if hashes.len < 2:
    return

  const NumSeeds = 128
  const NumBands = 16
  const MinJaccard = 0.35

  var dummyHasher = initMinHasher[uint32](NumSeeds, proc(s: string): seq[string] = @[])
  var lsh = initLocalitySensitive(dummyHasher, num_bands = NumBands)

  for h in hashes:
    if h.hash.len > 0:
      lsh.add(h.hash, h.pkgName)

  let dupes = lsh.getDuplicates(min_jaccard = MinJaccard)
  info "LSH found candidate pairs", candidates = dupes.len
  var passed = 0
  for p in dupes:
    let (a, b) = if p.a < p.b: (p.a, p.b) else: (p.b, p.a)
    let fpA = hashes.filterIt(it.pkgName == a)[0].hash
    let fpB = hashes.filterIt(it.pkgName == b)[0].hash
    let j = dummyHasher.jaccard(fpA, fpB)
    if j < MinJaccard:
      continue
    inc passed
    state.similarities.mgetOrPut(a, @[]).add((name: b, jaccard: j))
    state.similarities.mgetOrPut(b, @[]).add((name: a, jaccard: j))

  # Sort each list by jaccard descending
  for name, entries in state.similarities.mpairs:
    algorithm.sort(entries, proc(x, y: SimilarEntry): int =
      if x.jaccard > y.jaccard: -1
      elif x.jaccard < y.jaccard: 1
      else: 0
    )

  info "LSH passed exact jaccard filter", pairs = passed
  # Debug: print first 5 packages with similarities
  var first5: seq[string] = @[]
  for name, entries in state.similarities:
    if first5.len < 5:
      first5.add(name & " (" & $entries.len & ")")
  info "Sample packages with similar", samples = first5.join(", ")
  info "Computed package similarities", count = state.similarities.len

proc handleGetSimilarPackages(state: ptr ServerState): RequestHandler =
  result = proc(request: Request) =
    let name = request.pathParams["name"]
    let entries = state.similarities.getOrDefault(name, @[])
    var arr = newJArray()
    for e in entries:
      arr.add(%*{"name": e.name, "jaccard": e.jaccard})
    sendJson(request, arr, cacheSeconds = 3600)

proc setupRoutes*(router: var Router, state: ptr ServerState) =
  router.get("/health", handleHealth(state))
  router.get("/packages.json", handlePackagesJson(state))
  router.get("/api/v1/packages", handleListPackages(state))
  router.get("/api/v1/packages/@name", handleGetPackage(state))
  router.get("/api/v1/packages/@name/similar", handleGetSimilarPackages(state))
  # Note: Ingestion is now handled automatically by background fetcher
  router.get("/api/v1/packages/@name/validations", handleValidations(state))
  router.get("/api/v1/packages/@name/readme", handleReadme(state))
  router.get("/api/v1/packages/@name/downloads", handleDownloads(state))
  router.get("/api/v1/stats", handleStats(state))
  router.get("/packages.json.patch", handlePackagesJsonPatch(state))
  router.head("/packages.json.patch", handlePackagesJsonPatch(state))
  router.get("/download/@name", handleDownloadLatest(state))
  router.get("/download/@name/@version", handleDownload(state))

  # Static frontend assets
  router.get("/", serveIndex(state))
  router.get("/llm.txt", serveStaticFile(state, "llm.txt"))
  router.get("/app.js", serveStaticFile(state, "app.js"))
  router.get("/app.css", serveStaticFile(state, "app.css"))
  router.get("/robot.svg", serveStaticFile(state, "robot.svg"))
  router.get("/theme.js", serveStaticFile(state, "theme.js"))

  # SPA catch-all: serve index.html for any non-API route
  router.get("/**", serveIndex(state))

  # CORS preflight
  router.options("/*", proc(request: Request) =
    var headers = emptyHttpHeaders()
    headers["Access-Control-Allow-Origin"] = "*"
    headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    headers["Access-Control-Allow-Headers"] = "Content-Type"
    addSecurityHeaders(headers)
    request.respond(204, headers, "")
  )

# --- Main ---

proc runServer*(cfg: Config) =
  ## Run the HTTP server

  # Initialize state
  var state: ServerState
  state.cfg = cfg

  # Pre-compute similarities
  initSimilarities(addr state)

  # Setup router
  var router = Router()
  setupRoutes(router, addr state)

  # Start server
  let server = newServer(router)
  info "Server starting", address = cfg.server.bindAddr, port = cfg.server.port
  info "Server listening", address = cfg.server.bindAddr, port = cfg.server.port
  server.serve(Port(cfg.server.port), cfg.server.bindAddr)
