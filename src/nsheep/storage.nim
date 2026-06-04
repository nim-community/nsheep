##
## Storage abstraction
## SQLite for metadata, filesystem for tarballs
##

import std/[times, os, sequtils, json, options, tables, algorithm]
import tiny_sqlite
import chronicles
import ./types

# --- Errors ---

type
  StorageError* = object of CatchableError
  NotFoundError* = object of StorageError

# --- Database Schema ---

const Schema = """
-- Packages table
CREATE TABLE IF NOT EXISTS packages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    description TEXT,
    author TEXT,
    license TEXT,
    url TEXT NOT NULL,
    tags TEXT,
    created_at INTEGER DEFAULT (unixepoch()),
    updated_at INTEGER DEFAULT (unixepoch())
);

-- Versions table (metadata only, no tarball blob)
CREATE TABLE IF NOT EXISTS versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_id INTEGER NOT NULL,
    major INTEGER NOT NULL,
    minor INTEGER NOT NULL,
    patch INTEGER NOT NULL,
    head_commit TEXT,
    tarball_path TEXT NOT NULL,  -- Path to tarball file
    tarball_size INTEGER NOT NULL,
    checksum TEXT NOT NULL,
    published_at INTEGER,
    created_at INTEGER DEFAULT (unixepoch()),
    updated_at INTEGER DEFAULT (unixepoch()),
    FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE,
    UNIQUE(package_id, major, minor, patch, head_commit)
);

-- Validation results table
CREATE TABLE IF NOT EXISTS validation_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_name TEXT NOT NULL,
    version TEXT NOT NULL,
    success INTEGER NOT NULL,
    output TEXT,
    duration_ms INTEGER,
    tested_at INTEGER DEFAULT (unixepoch()),
    UNIQUE(package_name, version)
);

-- Download statistics table
CREATE TABLE IF NOT EXISTS download_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_name TEXT NOT NULL,
    version TEXT NOT NULL,
    downloads INTEGER DEFAULT 0,
    UNIQUE(package_name, version)
);

-- README contents per version
CREATE TABLE IF NOT EXISTS readmes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_name TEXT NOT NULL,
    version TEXT NOT NULL,
    filename TEXT DEFAULT '',
    content TEXT NOT NULL,
    fetched_at INTEGER DEFAULT (unixepoch()),
    UNIQUE(package_name, version)
);

-- Permanently failed packages (deleted/invalid repos)
CREATE TABLE IF NOT EXISTS failed_packages (
    name TEXT PRIMARY KEY,
    failed_at INTEGER DEFAULT (unixepoch()),
    reason TEXT,
    url TEXT
);

-- Pre-computed MinHash signatures per version (currently only head versions)
CREATE TABLE IF NOT EXISTS version_hashes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_id INTEGER NOT NULL,
    version_id INTEGER NOT NULL UNIQUE,
    hash BLOB NOT NULL,
    text_length INTEGER NOT NULL,
    algo_version INTEGER DEFAULT 1,
    created_at INTEGER DEFAULT (unixepoch()),
    FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE,
    FOREIGN KEY (version_id) REFERENCES versions(id) ON DELETE CASCADE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_packages_name ON packages(name);
CREATE INDEX IF NOT EXISTS idx_versions_package ON versions(package_id);
CREATE INDEX IF NOT EXISTS idx_validation_package ON validation_results(package_name);
CREATE INDEX IF NOT EXISTS idx_downloads_package ON download_stats(package_name);
CREATE INDEX IF NOT EXISTS idx_readmes_package ON readmes(package_name);
CREATE INDEX IF NOT EXISTS idx_failed_package ON failed_packages(name);
"""

# --- Types ---

type
  DbStorage* = object
    db*: DbConn
    dbPath*: string
    tarballDir*: string # Filesystem directory for tarballs

# --- Initialization ---

proc initStorage*(dbPath: string, tarballDir: string): DbStorage =
  ## Initialize SQLite storage + filesystem tarball storage (run once at startup)
  result.dbPath = dbPath
  result.tarballDir = tarballDir
  result.db = openDatabase(dbPath)

  # Wait up to 10s when the database is locked by another connection
  result.db.exec("PRAGMA busy_timeout = 10000")
  result.db.exec("PRAGMA journal_mode = WAL")

  # Keep WAL file small: auto-checkpoint every 100 pages (400KB)
  result.db.exec("PRAGMA wal_autocheckpoint = 100")

  # Create tables
  result.db.execScript(Schema)

  # Migration: add columns for existing databases
  try:
    result.db.exec("ALTER TABLE versions ADD COLUMN head_commit TEXT")
  except CatchableError:
    discard
  try:
    result.db.exec("ALTER TABLE versions ADD COLUMN updated_at INTEGER DEFAULT (unixepoch())")
  except CatchableError:
    discard
  try:
    result.db.exec("ALTER TABLE failed_packages ADD COLUMN url TEXT")
  except CatchableError:
    discard

  # Create tarball directory
  createDir(tarballDir)

  info "Storage initialized", dbPath = dbPath, tarballDir = tarballDir

