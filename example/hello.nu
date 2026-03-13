# Variables
let out = $env.out
let helloFile = "hello.txt"
let shareDir = ($out) | path join "share"
let helloOutputFile = ($shareDir) | path join ($helloFile)
let message = $env.MESSAGE
let helloVersion = (hello --version | lines | get 0 | parse "hello (GNU Hello) {version}" | get version.0)

log info $"Running hello version (ansi blue)($helloVersion)(ansi reset)"
log info $"Creating (ansi blue)($out)(ansi reset) directory at (ansi purple)($shareDir)(ansi reset)"

mkdir $shareDir

log info $"Writing hello message to (ansi purple)($helloOutputFile)(ansi reset)"
hello --greeting $message | save $helloOutputFile

ensureFileExists $helloOutputFile

log info $"Substituting \"Bash\" for \"Nushell\" in (ansi purple)($helloOutputFile)(ansi reset)"
substituteInPlace $helloOutputFile --replace "Bash" --with "Nushell"
