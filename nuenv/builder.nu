export use env.nu *
use std/log

let attrs = (get_attrs)
let initialPkgs = $attrs.packages

let nushell = {
  version: (version).version,
  pkg: (getPkgRoot $attrs.builder),
  userEnvFile: $attrs.envFile,
}

let drv = {
  name: $attrs.name,
  system: $attrs.system,
  outputs: ($attrs.outputs | transpose key value),
  initialPackages: $initialPkgs,
  packages: (
    $initialPkgs
    | append $nushell.pkg
    | split row (char space)
  ),
  extraAttrs: ($attrs.__nu_extra_attrs | transpose key value),
}

let nix = {
  sandbox: $env.NIX_BUILD_TOP,
  store: $env.NIX_STORE,
  debug: $attrs.__nu_debug,
}

if $nix.debug {
  log info $"Realising the ($drv.name) derivation for ($drv.system)"
  let numCores = ($env.NIX_BUILD_CORES? | default "1" | into int)
  log info $"Running on ($numCores) core(plural $numCores)"
  log info $"Using Nushell ($nushell.version)"
  log info "Declared build outputs:"
  for output in $drv.outputs { item $output.key }
}

# Build PATH from packages list
if ($drv.initialPackages | is-not-empty) and $nix.debug {
  let n = ($drv.initialPackages | length)
  log info $"Adding ($n) package(plural $n) to PATH:"
  for pkg in $drv.initialPackages {
    item (getPkgName $nix.store $pkg)
  }
}

let packagesPath = (
  $drv.packages
  | each { |pkg| $"($pkg)/bin" }
  | str join (char esep)
)
$env.PATH = $packagesPath

# Set user-supplied environment variables (anything not reserved)
let numAttrs = ($drv.extraAttrs | length)
if $numAttrs != 0 {
  if $nix.debug {
    log info $"Setting ($numAttrs) user-supplied environment variable(plural $numAttrs):"
  }
  for attr in $drv.extraAttrs {
    if $nix.debug { item $"($attr.key) = \"($attr.value)\"" }
    load-env { $attr.key: $attr.value }
  }
}

# Expose output paths as environment variables ($out, $dev, …)
for output in $drv.outputs {
  load-env { $output.key: $output.value }
}

# Expose src (and srcs) so phase scripts can reference $env.src / $env.srcs
load-env { src: $attrs.src }
if ($attrs.srcs | is-not-empty) {
  load-env { srcs: ($attrs.srcs | str join " ") }
}

# $prefix defaults to the first output ($out) unless the derivation overrides it
if ($attrs.prefix | is-empty) {
  $env.prefix = $env.out
} else {
  $env.prefix = $attrs.prefix
}

# SOURCE_DATE_EPOCH for reproducible builds (mirrors nixpkgs default)
if ("SOURCE_DATE_EPOCH" not-in ($env | columns)) {
  $env.SOURCE_DATE_EPOCH = "315532800"
}

# Unpack a single source archive or copy a directory into cwd.
def unpackFile [src: path] {
  let name = ($src | path basename)
  print $"unpacking source archive ($src)"
  if ($name | str ends-with ".tar.gz") or ($name | str ends-with ".tgz") {
    tar xzf $src
  } else if ($name | str ends-with ".tar.bz2") or ($name | str ends-with ".tbz2") {
    tar xjf $src
  } else if ($name | str ends-with ".tar.xz") or ($name | str ends-with ".txz") {
    tar xJf $src
  } else if ($name | str ends-with ".tar.zst") {
    tar --use-compress-program=zstd -xf $src
  } else if ($name | str ends-with ".tar.lz") {
    tar --use-compress-program=lzip -xf $src
  } else if ($name | str ends-with ".tar") {
    tar xf $src
  } else if (($src | path parse | get extension) == "zip") {
    unzip $src
  } else if ($src | path type) == "dir" {
    let dest = $name
    cp -r $src $dest
  } else {
    log warning $"Don't know how to unpack ($name); copying as-is."
    cp $src .
  }
}

# Return true when a Makefile (or custom -f target) is present.
def hasMakefile [makefile: string] {
  if ($makefile | is-not-empty) {
    $makefile | path exists
  } else {
    ["Makefile" "makefile" "GNUmakefile"] | any { path exists }
  }
}

# Flatten and stringify a variadic set of flag sources.
def collectFlags [...sources] {
  $sources
  | flatten
  | each { |f| $f | into string }
  | where { |f| ($f | is-not-empty) }
}