proc openStorage*(dbPath: string, tarballDir: string): DbStorage =
  ## Open an existing SQLite storage connection (for per-request use).
  ## Does NOT run schema creation — assumes initStorage was already called.
  result.dbPath = dbPath
  result.tarballDir = tarballDir
  result.db = openDatabase(dbPath)
  result.db.exec("PRAGMA busy_timeout = 10000")

proc close*(s: DbStorage) =
  ## Close database connection
  s.db.close()

proc walCheckpoint*(s: DbStorage) =
  ## Force WAL checkpoint to keep the WAL file small.
  ## Only works when there are no active concurrent readers.
  try:
    s.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
  except CatchableError:
    discard

# --- Package Operations ---

proc storePackage*(s: DbStorage, pkg: Package) =
  ## Store or update a package. Does NOT touch updated_at on conflict —
  ## caller must call touchPackage() after successful ingest to bump the timestamp.
  let tagsJson = $ %* pkg.tags

  s.db.exec("""
    INSERT INTO packages (name, description, author, license, url, tags, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, unixepoch(), unixepoch())
    ON CONFLICT(name) DO UPDATE SET
      description = excluded.description,
      author = excluded.author,
      license = excluded.license,
      url = excluded.url,
      tags = excluded.tags,
      created_at = COALESCE(packages.created_at, unixepoch())
  """, pkg.name, pkg.description, pkg.author, pkg.license, pkg.url, tagsJson)

proc touchPackage*(s: DbStorage, pkgName: string) =
  ## Bump updated_at to mark a successful full ingest. Used by the fetcher
  ## to distinguish "metadata stored but ingest crashed" from "fully processed".
  s.db.exec("""
    UPDATE packages SET updated_at = unixepoch() WHERE name = ?
  """, pkgName)

proc loadPackage*(s: DbStorage, name: string): Package =
  ## Load package by name
  let row = s.db.one("""
    SELECT name, description, author, license, url, tags, CAST(created_at AS INTEGER), CAST(updated_at AS INTEGER)
    FROM packages WHERE name = ?
  """, name)

  if row.isNone:
    raise newException(NotFoundError, "package not found: " & name)

  let r = row.get()
  result.name = name
  result.description = if r[1].kind == sqliteNull: "" else: r[1].strVal
  result.author = if r[2].kind == sqliteNull: "" else: r[2].strVal
  result.license = if r[3].kind == sqliteNull: "" else: r[3].strVal
  result.url = r[4].strVal
  # Parse tags JSON
  let tagsStr = if r[5].kind == sqliteNull: "[]" else: r[5].strVal
  try:
    let tagsJson = parseJson(tagsStr)
    result.tags = tagsJson.getElems().mapIt(it.getStr())
  except CatchableError as e:
    warn "Failed to parse package tags", name = name, error = e.msg
    result.tags = @[]

  # Parse timestamps
  if r[6].kind == sqliteNull:
    result.createdAt = now()
  else:
    result.createdAt = fromUnix(r[6].intVal).local()
  if r[7].kind == sqliteNull:
    result.updatedAt = now()
  else:
    result.updatedAt = fromUnix(r[7].intVal).local()

  # Load versions
  for vrow in s.db.all("""
    SELECT major, minor, patch, head_commit, tarball_path, tarball_size, checksum, CAST(published_at AS INTEGER)
    FROM versions
    WHERE package_id = (SELECT id FROM packages WHERE name = ?)
    ORDER BY major DESC, minor DESC, patch DESC
  """, name):
    let ver = initSemVer(vrow[0].intVal.int, vrow[1].intVal.int, vrow[2].intVal.int)
    let refName = if vrow[3].kind == sqliteNull: "" else: vrow[3].strVal
    let checksum = initChecksum(vrow[6].strVal)
    let publishedAt = if vrow[7].kind == sqliteNull: now() else: fromUnix(vrow[7].intVal).local()
    result.versions.add(PackageVersion(
      version: ver,
      headCommit: refName,
      tarballPath: vrow[4].strVal,
      checksum: checksum,
      size: vrow[5].intVal,
      publishedAt: publishedAt
    ))

proc listPackages*(s: DbStorage): seq[string] =
  ## List all package names
  for row in s.db.all("SELECT name FROM packages ORDER BY name"):
    result.add(row[0].strVal)

# --- Summary Operations ---

type
  PackageSummary* = object
    name*: string
    description*: string
    author*: string
    license*: string
    url*: string
    tags*: seq[string]
    latestVersion*: string
    createdAt*: int64
    updatedAt*: int64
    latestVersionPublishedAt*: int64

