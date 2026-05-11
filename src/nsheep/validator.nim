##
## Package validator - compiles packages in Docker to verify they work
## Tests default branch + latest 2 tagged versions
##

import std/[os, osproc, strutils, tempfiles, times, algorithm, tables]
import chronicles
import ./[config, storage, ingest]

export config.ValidatorConfig

const
  DefaultDockerImage = "nimlang/nim:alpine"
  BuildTimeout = 300    # 5 minutes per build
  MaxVersionsToTest = 2 # Latest 2 tagged versions + default branch

type
  BuildResult* = object
    version*: string # "default" or tag name
    success*: bool
    output*: string  # Build output (stdout+stderr)
    durationMs*: int

  ValidationResult* = object
    repo*: string # owner/repo
    defaultBranch*: BuildResult
    versions*: seq[BuildResult]
    overallSuccess*: bool

proc defaultValidatorConfig*(): ValidatorConfig =
  ValidatorConfig(
    enabled: true,
    dockerImage: DefaultDockerImage,
    timeout: BuildTimeout,
    required: false
  )

proc runDockerBuild(repoUrl, tag, subdir, dockerImage: string, timeout: int): BuildResult =
  ## Run a single build in Docker
  result.version = tag

  let tempDir = createTempDir("nsheep-build", "")
  defer: removeDir(tempDir)

  let srcDir = tempDir / "src"
  let workDir = if subdir.len > 0: srcDir / subdir else: srcDir

  # Clone specific tag/branch (shallow, single-branch to minimize data)
  let cloneCmd = if tag == "default":
    "git clone --depth 1 --single-branch " & repoUrl.quoteShell & " " & srcDir.quoteShell
  else:
    "git clone --depth 1 --single-branch --branch " & tag.quoteShell & " " & repoUrl.quoteShell & " " &
        srcDir.quoteShell

  var startTime = getTime()

  # Run clone
  let (cloneOut, cloneExit) = execCmdEx(cloneCmd)
  if cloneExit != 0:
    result.success = false
    result.output = "Clone failed: " & cloneOut
    result.durationMs = int((getTime() - startTime).inMilliseconds)
    return

  # Find .nimble file to get package name and metadata
  var nimbleFile = ""
  var pkgName = ""
  var nimblePath = ""
  for file in walkFiles(workDir / "*.nimble"):
    nimblePath = file
    nimbleFile = file.extractFilename
    pkgName = nimbleFile.replace(".nimble", "")
    break

  if nimbleFile == "":
    result.success = false
    result.output = "No .nimble file found"
    result.durationMs = int((getTime() - startTime).inMilliseconds)
    return

  # Parse nimble file for validation strategy
  let nimbleContent = readFile(nimblePath)
  let nimbleData = parseNimbleSimple(nimbleContent)
  let hasBin = nimbleData.getOrDefault("hasBin", "") == "true"
  let srcDirVal = nimbleData.getOrDefault("srcDir", "")
  let backend = nimbleData.getOrDefault("backend", "c")

  let dockerWorkDir = if subdir.len > 0: "/src/" & subdir else: "/src"
  let dockerBase = "docker run --rm " &
    "-v " & srcDir & ":/src:ro " &
    "-w " & dockerWorkDir.quoteShell & " " &
    dockerImage & " "

  var dockerCmd = ""
  var buildDescription = ""

  if hasBin:
    # Binary package: build all defined binaries
    # Use --binDir to output to a writable location since /src is mounted ro
    dockerCmd = dockerBase & "nimble build --binDir:/tmp 2>&1"
    buildDescription = "nimble build"
  else:
    # Library package: install deps then compile the main module to verify it imports correctly
    # Output to /tmp since /src is mounted read-only
    let nimBackend = if backend in ["c", "cpp", "js", "objc"]: backend else: "c"
    let srcPath = if srcDirVal.len > 0: srcDirVal & "/" & pkgName & ".nim" else: pkgName & ".nim"
    dockerCmd = dockerBase & "sh -c 'nimble install -d -y && nim " & nimBackend & " -o:/tmp/" & pkgName & " " &
        srcPath & "' 2>&1"
    buildDescription = "nimble install + nim " & nimBackend & " " & srcPath

  info "Running validation", repo = repoUrl, tag = tag, command = buildDescription

  let (buildOut, buildExit) = execCmdEx(dockerCmd)

  result.durationMs = int((getTime() - startTime).inMilliseconds)
  result.success = buildExit == 0
  result.output = buildOut

