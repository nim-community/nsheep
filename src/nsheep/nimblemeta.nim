import std/[os, paths, tables, tempfiles]

import basic/[deptypes, nimblecontext, pkgurls, versions]
import releaseinfo

const NimRepoUrl = "https://github.com/nim-lang/Nim"

proc processNimbleReleaseSafe(
    nc: var NimbleContext;
    pkg: Package;
    release: VersionTag
): NimbleRelease {.gcsafe.} =
  {.cast(gcsafe).}:
    nc.processNimbleRelease(pkg, release)

proc parseProjectInfoImpl(nimbleContent: string): Table[string, string] =
  ## Parse project metadata from a .nimble file using Atlas release parsing.
  result = initTable[string, string]()

  let tempDir = createTempDir("nsheep-", "")
  let nimblePath = tempDir / "pkg.nimble"
  writeFile(nimblePath, nimbleContent)

  let release = try:
    var nc = createUnfilledNimbleContext()
    discard nc.put("nim", createUrlSkipPatterns(NimRepoUrl))
    let pkgUrl = createUrlSkipPatterns(tempDir)
    let pkg = Package(url: pkgUrl, ondisk: Path tempDir, isLocalOnly: true)
    processNimbleReleaseSafe(
      nc,
      pkg,
      VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    )
  finally:
    removeDir(tempDir)

  if not release.isNil:
    if release.name.len > 0:
      result["name"] = release.name
    let version = $release.version
    if version != "~" and version.len > 0:
      result["version"] = version
    if release.author.len > 0:
      result["author"] = release.author
    if release.description.len > 0:
      result["description"] = release.description
    if release.license.len > 0:
      result["license"] = release.license
    let srcDir = $release.srcDir
    if srcDir.len > 0:
      result["srcDir"] = srcDir
    let binDir = $release.binDir
    if binDir.len > 0:
      result["binDir"] = binDir
    if release.backend.len > 0:
      result["backend"] = release.backend
    if release.hasBin:
      result["hasBin"] = "true"

proc parseProjectInfo*(nimbleContent: string): Table[string, string] {.gcsafe.} =
  {.cast(gcsafe).}:
    parseProjectInfoImpl(nimbleContent)
