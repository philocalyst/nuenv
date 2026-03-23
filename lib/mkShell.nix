{
  lib,
  nuenv,
}:
# A special kind of derivation that is only meant to be consumed by the
# nix-shell.
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
      # a list of packages to add to the shell environment
      packages ? [ ],
      # propagate all the inputs from the given derivations
      inputsFrom ? [ ],
      ...
    }@attrs:
    let
      mergeInputs =
        name:
        (attrs.${name} or [ ])
        ++
          # 1. get all `{build,nativeBuild,...}Inputs` from the elements of `inputsFrom`
          # 2. since that is a list of lists, `flatten` that into a regular list
          # 3. filter out of the result everything that's in `inputsFrom` itself
          # this leaves actual dependencies of the derivations in `inputsFrom`, but never the derivations themselves
          (lib.subtractLists inputsFrom (lib.flatten (lib.catAttrs name inputsFrom)));
    in
    {
      inherit name;

      buildInputs = mergeInputs "buildInputs";
      nativeBuildInputs = packages ++ (mergeInputs "nativeBuildInputs");
      propagatedBuildInputs = mergeInputs "propagatedBuildInputs";
      propagatedNativeBuildInputs = mergeInputs "propagatedNativeBuildInputs";

      shellHook = lib.concatStringsSep "\n" (
        lib.catAttrs "shellHook" (lib.reverseList inputsFrom ++ [ attrs ])
      );

      # Map buildPhase to build for nuenv
      build =
        attrs.build or ''
          print "------------------------------------------------------------"
          print " WARNING: the existence of this path is not guaranteed."
          print " It is an internal implementation detail for nuenv.mkShell."
          print "------------------------------------------------------------"
          print ""
          # Record environment
          $env | table --expand | save $env.out
        '';

      preferLocalBuild = attrs.preferLocalBuild or true;
    };
}
