{
  lib,
  nuenv,
  nushell,
  writeTextFile,
}:
lib.extendMkDerivation {
  constructDrv = nuenv.mkDerivation;

  excludeDrvArgNames = [
    "packages"
    "inputsFrom"
    "commands"
    "commandsDir"
  ];

  extendDrvArgs =
    _finalAttrs:
    {
      name ? "nix-shell",

      # Packages to add to the shell environment
      packages ? [ ],

      # Propagate all inputs from the listed derivations
      inputsFrom ? [ ],

      # Nushell script files to expose as shell commands.
      # Each entry may be a path (e.g. ./scripts/ci.nu) or a bare name string
      # (e.g. "ci") resolved relative to `commandsDir`.
      # A thin wrapper named after the file (without .nu) is added to PATH so
      # the script is callable directly from `nix develop` / `nix shell`.
      commands ? [ ],

      # Base directory used to resolve bare-name entries in `commands`.
      # Example: commandsDir = ./.config/scripts; commands = [ "ci" "build" ];
      commandsDir ? null,
      ...
    }@attrs:
    let
      # Merge a single input-list attribute from all inputsFrom derivations,
      # excluding the derivations themselves.
      mergeInputs =
        attrName:
        (attrs.${attrName} or [ ])
        ++ (lib.subtractLists inputsFrom (lib.flatten (lib.catAttrs attrName inputsFrom)));

      # Accept either the nuenv-style name ("build") or the nixpkgs-style
      # work out of the box.
      resolvePhase =
        nuenvName: nixpkgsName: fallback:
        attrs.${nuenvName} or attrs.${nixpkgsName} or fallback;

      # Resolve each commands entry to { name, path }.
      # - Path values are used directly; the command name is the basename
      #   with the .nu suffix removed.
      # - String values are treated as bare names; commandsDir must be set.
      resolvedCommands = map (
        cmd:
        if builtins.isPath cmd || lib.isDerivation cmd then
          {
            path = cmd;
            name = lib.removeSuffix ".nu" (builtins.baseNameOf (builtins.toString cmd));
          }
        else
          let
            bareName = lib.removeSuffix ".nu" cmd;
          in
          {
            name = bareName;
            path =
              if commandsDir != null then
                commandsDir + "/${bareName}.nu"
              else
                throw "nuenv.mkShell: commands entry '${cmd}' is a string but commandsDir is not set";
          }
      ) commands;

      # For each resolved command, create a thin wrapper that runs the .nu
      # script via the Nushell binary so it is available in PATH.
      commandPkgs = map (
        { name, path }:
        writeTextFile {
          inherit name;
          destination = "/bin/${name}";
          executable = true;
          text = ''
            #!/bin/sh
            exec ${nushell}/bin/nu ${path} "$@"
          '';
        }
      ) resolvedCommands;
    in
    {
      inherit name;

      # mkShell does not require a real source; use a dummy unless the caller
      # explicitly provides one.
      src = attrs.src or (builtins.toFile "nuenv-shell-src" "");

      buildInputs = mergeInputs "buildInputs";
      nativeBuildInputs = packages ++ commandPkgs ++ (mergeInputs "nativeBuildInputs");
      propagatedBuildInputs = mergeInputs "propagatedBuildInputs";
      propagatedNativeBuildInputs = mergeInputs "propagatedNativeBuildInputs";

      # Concatenate shellHooks from all inputsFrom derivations (deepest first),
      # then the shell's own hook
      shellHook = lib.concatStringsSep "\n" (
        lib.catAttrs "shellHook" (lib.reverseList inputsFrom ++ [ attrs ])
      );

      unpack = resolvePhase "unpack" "unpackPhase" "";
      patch = resolvePhase "patch" "patchPhase" "";
      configure = resolvePhase "configure" "configurePhase" "";
      check = resolvePhase "check" "checkPhase" "";
      install = resolvePhase "install" "installPhase" "";
      fixup = resolvePhase "fixup" "fixupPhase" "";
      installCheck = resolvePhase "installCheck" "installCheckPhase" "";
      dist = resolvePhase "dist" "distPhase" "";

      # The build/buildPhase is the most commonly customised phase; provide a
      # sensible default that records the environment for introspection.
      build = resolvePhase "build" "buildPhase" ''
        {
          print "------------------------------------------------------------"
          print " WARNING: the existence of this path is not guaranteed."
          print " It is an internal implementation detail for nuenv.mkShell."
          print "------------------------------------------------------------"
          print ""
          # Record all environment variables for debugging
          $env | table --expand | save --force $env.out
        }
      '';

      preUnpack = resolvePhase "preUnpack" "preUnpack" "";
      postUnpack = resolvePhase "postUnpack" "postUnpack" "";
      prePatch = resolvePhase "prePatch" "prePatch" "";
      postPatch = resolvePhase "postPatch" "postPatch" "";
      preConfigure = resolvePhase "preConfigure" "preConfigure" "";
      postConfigure = resolvePhase "postConfigure" "postConfigure" "";
      preBuild = resolvePhase "preBuild" "preBuild" "";
      postBuild = resolvePhase "postBuild" "postBuild" "";
      preCheck = resolvePhase "preCheck" "preCheck" "";
      postCheck = resolvePhase "postCheck" "postCheck" "";
      preInstall = resolvePhase "preInstall" "preInstall" "";
      postInstall = resolvePhase "postInstall" "postInstall" "";
      preFixup = resolvePhase "preFixup" "preFixup" "";
      postFixup = resolvePhase "postFixup" "postFixup" "";
      preInstallCheck = resolvePhase "preInstallCheck" "preInstallCheck" "";
      postInstallCheck = resolvePhase "postInstallCheck" "postInstallCheck" "";
      preDist = resolvePhase "preDist" "preDist" "";
      postDist = resolvePhase "postDist" "postDist" "";

      preferLocalBuild = attrs.preferLocalBuild or true;
    };
}