proc listPackageSummaries*(s: DbStorage): seq[PackageSummary] =
  ## List all packages with metadata and latest version
  for row in s.db.all("""
    SELECT p.name, p.description, p.author, p.license, p.url, p.tags, CAST(p.created_at AS INTEGER), CAST(p.updated_at AS INTEGER),
           v.major, v.minor, v.patch, v.head_commit, CAST(v.published_at AS INTEGER)
    FROM packages p
    LEFT JOIN versions v ON v.id = (
      SELECT id FROM versions
      WHERE package_id = p.id
      ORDER BY CASE WHEN head_commit IS NULL THEN 0 ELSE 1 END,
               major DESC, minor DESC, patch DESC
      LIMIT 1
    )
    ORDER BY p.name
  """):
    var tags: seq[string] = @[]
    let tagsStr = if row[5].kind == sqliteNull: "[]" else: row[5].strVal
    try:
      let tagsJson = parseJson(tagsStr)
      tags = tagsJson.getElems().mapIt(it.getStr())
    except CatchableError as e:
      warn "Failed to parse package tags in summary", tags = tagsStr, error = e.msg

    var latestVersion = ""
    if row[8].kind != sqliteNull:
      let refName = if row[11].kind == sqliteNull: "" else: row[11].strVal
      if refName.len > 0:
        latestVersion = "#head"
      else:
        latestVersion = $row[8].intVal & "." & $row[9].intVal & "." & $row[10].intVal

    result.add(PackageSummary(
      name: row[0].strVal,
      description: if row[1].kind == sqliteNull: "" else: row[1].strVal,
      author: if row[2].kind == sqliteNull: "" else: row[2].strVal,
      license: if row[3].kind == sqliteNull: "" else: row[3].strVal,
      url: row[4].strVal,
      tags: tags,
      latestVersion: latestVersion,
      createdAt: if row[6].kind != sqliteNull: row[6].intVal else: 0,
      updatedAt: if row[7].kind != sqliteNull: row[7].intVal else: 0,
      latestVersionPublishedAt: if row[12].kind != sqliteNull: row[12].intVal else: 0
    ))

proc listPackageSummariesPaged*(s: DbStorage, offset, limit: int,
    sort: string = "updated_desc", search: string = "",
    author: string = "", tag: string = ""): seq[PackageSummary] =
  ## List packages with metadata and latest version, paginated
  let orderBy = case sort
    of "published_desc": "p.created_at DESC"
    of "updated_desc": "p.updated_at DESC"
    else: "p.updated_at DESC"
  let searchPattern = if search.len > 0: "%" & search & "%" else: ""
  let tagPattern = if tag.len > 0: "%\"" & tag & "\"%" else: ""
  for row in s.db.all("""
    SELECT p.name, p.description, p.author, p.license, p.url, p.tags, CAST(p.created_at AS INTEGER), CAST(p.updated_at AS INTEGER),
           v.major, v.minor, v.patch, v.head_commit, CAST(v.published_at AS INTEGER)
    FROM packages p
    LEFT JOIN versions v ON v.id = (
      SELECT id FROM versions
      WHERE package_id = p.id
      ORDER BY CASE WHEN head_commit IS NULL THEN 0 ELSE 1 END,
               major DESC, minor DESC, patch DESC
      LIMIT 1
    )
    WHERE (? = '' OR p.name LIKE ? OR p.description LIKE ?)
      AND (? = '' OR p.author = ?)
      AND (? = '' OR p.tags LIKE ?)
    ORDER BY """ & orderBy & """
    LIMIT ? OFFSET ?
  """, searchPattern, searchPattern, searchPattern,
      author, author,
      tagPattern, tagPattern,
      limit.int64, offset.int64):
    var tags: seq[string] = @[]
    let tagsStr = if row[5].kind == sqliteNull: "[]" else: row[5].strVal
    try:
      let tagsJson = parseJson(tagsStr)
      tags = tagsJson.getElems().mapIt(it.getStr())
    except CatchableError as e:
      warn "Failed to parse package tags in search", tags = tagsStr, error = e.msg

    var latestVersion = ""
    if row[8].kind != sqliteNull:
      let refName = if row[11].kind == sqliteNull: "" else: row[11].strVal
      if refName.len > 0:
        latestVersion = "#head"
      else:
        latestVersion = $row[8].intVal & "." & $row[9].intVal & "." & $row[10].intVal

    result.add(PackageSummary(
      name: row[0].strVal,
      description: if row[1].kind == sqliteNull: "" else: row[1].strVal,
      author: if row[2].kind == sqliteNull: "" else: row[2].strVal,
      license: if row[3].kind == sqliteNull: "" else: row[3].strVal,
      url: row[4].strVal,
      tags: tags,
      latestVersion: latestVersion,
      createdAt: if row[6].kind != sqliteNull: row[6].intVal else: 0,
      updatedAt: if row[7].kind != sqliteNull: row[7].intVal else: 0,
      latestVersionPublishedAt: if row[12].kind != sqliteNull: row[12].intVal else: 0
    ))