proc getLatestTags(repoUrl: string, count: int): seq[string] =
  ## Get latest N tags from git repository via ls-remote (no clone needed)
  let cmd = "git ls-remote --tags " & repoUrl.quoteShell & " 2>&1"
  let (output, exitCode) = execCmdEx(cmd)

  if exitCode != 0:
    return @[]

  var tags: seq[string] = @[]
  for line in output.splitLines():
    let parts = line.strip().split('\t')
    if parts.len >= 2:
      let refPath = parts[1]
      # refs/tags/v1.0.0^{} is the dereferenced commit; skip it
      if refPath.startsWith("refs/tags/") and not refPath.endsWith("^{}"):
        let tag = refPath[10 .. ^1] # strip "refs/tags/"
        if tag.len > 0 and not tag.contains(" "):
          tags.add(tag)

  # Sort version tags and take latest N
  tags.sort(cmp = system.cmp[string])
  if tags.len > count:
    tags = tags[tags.len - count .. ^1]
  else:
    tags = tags

  result = tags

proc validatePackage*(
  s: DbStorage,
  repoUrl, repoName, subdir: string,
  config: ValidatorConfig = defaultValidatorConfig()
): ValidationResult =
  ## Validate a package by building default branch + latest tags, store results in DB
  result.repo = repoName
  result.overallSuccess = true

  if not config.enabled:
    result.overallSuccess = true
    return

  info "Starting validation", repo = result.repo

  # Build default branch
  info "Building default branch", repo = result.repo
  result.defaultBranch = runDockerBuild(repoUrl, "default", subdir, config.dockerImage, config.timeout)

  # Store default branch result
  s.storeValidationResult(
    repoName,
    "default",
    result.defaultBranch.success,
    result.defaultBranch.output,
    result.defaultBranch.durationMs
  )

  if not result.defaultBranch.success:
    result.overallSuccess = false
    warn "Default branch build failed", repo = result.repo
  else:
    info "Default branch build succeeded", repo = result.repo, duration = result.defaultBranch.durationMs

  # Get and build latest tags
  let tags = getLatestTags(repoUrl, MaxVersionsToTest)
  info "Found tags", repo = result.repo, tags = tags

  for tag in tags:
    info "Building tagged version", repo = result.repo, tag = tag
    let buildResult = runDockerBuild(repoUrl, tag, subdir, config.dockerImage, config.timeout)
    result.versions.add(buildResult)

    # Store version result
    s.storeValidationResult(
      repoName,
      tag,
      buildResult.success,
      buildResult.output,
      buildResult.durationMs
    )

    if not buildResult.success:
      result.overallSuccess = false
      warn "Tagged build failed", repo = result.repo, tag = tag
    else:
      info "Tagged build succeeded", repo = result.repo, tag = tag, duration = buildResult.durationMs

  info "Validation complete", repo = result.repo, overallSuccess = result.overallSuccess

proc isDockerAvailable*(): bool =
  ## Check if Docker is installed and running
  let (_, exitCode) = execCmdEx("docker ps")
  return exitCode == 0

proc validateOrSkip*(s: DbStorage, repoUrl, repoName, subdir: string, config: ValidatorConfig): bool =
  ## Validate if enabled and Docker available, otherwise return true (skip)
  if not config.enabled:
    return true

  if not isDockerAvailable():
    warn "Docker not available, skipping validation", repo = repoName
    return true

  let res = validatePackage(s, repoUrl, repoName, subdir, config)
  return res.overallSuccess