# Convert a phase name to its capitalised hook-name fragment
# e.g. "unpack" → "Unpack", "installCheck" → "InstallCheck"
def phaseCapitalized [phase: string] {
  match $phase {
    "unpack"        => "Unpack"
    "patch"         => "Patch"
    "configure"     => "Configure"
    "build"         => "Build"
    "check"         => "Check"
    "install"       => "Install"
    "fixup"         => "Fixup"
    "installCheck"  => "InstallCheck"
    "dist"          => "Dist"
    _               => ($phase | str capitalize)
  }
}

# Decide whether a phase should be skipped.
def shouldSkip [phase: string, attrs: record] {
  match $phase {
    "unpack"        => $attrs.dontUnpack
    "patch"         => $attrs.dontPatch
    "configure"     => $attrs.dontConfigure
    "build"         => $attrs.dontBuild
    "check"         => (not $attrs.doCheck)
    "install"       => $attrs.dontInstall
    "fixup"         => $attrs.dontFixup
    "installCheck"  => (not $attrs.doInstallCheck)
    "dist"          => (not $attrs.doDist)
    _               => false
  }
}

# Print the phase header (mirrors nixpkgs showPhaseHeader).
def showPhaseHeader [phase: string] {
  print $"Running phase: ($phase)"
}

# Print elapsed time when a phase took ≥ 30 s.
def showPhaseFooter [phase: string, startNs: int, endNs: int] {
  let delta = (($endNs - $startNs) / 1_000_000_000)
  if $delta >= 30 {
    let h = ($delta / 3600)
    let m = (($delta mod 3600) / 60)
    let s = ($delta mod 60)
    mut msg = $"($phase) completed in "
    if $h > 0 { $msg = $msg + $"($h) hours " }
    if $m > 0 { $msg = $msg + $"($m) minutes " }
    $msg = $msg + $"($s) seconds"
    print $msg
  }
}

# Patch interpreter shebangs under a directory tree.
# Replaces bare /usr/bin/foo references with whatever `which foo` resolves to,
# skipping paths already inside the Nix store.
def patchShebangsInDir [dir: path] {
  if not ($dir | path exists) { return }
  let storeDir = $env.NIX_STORE

  # find all regular executable files
  let files = (
    try { ^find $dir -type f -perm -0100 | lines } catch { [] }
  )

  for file in $files {
    try {
      let raw     = (open --raw $file)
      let first   = ($raw | lines | first)
      if not ($first | str starts-with "#!") { continue }

      let shebang = ($first | str replace "#!" "" | str trim)
      let parts   = ($shebang | split row " " | where { |p| ($p | is-not-empty) })
      if ($parts | is-empty) { continue }
      let interp  = ($parts | first)

      # Already in store — nothing to do
      if ($interp | str starts-with $storeDir) { continue }

      # Skip env-style shebangs — too dynamic to rewrite safely
      if ($interp | str ends-with "/env") { continue }

      let interpName = ($interp | path basename)
      let newInterp  = (try { which $interpName | str trim } catch { "" })
      if ($newInterp | is-empty) { continue }

      let rest       = ($parts | skip 1 | str join " ")
      let newShebang = (if ($rest | is-not-empty) {
        $"#!($newInterp) ($rest)"
      } else {
        $"#!($newInterp)"
      })
      let newContent = ($raw | str replace $first $newShebang)
      $newContent | save --force $file
    } catch { }
  }
}

# Write propagated-{build,native-build}-inputs and propagated-user-env-packages
# files into the appropriate nix-support directories.
def recordPropagatedDependencies [outputs: list, attrs: record] {
  let devOutput = (
    $outputs | where key == "dev" | first
    | default ($outputs | first)
  )
  let binOutput = (
    $outputs | where key == "bin" | first
    | default ($outputs | first)
  )

  if ($attrs.propagatedBuildInputs | is-not-empty) {
    let dir = ($devOutput.value | path join "nix-support")
    mkdir $dir
    $attrs.propagatedBuildInputs | str join " "
      | save --force ($dir | path join "propagated-build-inputs")
  }

  if ($attrs.propagatedNativeBuildInputs | is-not-empty) {
    let dir = ($devOutput.value | path join "nix-support")
    mkdir $dir
    $attrs.propagatedNativeBuildInputs | str join " "
      | save --force ($dir | path join "propagated-native-build-inputs")
  }

  if ($attrs.propagatedUserEnvPkgs | is-not-empty) {
    let dir = ($binOutput.value | path join "nix-support")
    mkdir $dir
    $attrs.propagatedUserEnvPkgs | str join " "
      | save --force ($dir | path join "propagated-user-env-packages")
  }
}


