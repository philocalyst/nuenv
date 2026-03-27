use std/log

# Return the path of <path> relative to the Nix store root or the build
# directory, for concise log output.
export def relativePath [
  path: path,  # The absolute path to shorten
] {
  if ($path | str starts-with $env.NIX_BUILD_TOP) {
    $path | str replace $"($env.NIX_BUILD_TOP)/" ""
  } else if ($path | str starts-with $env.NIX_STORE) {
    $path | parse $"($env.NIX_STORE)/{_pkg}/{rest}" | get rest.0? | default $path
  } else {
    $path
  }
}

# Assert that <file> exists; exit with a clear error message if it does not.
export def ensureFileExists [
  file: path,  # The path that must exist
] {
  if not ($file | path exists) {
    log error $"File not found: (ansi red)(relativePath $file)(ansi reset)"
    exit 1
  }
}

# Copy <src> to <dest>, creating parent directories as needed.
export def install [
  src: path,
  dest: path,
  --mode (-m): string = "",  # Optional chmod mode string (e.g. "755")
] {
  ensureFileExists $src
  let parent = ($dest | path dirname)
  if ($parent | is-not-empty) { mkdir $parent }
  cp $src $dest
  if ($mode | is-not-empty) { ^chmod $mode $dest }
}

# Write a copy of <file> to <out> with every occurrence of <replace> replaced
# by <with>.
export def substitute [
  file: path,  # Source file
  out: path,   # Destination file
  --replace (-r): string,  # String to search for
  --with (-w): string,     # Replacement string
] {
  ensureFileExists $file
  open --raw $file
    | str replace --all $replace $with
    | save --force $out
}

# Replace every occurrence of <replace> with <with> in-place across all given
# files.
export def substituteInPlace [
  ...files: path,          # One or more files to edit in place
  --replace (-r): string,  # String to search for
  --with (-w): string,     # Replacement string
] {
  for file in $files {
    substitute $file $file --replace $replace --with $with
  }
}

# Replace every line matching a regex pattern with a fixed replacement string.
export def substituteInPlaceRegex [
  ...files: path,           # One or more files to edit in place
  --pattern (-p): string,   # Regular-expression pattern
  --with (-w): string,      # Replacement string (literal, not a regex)
] {
  for file in $files {
    ensureFileExists $file
    open --raw $file
      | str replace --all --regex $pattern $with
      | save --force $file
  }
}

# Patch interpreter shebangs in one or more directories or files, rewriting
# bare /usr/bin/foo paths to the resolved `which foo` store path.
# Mirrors nixpkgs' `patchShebangs`.
export def patchShebangs [
  ...targets: path,         # Directories or individual files to patch
  --build,                  # Patch using build-time PATH (default behaviour)
] {
  let storeDir = $env.NIX_STORE
  let allFiles = (
    $targets | each { |t|
      if ($t | path type) == "dir" {
        try { ^find $t -type f -perm -0100 | lines } catch { [] }
      } else {
        [$t]
      }
    } | flatten
  )

  for file in $allFiles {
    try {
      let raw   = (open --raw $file)
      let first = ($raw | lines | first)
      if not ($first | str starts-with "#!") { continue }

      let shebang = ($first | str replace "#!" "" | str trim)
      let parts   = ($shebang | split row " " | where { |p| ($p | is-not-empty) })
      if ($parts | is-empty) { continue }
      let interp  = ($parts | first)

      if ($interp | str starts-with $storeDir) { continue }
      if ($interp | str ends-with "/env") { continue }

      let interpName = ($interp | path basename)
      let newInterp  = (try { which $interpName | str trim } catch { "" })
      if ($newInterp | is-empty) { continue }

      let rest    = ($parts | skip 1 | str join " ")
      let newLine = if ($rest | is-not-empty) {
        $"#!($newInterp) ($rest)"
      } else {
        $"#!($newInterp)"
      }

      $raw | str replace $first $newLine | save --force $file
      log debug $"patched shebang in (relativePath $file): ($first) → ($newLine)"
    } catch { }
  }
}


# Create the standard bin/lib/share/include layout under a prefix.
export def mkDirs [
  prefix?: path,  # Defaults to $env.out
  --with-lib,     # Also create lib/
  --with-include, # Also create include/
  --with-share,   # Also create share/
] {
  let root = ($prefix | default $env.out)
  mkdir ($root | path join "bin")
  if $with_lib     { mkdir ($root | path join "lib") }
  if $with_include { mkdir ($root | path join "include") }
  if $with_share   { mkdir ($root | path join "share") }
}

# Copy a tree of files into an output directory, preserving relative structure.
export def copyTree [
  src: path,   # Source directory
  dest: path,  # Destination directory
] {
  if not ($src | path exists) {
    log error $"copyTree: source does not exist: ($src)"
    exit 1
  }
  mkdir $dest
  cp -r ($src | path join "*") $dest
}


# Write a simple wrapper script at <dest> that prepends entries to PATH and
# then execs <executable>.  Useful for wrapping binaries that need extra
# packages at runtime.
export def makeWrapper [
  executable: path,  # The binary to wrap
  dest: path,        # Where to write the wrapper
  --prefix-path: list<path> = [],  # Paths to prepend to PATH
  --set: record = {},              # Environment variables to set
] {
  let parent = ($dest | path dirname)
  if ($parent | is-not-empty) { mkdir $parent }

  mut lines = ["#!/bin/sh"]
  for p in $prefix_path {
    $lines = ($lines ++ [$"export PATH=\"($p)/bin:$PATH\""])
  }

  for col in ($set | columns) {
    let val = ($set | get $col)
    $lines = ($lines ++ [$"export ($col)=\"($val)\""])
  }

  $lines = ($lines ++ [$"exec ($executable) \"$@\""])

  $lines | str join "\n" | save --force $dest

  chmod +x $dest
}


# List all custom commands registered from this file.
export def nuenvCommands [] {
  help commands
    | where command_type == "custom"
    | where name not-in ["create_left_prompt" "create_right_prompt" "nuenvCommands"]
    | select name usage
}
