## Bootstrap script
# This script performs any necessary setup before the builder.nu script is run.

# Discover and load the .attrs.json file, which supplies Nuenv with all the
# information it needs to realise the derivation.

use env.nu *
use std/log

let attrs = (get_attrs)

log debug "Copying all .nu helper files into the sandbox"
for file in $attrs.__nu_env {
  let filename = ($file | path basename)
  let target = $env.NIX_BUILD_TOP | path join $filename
  cp $file $target
}

# Copy the builder script into the sandbox so it can find env.nu
let builder_name = ($attrs.__nu_builder | path basename)
cp $attrs.__nu_builder ($env.NIX_BUILD_TOP | path join $builder_name)

# Set the PATH so that Nushell itself is discoverable. The PATH will be
# overwritten later.
$env.PATH = ($attrs.__nu_nushell | parse "{root}/nu" | get root.0)

# Run the Nushell builder from NIX_BUILD_TOP so it can find env.nu
cd $env.NIX_BUILD_TOP
nu $builder_name