# runHook and runUserPhase are closures so they can capture $attrs, $nix,
# and $nushell from the surrounding script scope without being passed as args.

# Run a hook script (preXxx / postXxx) when present and non-empty.
let runHook = { |hookName: string|
  if ($hookName in $attrs) {
    let script = ($attrs | get $hookName)
    if ($script | is-not-empty) {
      if $nix.debug { log info $"  hook: ($hookName)" }
      let result = (nu --log-level warn --env-config $nushell.userEnvFile --commands $script | complete)
      if ($result.stdout | is-not-empty) { $result.stdout | print }
      if ($result.stderr | is-not-empty) { $result.stderr | print }
      if $result.exit_code != 0 {
        log error $"Hook ($hookName) failed (exit ($result.exit_code))"
        exit $result.exit_code
      }
    }
  }
}

# Run the user-supplied phase script when present and non-empty.
# Returns true when a script was found and executed, false otherwise.
let runUserPhase = { |phaseName: string|
  if ($phaseName in $attrs) {
    let script = ($attrs | get $phaseName)
    if ($script | is-not-empty) {
      if $nix.debug { log info $"  user ($phaseName) script" }
      let result = (nu --log-level warn --env-config $nushell.userEnvFile --commands $script | complete)
      if ($result.stdout | is-not-empty) { $result.stdout | print }
      if ($result.stderr | is-not-empty) { $result.stderr | print }
      if $result.exit_code != 0 {
        log error $"Phase ($phaseName) failed (exit ($result.exit_code))"
        exit $result.exit_code
      }
      true
    } else { false }
  } else { false }
}

# unpack: extract source archives and return the new source-root directory.
let defaultUnpack = {
  let sources = if ($attrs.srcs | is-not-empty) { $attrs.srcs } else { [$attrs.src] }

  let dirsBefore = (ls | where type == dir | get name)

  for src in $sources { unpackFile $src }

  let dirsAfter = (ls | where type == dir | get name)
  let newDirs   = ($dirsAfter | where { |d| $d not-in $dirsBefore })

  let root = if ($newDirs | length) > 1 {
    # Multiple new dirs — acceptable only when sourceRoot is pre-set
    if ($attrs.sourceRoot | is-not-empty) {
      $attrs.sourceRoot
    } else {
      log error "unpacker produced multiple directories; set sourceRoot to disambiguate"
      exit 1
    }
  } else if ($newDirs | is-empty) {
    # No new directory (e.g. flat file archive) — stay in build top
    ""
  } else {
    $newDirs | first
  }

  if ($root | is-not-empty) {
    print $"source root is ($root)"
    if not $attrs.dontMakeSourcesWritable {
      try { chmod -R u+w $root } catch { }
    }
  }
  $root
}

# patch: apply a list of patch files.
let defaultPatch = {
  if ($attrs.patches | is-empty) {
    if $nix.debug { log info "No patches to apply." }
  } else {
    for patch in $attrs.patches {
      print $"applying patch ($patch)"
      let pname  = ($patch | path basename)
      let flags  = $attrs.patchFlags
      if ($pname | str ends-with ".gz") {
        gzip -dc $patch | patch ...$flags
      } else if ($pname | str ends-with ".bz2") {
        bzip2 -dc $patch | patch ...$flags
      } else if ($pname | str ends-with ".xz") {
        xz -dc $patch | patch ...$flags
      } else {
        open --raw $patch | patch ...$flags
      }
    }
  }
}

# configure: run ./configure (or a custom configureScript) with flags.
let defaultConfigure = {
  let script = if ($attrs.configureScript | is-not-empty) {
    $attrs.configureScript
  } else if ("./configure" | path exists) {
    "./configure"
  } else { "" }

  if ($script | is-not-empty) {
    mut flags = ($attrs.configureFlags ++ $attrs.configureFlagsArray)

    if not $attrs.dontAddPrefix {
      $flags = ([$"($attrs.prefixKey)($env.prefix)"] ++ $flags)
    }

    # Opt-in auto-flags that mirror nixpkgs behaviour
    if not $attrs.dontAddDisableDepTrack {
      try {
        if (open --raw $script | str contains "dependency-tracking") {
          $flags = (["--disable-dependency-tracking"] ++ $flags)
        }
      } catch { }
    }
    if not $attrs.dontDisableStatic {
      try {
        if (open --raw $script | str contains "enable-static") {
          $flags = (["--disable-static"] ++ $flags)
        }
      } catch { }
    }

    print $"configure flags: ($flags | str join ' ')"
    run-external $script ...$flags
  } else {
    print "no configure script, doing nothing"
  }
}

