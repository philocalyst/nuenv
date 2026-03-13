# Logging

# Get the attributes passed to a derivation
export def get_attrs [] {
  let attributes_file = $env.NIX_ATTRS_JSON_FILE
  let building_directory = $env.NIX_BUILD_TOP

  # This branching is a necessary workaround for a bug in the Nix CLI fixed in
  # https://github.com/NixOS/nix/pull/8053
  let attrsJsonFile = if ($attributes_file | path exists) {
    $attributes_file
  } else {
    $building_directory | path join ".attrs.json"
  }

  # Return as a structured table
  open $attrsJsonFile
}

# Misc helpers

## Add an "s" to the end of a word if n is greater than 1
export def plural [n: int] { if $n > 1 { "s" } else { "" } }

export def item [msg: string] { print $"(ansi purple) + (ansi rst) ($msg)"}

## Convert a Nix Boolean into a Nushell Boolean ("1" = true, "0" = false)
export def envToBool [var: string] {
  ($var | into int) == 1
}

## Get package root
export def getPkgRoot [path: path] { $path | parse "{root}/bin/{__bin}" | get root.0 }

## Get package name from full store path
export def getPkgName [storeRoot: path, path: path] {
  $path | parse --regex $"($storeRoot)/[^-]+-(?<pkg>.+)$" | get pkg.0
}