proc countPackages*(s: DbStorage, search: string = "",
    author: string = "", tag: string = ""): int =
  ## Return total number of packages matching filters
  let searchPattern = if search.len > 0: "%" & search & "%" else: ""
  let tagPattern = if tag.len > 0: "%\"" & tag & "\"%" else: ""
  let row = s.db.one("""
    SELECT COUNT(*) FROM packages p
    WHERE (? = '' OR p.name LIKE ? OR p.description LIKE ?)
      AND (? = '' OR p.author = ?)
      AND (? = '' OR p.tags LIKE ?)
  """, searchPattern, searchPattern, searchPattern,
      author, author,
      tagPattern, tagPattern)
  if row.isSome:
    result = row.get()[0].intVal.int
  else:
    result = 0

# --- Version/Tarball Operations ---

proc tarballPath*(s: DbStorage, pkgName: string, ver: SemVer, refName: string = ""): string =
  ## Get filesystem path for tarball
  let versionStr = if refName.len > 0: "#head" else: $ver.major & "." & $ver.minor & "." & $ver.patch
  s.tarballDir / pkgName & "-" & versionStr & ".tar.gz"

proc storeVersion*(
  s: DbStorage,
  pkgName: string,
  ver: SemVer,
  tarball: seq[byte],
  checksum: Checksum,
  publishedAt: DateTime,
  refName: string = ""
) =
  ## Store a version - tarball to filesystem, metadata to SQLite
  # Get package id
  let pkgRow = s.db.one("SELECT id FROM packages WHERE name = ?", pkgName)
  if pkgRow.isNone:
    raise newException(NotFoundError, "package not found: " & pkgName)

  let pkgId = pkgRow.get()[0].intVal

  # Write tarball to filesystem
  let tarPath = s.tarballPath(pkgName, ver, refName)
  createDir(tarPath.parentDir)

  var f: File
  if open(f, tarPath, fmWrite):
    defer: close(f)
    if tarball.len > 0:
      discard f.writeBuffer(unsafeAddr tarball[0], tarball.len)
  else:
    raise newException(StorageError, "cannot write tarball: " & tarPath)

  # Store metadata in SQLite
  if refName.len > 0:
    s.db.exec("""
      INSERT INTO versions (package_id, major, minor, patch, head_commit, tarball_path, tarball_size, checksum, published_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, unixepoch())
      ON CONFLICT DO UPDATE SET
        tarball_path = excluded.tarball_path,
        tarball_size = excluded.tarball_size,
        checksum = excluded.checksum,
        published_at = excluded.published_at,
        updated_at = unixepoch()
    """, pkgId, ver.major.int64, ver.minor.int64, ver.patch.int64, refName, tarPath, tarball.len.int64, $checksum,
        publishedAt.toTime.toUnix)
  else:
    s.db.exec("""
      INSERT INTO versions (package_id, major, minor, patch, head_commit, tarball_path, tarball_size, checksum, published_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, unixepoch())
      ON CONFLICT DO UPDATE SET
        tarball_path = excluded.tarball_path,
        tarball_size = excluded.tarball_size,
        checksum = excluded.checksum,
        published_at = excluded.published_at,
        updated_at = unixepoch()
    """, pkgId, ver.major.int64, ver.minor.int64, ver.patch.int64, nil, tarPath, tarball.len.int64, $checksum,
        publishedAt.toTime.toUnix)

proc loadTarball*(
  s: DbStorage,
  pkgName: string,
  ver: SemVer,
  refName: string = ""
): seq[byte] =
  ## Load tarball bytes from filesystem
  let row = if refName.len > 0:
    s.db.one("""
      SELECT tarball_path FROM versions v
      JOIN packages p ON v.package_id = p.id
      WHERE p.name = ? AND v.head_commit IS NOT NULL
      ORDER BY v.major DESC, v.minor DESC, v.patch DESC
      LIMIT 1
    """, pkgName)
  else:
    s.db.one("""
      SELECT tarball_path FROM versions v
      JOIN packages p ON v.package_id = p.id
      WHERE p.name = ? AND v.major = ? AND v.minor = ? AND v.patch = ? AND v.head_commit IS NULL
    """, pkgName, ver.major.int64, ver.minor.int64, ver.patch.int64)

  if row.isNone:
    let verStr = if refName.len > 0: refName else: $ver.major & "." & $ver.minor & "." & $ver.patch
    raise newException(NotFoundError, "version not found: " & pkgName & "@" & verStr)

  let tarPath = row.get()[0].strVal
  if not fileExists(tarPath):
    raise newException(NotFoundError, "tarball file not found: " & tarPath)

  let fileSize = getFileSize(tarPath)
  result = newSeq[byte](fileSize)

  var f: File
  if open(f, tarPath, fmRead):
    defer: close(f)
    if fileSize > 0:
      discard f.readBuffer(addr result[0], fileSize)
  else:
    raise newException(StorageError, "cannot read tarball: " & tarPath)