# build: run make (or do nothing when no Makefile is present).
let defaultBuild = {
  if (hasMakefile $attrs.makefile) {
    let parallelJ = if $attrs.enableParallelBuilding {
      [$"-j($env.NIX_BUILD_CORES? | default '1')"]
    } else { [] }
    let flags    = (collectFlags $parallelJ $attrs.makeFlags $attrs.buildFlags $attrs.buildFlagsArray)
    let makeArgs = if ($attrs.makefile | is-not-empty) {
      ["-f" $attrs.makefile] ++ $flags
    } else { $flags }
    print $"build flags: ($makeArgs | str join ' ')"
    run-external "make" ...$makeArgs
  } else {
    print "no Makefile or custom build, doing nothing"
  }
}

# check: run make check / make test (only reached when doCheck = true).
let defaultCheck = {
  if (hasMakefile $attrs.makefile) {
    let target = if ($attrs.checkTarget | is-not-empty) {
      $attrs.checkTarget
    } else {
      # Probe for check target, fall back to test
      let hasCheck = ((do { make -n check } | complete).exit_code == 0)
      if $hasCheck { "check" } else { "test" }
    }
    let parallelJ = if $attrs.enableParallelChecking {
      [$"-j($env.NIX_BUILD_CORES? | default '1')"]
    } else { [] }
    let flags    = (collectFlags $parallelJ $attrs.makeFlags $attrs.checkFlags $attrs.checkFlagsArray [$target])
    let makeArgs = if ($attrs.makefile | is-not-empty) {
      ["-f" $attrs.makefile] ++ $flags
    } else { $flags }
    print $"check flags: ($makeArgs | str join ' ')"
    run-external "make" ...$makeArgs
  } else {
    print "no Makefile or custom checkPhase, doing nothing"
  }
}

# install: run make install into $prefix.
let defaultInstall = {
  if (hasMakefile $attrs.makefile) {
    mkdir $env.prefix
    let parallelJ = if $attrs.enableParallelInstalling {
      [$"-j($env.NIX_BUILD_CORES? | default '1')"]
    } else { [] }
    let targets  = if ($attrs.installTargets | is-not-empty) { $attrs.installTargets } else { ["install"] }
    let flags    = (collectFlags $parallelJ $attrs.makeFlags $attrs.installFlags $attrs.installFlagsArray $targets)
    let makeArgs = if ($attrs.makefile | is-not-empty) {
      ["-f" $attrs.makefile] ++ $flags
    } else { $flags }
    print $"install flags: ($makeArgs | str join ' ')"
    run-external "make" ...$makeArgs
  } else {
    print "no Makefile or custom install, doing nothing"
  }
}

# fixup: strip binaries, patch shebangs, record propagated deps, copy setup hook.
let defaultFixup = {
  # Make outputs writable before stripping / patching
  for output in $drv.outputs {
    if ($output.value | path exists) {
      try { chmod -R u+w,u-s,g-s $output.value } catch { }
    }
  }

  # Strip binaries
  if not $attrs.dontStrip {
    for output in $drv.outputs {
      let outPath = $output.value
      if not ($outPath | path exists) { continue }

      # Strip-all dirs (e.g. debug packages)
      for stripDir in $attrs.stripAllList {
        let target = ($outPath | path join $stripDir)
        if ($target | path exists) {
          for f in (try { ^find $target -type f | lines } catch { [] }) {
            try { run-external "strip" ...$attrs.stripAllFlags $f } catch { }
          }
        }
      }

      # Strip-debug dirs (default: lib, lib32, lib64, libexec, bin, sbin)
      let debugDirs = if ($attrs.stripDebugList | is-not-empty) {
        $attrs.stripDebugList
      } else {
        ["lib" "lib32" "lib64" "libexec" "bin" "sbin"]
      }
      for dir in $debugDirs {
        let target = ($outPath | path join $dir)
        if ($target | path exists) {
          for f in (try { ^find $target -type f | lines } catch { [] }) {
            try { run-external "strip" ...$attrs.stripDebugFlags $f } catch { }
          }
        }
      }
    }
  }

  # Patch shebangs in all outputs
  if not $attrs.dontPatchShebangs {
    for output in $drv.outputs {
      if ($output.value | path exists) {
        patchShebangsInDir $output.value
      }
    }
  }

  # Record propagated dependencies
  recordPropagatedDependencies $drv.outputs $attrs

  # Copy setup hook into nix-support/setup-hook of the dev output
  if ($attrs.setupHook | is-not-empty) {
    let devOut = (
      $drv.outputs | where key == "dev" | first?
      | default ($drv.outputs | first)
    )
    let dir = ($devOut.value | path join "nix-support")
    mkdir $dir
    cp $attrs.setupHook ($dir | path join "setup-hook")
  }
}

