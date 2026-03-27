{
  lib,
  nuenv,
}:
lib.extendMkDerivation {
  constructDrv = nuenv.mkDerivation;

  excludeDrvArgNames = [
    "packages"
    "inputsFrom"
  ];

  extendDrvArgs =
    _finalAttrs:
    {
      name ? "nix-shell",

      # Packages to add to the shell environment
      packages ? [ ],

      # Propagate all inputs from the listed derivations
      inputsFrom ? [ ],
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
    in
    {
      inherit name;

      buildInputs = mergeInputs "buildInputs";
      nativeBuildInputs = packages ++ (mergeInputs "nativeBuildInputs");
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