proc getTarballPath*(
  s: DbStorage,
  pkgName: string,
  ver: SemVer,
  refName: string = ""
): string =
  ## Look up tarball filesystem path without loading bytes
  let row = if refName.len > 0:
    s.db.one("""
      SELECT tarball_path FROM versions v
      JOIN packages p ON v.package_id = p.id
      WHERE p.name = ? AND v.head_commit IS NOT NULL
      ORDER BY v.major DESC, v.minor DESC, v.patch DESC
      LIMIT 1
    """, pkgName)
  else:
    s.db.one("""
      SELECT tarball_path FROM versions v
      JOIN packages p ON v.package_id = p.id
      WHERE p.name = ? AND v.major = ? AND v.minor = ? AND v.patch = ? AND v.head_commit IS NULL
    """, pkgName, ver.major.int64, ver.minor.int64, ver.patch.int64)

  if row.isNone:
    let verStr = if refName.len > 0: refName else: $ver.major & "." & $ver.minor & "." & $ver.patch
    raise newException(NotFoundError, "version not found: " & pkgName & "@" & verStr)

  result = row.get()[0].strVal
  if not fileExists(result):
    raise newException(NotFoundError, "tarball file not found: " & result)

proc versionExists*(s: DbStorage, pkgName: string, ver: SemVer, refName: string = ""): bool =
  ## Check if version exists
  let row = if refName.len > 0:
    s.db.one("""
      SELECT 1 FROM versions v
      JOIN packages p ON v.package_id = p.id
      WHERE p.name = ? AND v.head_commit = ?
    """, pkgName, refName)
  else:
    s.db.one("""
      SELECT 1 FROM versions v
      JOIN packages p ON v.package_id = p.id
      WHERE p.name = ? AND v.major = ? AND v.minor = ? AND v.patch = ? AND v.head_commit IS NULL
    """, pkgName, ver.major.int64, ver.minor.int64, ver.patch.int64)
  return row.isSome

proc getHeadCommitSha*(s: DbStorage, pkgName: string): string =
  ## Return the stored HEAD commit SHA for a package, or empty string if none.
  let row = s.db.one("""
    SELECT v.head_commit FROM versions v
    JOIN packages p ON v.package_id = p.id
    WHERE p.name = ? AND v.major = 99999 AND v.minor = 99999 AND v.patch = 99999
    LIMIT 1
  """, pkgName)
  if row.isSome and row.get()[0].kind != sqliteNull:
    result = row.get()[0].strVal

proc deleteHeadVersions*(s: DbStorage, pkgName: string) =
  ## Remove all HEAD versions for a package so a new HEAD can replace them.
  s.db.exec("""
    DELETE FROM versions WHERE package_id = (
      SELECT id FROM packages WHERE name = ?
    ) AND major = 99999 AND minor = 99999 AND patch = 99999
  """, pkgName)

proc packageProcessedRecently*(s: DbStorage, pkgName: string, withinSeconds: int): bool =
  ## Check if the fetcher fully processed a package within the given seconds.
  ## Uses updated_at which is only bumped by touchPackage() on successful ingest.
  ## Also checks failed_packages so deleted repos are not retried every cycle.
  if withinSeconds <= 0:
    return false

  # Check failed_packages first: a recent failure takes precedence over an old success.
  # This prevents permanently-failed packages from being retried just because they
  # were once successfully ingested long ago.
  let failedRow = s.db.one("""
    SELECT CAST(failed_at AS INTEGER) FROM failed_packages
    WHERE name = ? AND failed_at IS NOT NULL
  """, pkgName)

  if failedRow.isSome:
    let failedAt = failedRow.get()[0].intVal
    return (getTime().toUnix - failedAt) < withinSeconds.int64

  let row = s.db.one("""
    SELECT CAST(updated_at AS INTEGER) FROM packages
    WHERE name = ? AND updated_at IS NOT NULL
  """, pkgName)

  if row.isSome:
    let updatedAt = row.get()[0].intVal
    return (getTime().toUnix - updatedAt) < withinSeconds.int64

  return false

proc recordFailedPackage*(s: DbStorage, pkgName: string, reason: string = "", url: string = "") =
  ## Record a permanently failed package so we don't retry it every cycle.
  s.db.exec("""
    INSERT INTO failed_packages (name, failed_at, reason, url)
    VALUES (?, unixepoch(), ?, ?)
    ON CONFLICT(name) DO UPDATE SET
      failed_at = unixepoch(),
      reason = excluded.reason,
      url = excluded.url
  """, pkgName, reason, url)

# --- Validation Result Operations ---