# installCheck: run make installcheck (only reached when doInstallCheck = true).
let defaultInstallCheck = {
  if (hasMakefile $attrs.makefile) {
    let target   = if ($attrs.installCheckTarget | is-not-empty) { $attrs.installCheckTarget } else { "installcheck" }
    let flags    = (collectFlags $attrs.makeFlags $attrs.installCheckFlags $attrs.installCheckFlagsArray [$target])
    let makeArgs = if ($attrs.makefile | is-not-empty) { ["-f" $attrs.makefile] ++ $flags } else { $flags }

    print $"installcheck flags: ($makeArgs | str join ' ')"

    run-external "make" ...$makeArgs
  } else {
    print "no Makefile or custom installCheckPhase, doing nothing"
  }
}

# dist: run make dist and optionally copy tarballs to $out/tarballs.
let defaultDist = {
  let target   = if ($attrs.distTarget | is-not-empty) { $attrs.distTarget } else { "dist" }
  let flags    = (collectFlags $attrs.distFlags $attrs.distFlagsArray [$target])
  let makeArgs = if ($attrs.makefile | is-not-empty) { ["-f" $attrs.makefile] ++ $flags } else { $flags }
  print $"dist flags: ($makeArgs | str join ' ')"
  run-external "make" ...$makeArgs

  if not $attrs.dontCopyDist {
    let tarballDir = ($env.out | path join "tarballs")
    mkdir $tarballDir
    let sources = if ($attrs.tarballs | is-not-empty) {
      $attrs.tarballs
    } else {
      glob "*.tar.gz"
    }
    for t in $sources {
      if ($t | path exists) { cp -v $t $tarballDir }
    }
  }
}

let phaseList = if ($attrs.phases | is-not-empty) {
  $attrs.phases
} else {
  $attrs.prePhases
  | append ["unpack"]
  | append ["patch"]
  | append $attrs.preConfigurePhases
  | append ["configure"]
  | append $attrs.preBuildPhases
  | append ["build"]
  | append ["check"]
  | append $attrs.preInstallPhases
  | append ["install"]
  | append $attrs.preFixupPhases
  | append ["fixup"]
  | append ["installCheck"]
  | append $attrs.preDistPhases
  | append ["dist"]
  | append $attrs.postPhases
}

# Tracks the source root after the unpack phase so we can cd into it.
mut sourceRoot = if ($attrs.sourceRoot | is-not-empty) { $attrs.sourceRoot } else { "" }

if $nix.debug { log debug "REALISATION" }

for phase in $phaseList {
  if (shouldSkip $phase $attrs) {
    if $nix.debug { log info $"Skipping phase: ($phase)" }
    continue
  }

  showPhaseHeader $phase
  let tStart = (date now | into int)

  let cap = (phaseCapitalized $phase)
  do $runHook $"pre($cap)"

  let hasUser = (do $runUserPhase $phase)

  if not $hasUser {
    match $phase {
      "unpack" => {
        let root = (do $defaultUnpack)
        $sourceRoot = $root
      }
      "patch"        => { do $defaultPatch }
      "configure"    => { do $defaultConfigure }
      "build"        => { do $defaultBuild }
      "check"        => { do $defaultCheck }
      "install"      => { do $defaultInstall }
      "fixup"        => { do $defaultFixup }
      "installCheck" => { do $defaultInstallCheck }
      "dist"         => { do $defaultDist }
      _ => {
        if $nix.debug {
          log info $"No default implementation for custom phase '($phase)'; nothing to do."
        }
      }
    }
  }

  do $runHook $"post($cap)"

  let tEnd = (date now | into int)
  showPhaseFooter $phase $tStart $tEnd

  # After unpack, change into the source root directory so all subsequent
  # phases (patch, configure, build …) operate on the right tree.
  if $phase == "unpack" and ($sourceRoot | is-not-empty) {
    if $nix.debug { log info $"Entering source root: ($sourceRoot)" }
    cd $sourceRoot
  }
}

if $nix.debug {
  log info "Outputs written:"
  for output in $drv.outputs {
    item $"(ansi yellow)($output.key)(ansi reset) → (ansi purple)($output.value)(ansi reset)"
  }
  log debug "DONE!"
}
