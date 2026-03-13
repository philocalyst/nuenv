## Bootstrap script
# This script performs any necessary setup before the builder.nu script is run.

# Discover and load the .attrs.json file, which supplies Nuenv with all the
# information it needs to realise the derivation.

use env.nu *
use std/log

let attrs = (get_attrs)

log debug "Copying all .nu helper files into the sandbox"
for file in $attrs.__nu_env {
  # Strip the hash, etc.
  # Removing any non-dash character before a final literal dash
  # And removing
  let filename = ($file | str replace --regex '^[^-]+-' '')
  let target = $env.NIX_BUILD_TOP | path join $filename

  cp $file $target
}

# Set the PATH so that Nushell itself is discoverable. The PATH will be
# overwritten later.
$env.PATH = ($attrs.__nu_nushell | parse "{root}/nu" | get root.0)

# Run the Nushell builder
nu --commands (open $attrs.__nu_builder)