proc storeValidationResult*(
  s: DbStorage,
  pkgName: string,
  version: string,
  success: bool,
  output: string,
  durationMs: int
) =
  ## Store validation result
  s.db.exec("""
    INSERT INTO validation_results (package_name, version, success, output, duration_ms, tested_at)
    VALUES (?, ?, ?, ?, ?, unixepoch())
    ON CONFLICT(package_name, version) DO UPDATE SET
      success = excluded.success,
      output = excluded.output,
      duration_ms = excluded.duration_ms,
      tested_at = unixepoch()
  """, pkgName, version, success.int64, output, durationMs.int64)

proc getValidationResult*(s: DbStorage, pkgName, version: string): Option[tuple[success: bool, output: string,
    durationMs: int]] =
  ## Get validation result
  let row = s.db.one("""
    SELECT success, output, duration_ms FROM validation_results
    WHERE package_name = ? AND version = ?
  """, pkgName, version)

  if row.isSome:
    let r = row.get()
    result = some((
      success: r[0].kind != sqliteNull and r[0].intVal != 0,
      output: if r[1].kind == sqliteNull: "" else: r[1].strVal,
      durationMs: if r[2].kind == sqliteNull: 0 else: r[2].intVal.int
    ))

proc getLatestValidationResults*(s: DbStorage, pkgName: string): seq[tuple[version: string, success: bool,
    testedAt: DateTime]] =
  ## Get all validation results for a package
  for row in s.db.all("""
    SELECT version, success, CAST(tested_at AS INTEGER) FROM validation_results
    WHERE package_name = ?
    ORDER BY tested_at DESC
  """, pkgName):
    result.add((
      version: row[0].strVal,
      success: row[1].kind != sqliteNull and row[1].intVal != 0,
      testedAt: if row[2].kind == sqliteNull: now() else: fromUnix(row[2].intVal).local()
    ))

proc isFailedPackage*(s: DbStorage, pkgName: string): bool =
  ## Check if a package is permanently failed (exists in failed_packages).
  let row = s.db.one("""
    SELECT 1 FROM failed_packages WHERE name = ?
  """, pkgName)
  return row.isSome

proc validationDoneRecently*(s: DbStorage, pkgName: string, withinSeconds: int): bool =
  ## Check if any validation result exists for this package within the given seconds.
  if withinSeconds <= 0:
    return false
  let row = s.db.one("""
    SELECT CAST(tested_at AS INTEGER) FROM validation_results
    WHERE package_name = ? AND tested_at IS NOT NULL
    ORDER BY tested_at DESC
    LIMIT 1
  """, pkgName)
  if row.isNone:
    return false
  let testedAt = row.get()[0].intVal
  result = (getTime().toUnix - testedAt) < withinSeconds.int64

proc recordDownload*(s: DbStorage, pkgName: string, version: string) =
  ## Record a download for a package version
  s.db.exec("""
    INSERT INTO download_stats (package_name, version, downloads)
    VALUES (?, ?, 1)
    ON CONFLICT(package_name, version) DO UPDATE SET
      downloads = downloads + 1
  """, pkgName, version)

proc getDownloadStats*(s: DbStorage, pkgName: string): seq[tuple[version: string, downloads: int]] =
  ## Get download statistics for all versions of a package
  for row in s.db.all("""
    SELECT version, downloads FROM download_stats
    WHERE package_name = ?
    ORDER BY version DESC
  """, pkgName):
    result.add((version: row[0].strVal, downloads: row[1].intVal.int))

proc getTotalDownloads*(s: DbStorage, pkgName: string): int =
  ## Get total download count for a package
  let row = s.db.one("""
    SELECT COALESCE(SUM(downloads), 0) FROM download_stats
    WHERE package_name = ?
  """, pkgName)
  if row.isSome:
    result = row.get()[0].intVal.int
  else:
    result = 0

# --- Stats Operations ---

type
  PackageStats* = object
    totalPackages*: int
    totalAuthors*: int
    totalDownloads*: int

  TopPackage* = object
    name*: string
    downloads*: int

  RecentPackage* = object
    name*: string
    description*: string
    author*: string
    createdAt*: int64

  TopAuthor* = object
    name*: string
    packageCount*: int

  LicenseDist* = object
    license*: string
    count*: int

  HostDist* = object
    host*: string
    count*: int

  TopTag* = object
    tag*: string
    count*: int

  FailedPackage* = object
    name*: string
    url*: string
    failedAt*: int64

  LargestPackage* = object
    name*: string
    url*: string
    totalSize*: int64
    versionCount*: int

proc getFailedPackages*(s: DbStorage, reason: string = ""): seq[FailedPackage] =
  ## Get failed packages filtered by reason (empty = all)
  var query = "SELECT name, url, CAST(failed_at AS INTEGER) FROM failed_packages"
  if reason.len > 0:
    query.add(" WHERE reason = ?")
    query.add(" ORDER BY failed_at DESC")
    for row in s.db.all(query, reason):
      result.add(FailedPackage(
        name: row[0].strVal,
        url: if row[1].kind == sqliteNull: "" else: row[1].strVal,
        failedAt: if row[2].kind == sqliteNull: 0 else: row[2].intVal
      ))
  else:
    query.add(" ORDER BY failed_at DESC")
    for row in s.db.all(query):
      result.add(FailedPackage(
        name: row[0].strVal,
        url: if row[1].kind == sqliteNull: "" else: row[1].strVal,
        failedAt: if row[2].kind == sqliteNull: 0 else: row[2].intVal
      ))

proc getLargestPackages*(s: DbStorage, limit: int = 20): seq[LargestPackage] =
  ## Get packages with largest total tarball size
  for row in s.db.all("""
    SELECT p.name, p.url, SUM(v.tarball_size) as total_size, COUNT(v.id) as version_count
    FROM packages p
    JOIN versions v ON p.id = v.package_id
    GROUP BY p.id
    ORDER BY total_size DESC
    LIMIT ?
  """, limit.int64):
    result.add(LargestPackage(
      name: row[0].strVal,
      url: if row[1].kind == sqliteNull: "" else: row[1].strVal,
      totalSize: row[2].intVal,
      versionCount: row[3].intVal.int
    ))

proc getPackageStats*(s: DbStorage): PackageStats =
  ## Get core package-level stats
  let pkgRow = s.db.one("SELECT COUNT(*), COUNT(DISTINCT author) FROM packages")
  if pkgRow.isSome:
    result.totalPackages = pkgRow.get()[0].intVal.int
    result.totalAuthors = pkgRow.get()[1].intVal.int

  let dlRow = s.db.one("SELECT COALESCE(SUM(downloads), 0) FROM download_stats")
  if dlRow.isSome:
    result.totalDownloads = dlRow.get()[0].intVal.int

proc getTopPackagesByDownloads*(s: DbStorage, limit: int = 10): seq[TopPackage] =
  ## Get packages with most total downloads
  for row in s.db.all("""
    SELECT package_name, SUM(downloads) as total
    FROM download_stats
    GROUP BY package_name
    ORDER BY total DESC
    LIMIT ?
  """, limit.int64):
    result.add(TopPackage(
      name: row[0].strVal,
      downloads: row[1].intVal.int
    ))

proc getRecentPackages*(s: DbStorage, limit: int = 10): seq[RecentPackage] =
  ## Get most recently added packages
  for row in s.db.all("""
    SELECT name, description, author, CAST(created_at AS INTEGER)
    FROM packages
    ORDER BY created_at DESC
    LIMIT ?
  """, limit.int64):
    result.add(RecentPackage(
      name: row[0].strVal,
      description: if row[1].kind == sqliteNull: "" else: row[1].strVal,
      author: if row[2].kind == sqliteNull: "" else: row[2].strVal,
      createdAt: if row[3].kind == sqliteNull: 0 else: row[3].intVal
    ))

proc getTopAuthors*(s: DbStorage, limit: int = 10): seq[TopAuthor] =
  ## Get authors with most packages
  for row in s.db.all("""
    SELECT author, COUNT(*) as cnt
    FROM packages
    WHERE author IS NOT NULL AND author != ''
    GROUP BY author
    ORDER BY cnt DESC
    LIMIT ?
  """, limit.int64):
    result.add(TopAuthor(
      name: row[0].strVal,
      packageCount: row[1].intVal.int
    ))

proc getLicenseDistribution*(s: DbStorage): seq[LicenseDist] =
  ## Get license distribution (group empty/unknown together)
  for row in s.db.all("""
    SELECT CASE
      WHEN license IS NULL OR license = '' OR license = 'Unknown' THEN 'Unknown'
      ELSE license
    END as lic, COUNT(*) as cnt
    FROM packages
    GROUP BY lic
    ORDER BY cnt DESC
  """):
    result.add(LicenseDist(
      license: row[0].strVal,
      count: row[1].intVal.int
    ))

proc getHostDistribution*(s: DbStorage): seq[HostDist] =
  ## Get host distribution from URL prefixes
  for row in s.db.all("""
    SELECT CASE
      WHEN url LIKE 'https://github.com%' THEN 'GitHub'
      WHEN url LIKE 'https://gitlab.com%' THEN 'GitLab'
      WHEN url LIKE 'https://codeberg.org%' THEN 'Codeberg'
      WHEN url LIKE 'https://bitbucket.org%' THEN 'Bitbucket'
      WHEN url LIKE 'https://git.sr.ht%' THEN 'SourceHut'
      ELSE 'Other'
    END as host, COUNT(*) as cnt
    FROM packages
    GROUP BY host
    ORDER BY cnt DESC
  """):
    result.add(HostDist(
      host: row[0].strVal,
      count: row[1].intVal.int
    ))

proc cmpTopTagDesc(a, b: TopTag): int = cmp(b.count, a.count)

proc getTopTags*(s: DbStorage, limit: int = 20): seq[TopTag] =
  ## Get most common tags
  ## SQLite doesn't have JSON array unpacking, so we parse in application code
  var tagCounts = initTable[string, int]()
  for row in s.db.all("SELECT tags FROM packages WHERE tags IS NOT NULL AND tags != '' AND tags != '[]'"):
    let tagsStr = row[0].strVal
    try:
      let tagsJson = parseJson(tagsStr)
      for t in tagsJson:
        let tag = t.getStr()
        if tag.len > 0:
          tagCounts[tag] = tagCounts.getOrDefault(tag, 0) + 1
    except CatchableError as e:
      warn "Failed to parse tags for tag stats", tags = tagsStr, error = e.msg

  for tag, count in tagCounts:
    result.add(TopTag(tag: tag, count: count))

  algorithm.sort(result, cmpTopTagDesc)
  if result.len > limit:
    result = result[0..<limit]

# --- README Operations ---

proc storeReadme*(s: DbStorage, pkgName: string, version: string, filename: string, content: string) =
  ## Store or update a README for a specific package version
  s.db.exec("""
    INSERT INTO readmes (package_name, version, filename, content, fetched_at)
    VALUES (?, ?, ?, ?, unixepoch())
    ON CONFLICT(package_name, version) DO UPDATE SET
      filename = excluded.filename,
      content = excluded.content,
      fetched_at = unixepoch()
  """, pkgName, version, filename, content)

type ReadmeData* = object
  filename*: string
  content*: string

proc loadReadme*(s: DbStorage, pkgName: string, version: string): ReadmeData =
  ## Load README for a specific package version
  let row = s.db.one("""
    SELECT filename, content FROM readmes
    WHERE package_name = ? AND version = ?
  """, pkgName, version)
  if row.isNone:
    raise newException(NotFoundError, "readme not found: " & pkgName & "@" & version)
  let r = row.get()
  result = ReadmeData(filename: r[0].strVal, content: r[1].strVal)

# --- Version Hash Operations ---

type VersionHash* = object
  pkgName*: string
  ver*: SemVer
  hash*: seq[uint32]
  textLength*: int

proc storeVersionHash*(s: DbStorage, pkgName: string, ver: SemVer, hash: seq[uint32], textLength: int) =
  ## Store or update a MinHash signature for a specific version
  let pkgRow = s.db.one("SELECT id FROM packages WHERE name = ?", pkgName)
  if pkgRow.isNone:
    raise newException(NotFoundError, "package not found: " & pkgName)
  let pkgId = pkgRow.get()[0].intVal

  let verRow = s.db.one("""
    SELECT id FROM versions
    WHERE package_id = ? AND major = ? AND minor = ? AND patch = ?
  """, pkgId, ver.major.int64, ver.minor.int64, ver.patch.int64)
  if verRow.isNone:
    raise newException(NotFoundError, "version not found: " & pkgName & " v" & $ver)
  let verId = verRow.get()[0].intVal

  # Serialize seq[uint32] to seq[byte] (little-endian)
  var blob = newSeq[byte](hash.len * 4)
  for i, v in hash:
    blob[i * 4 + 0] = byte((v shr 0) and 0xFF)
    blob[i * 4 + 1] = byte((v shr 8) and 0xFF)
    blob[i * 4 + 2] = byte((v shr 16) and 0xFF)
    blob[i * 4 + 3] = byte((v shr 24) and 0xFF)

  s.db.exec("""
    INSERT INTO version_hashes (package_id, version_id, hash, text_length, algo_version, created_at)
    VALUES (?, ?, ?, ?, 1, unixepoch())
    ON CONFLICT(version_id) DO UPDATE SET
      hash = excluded.hash,
      text_length = excluded.text_length,
      algo_version = excluded.algo_version,
      created_at = unixepoch()
  """, pkgId, verId, blob, textLength.int64)

proc getVersionHashes*(s: DbStorage): seq[VersionHash] =
  ## Load all version hashes (currently only head versions are populated)
  for row in s.db.all("""
    SELECT p.name, v.major, v.minor, v.patch, h.hash, h.text_length
    FROM version_hashes h
    JOIN versions v ON v.id = h.version_id
    JOIN packages p ON p.id = h.package_id
  """):
    # Deserialize BLOB to seq[uint32] (little-endian)
    var hashSeq: seq[uint32]
    if row[4].kind == sqliteBlob:
      let blob = row[4].blobVal
      let n = blob.len div 4
      hashSeq = newSeq[uint32](n)
      for i in 0..<n:
        hashSeq[i] = uint32(blob[i * 4 + 0]) or
                     (uint32(blob[i * 4 + 1]) shl 8) or
                     (uint32(blob[i * 4 + 2]) shl 16) or
                     (uint32(blob[i * 4 + 3]) shl 24)

    result.add(VersionHash(
      pkgName: row[0].strVal,
      ver: SemVer(
        major: row[1].intVal.int,
        minor: row[2].intVal.int,
        patch: row[3].intVal.int
      ),
      hash: hashSeq,
      textLength: row[5].intVal.int
    ))
