{
  # The Nuenv build function. A wrapper around Nix's core derivation function that
  mkNushellDerivation =
    nushell: # nixpkgs.nushell (from overlay)
    sys: # nixpkgs.system (from overlay)

    # Accept either a plain attrset or a fixed-point function.  lib.extendMkDerivation
    # (and stdenv.mkDerivation) pass a function `final: attrs` rather than a plain set.
    fpOrAttrs:

    (
      {
        name, # The name of the derivation
        src, # The derivation's primary source (path or derivation)
      packages ? [ ], # Packages provided to the realisation process
      system ? sys, # The build system
      debug ? true, # Run in debug mode
      outputs ? [ "out" ], # Outputs to provide
      envFile ? ../nuenv/user-env.nu, # Nushell environment passed to build phases

      unpack ? "", # Extract source archives
      patch ? "", # Apply patches
      configure ? "", # Run configure script
      build ? "", # Compile / build
      check ? "", # Run tests  (requires doCheck = true)
      install ? "", # Install into $out
      fixup ? "", # Strip, patchShebangs, record propagated deps
      installCheck ? "", # Post-install tests  (requires doInstallCheck = true)
      dist ? "", # Create release tarballs  (requires doDist = true)

      preUnpack ? "",
      postUnpack ? "",
      prePatch ? "",
      postPatch ? "",
      preConfigure ? "",
      postConfigure ? "",
      preBuild ? "",
      postBuild ? "",
      preCheck ? "",
      postCheck ? "",
      preInstall ? "",
      postInstall ? "",
      preFixup ? "",
      postFixup ? "",
      preInstallCheck ? "",
      postInstallCheck ? "",
      preDist ? "",
      postDist ? "",

      # Override the full list, or prepend phases to standard insertion points.
      phases ? [ ],
      prePhases ? [ ],
      preConfigurePhases ? [ ],
      preBuildPhases ? [ ],
      preInstallPhases ? [ ],
      preFixupPhases ? [ ],
      preDistPhases ? [ ],
      postPhases ? [ ],

      dontUnpack ? false,
      dontPatch ? false,
      dontConfigure ? false,
      dontBuild ? false,
      doCheck ? false, # check phase is opt-in
      dontInstall ? false,
      dontFixup ? false,
      doInstallCheck ? false, # installCheck phase is opt-in
      doDist ? false, # dist phase is opt-in

      srcs ? [ ], # Additional / alternative sources
      patches ? [ ], # List of patch files to apply
      patchFlags ? [ "-p1" ], # Flags passed to `patch`

      # make
      makeFlags ? [ ],
      makefile ? "",
      buildFlags ? [ ],
      buildFlagsArray ? [ ],
      installFlags ? [ ],
      installFlagsArray ? [ ],
      installTargets ? [ "install" ],
      checkFlags ? [ ],
      checkFlagsArray ? [ ],
      checkTarget ? "",
      installCheckFlags ? [ ],
      installCheckFlagsArray ? [ ],
      installCheckTarget ? "",
      distFlags ? [ ],
      distFlagsArray ? [ ],
      distTarget ? "dist",
      tarballs ? [ ],
      dontCopyDist ? false,

      # config vars
      configureScript ? "",
      configureFlags ? [ ],
      configureFlagsArray ? [ ],
      prefix ? "", # Defaults to $out at build time
      prefixKey ? "--prefix=",
      dontAddPrefix ? false,
      dontAddDisableDepTrack ? false,
      dontDisableStatic ? false,
      dontPatchShebangsInConfigure ? false,

      # fixup variables
      dontStrip ? false,
      dontStripHost ? false,
      dontStripTarget ? false,
      stripAllList ? [ ],
      stripAllFlags ? [ "--strip-all" ],
      stripDebugList ? [ ],
      stripDebugFlags ? [
        "--strip-debug"
        "--keep-file-symbols"
      ],
      dontPatchELF ? false,
      dontPatchShebangs ? false,
      setupHook ? "",
      setupHooks ? [ ],
      propagatedBuildInputs ? [ ],
      propagatedNativeBuildInputs ? [ ],
      propagatedUserEnvPkgs ? [ ],

      # misc
      dontMakeSourcesWritable ? false,
      sourceRoot ? "", # Override auto-detected source root
      enableParallelBuilding ? false,
      enableParallelChecking ? false,
      enableParallelInstalling ? false,

      ... # Catch user-supplied environment variables
    }@attrs:

    let
      # All nuenv .nu scripts live in a single store directory so they can
      # resolve each other at parse time (use env.nu, use std/log, etc.)
      nuenvDir = ../nuenv;

      # Attributes consumed internally — excluded from __nu_extra_attrs so
      # they are not re-exported as arbitrary environment variables.
      reservedAttrs = [
        "name"
        "src"
        "packages"
        "system"
        "debug"
        "outputs"
        "envFile"

        # phases
        "unpack"
        "patch"
        "configure"
        "build"
        "check"
        "install"
        "fixup"
        "installCheck"
        "dist"

        # hooks
        "preUnpack"
        "postUnpack"
        "prePatch"
        "postPatch"
        "preConfigure"
        "postConfigure"
        "preBuild"
        "postBuild"
        "preCheck"
        "postCheck"
        "preInstall"
        "postInstall"
        "preFixup"
        "postFixup"
        "preInstallCheck"
        "postInstallCheck"
        "preDist"
        "postDist"

        # phase ordering
        "phases"
        "prePhases"
        "preConfigurePhases"
        "preBuildPhases"
        "preInstallPhases"
        "preFixupPhases"
        "preDistPhases"
        "postPhases"

        # phase control
        "dontUnpack"
        "dontPatch"
        "dontConfigure"
        "dontBuild"
        "doCheck"
        "dontInstall"
        "dontFixup"
        "doInstallCheck"
        "doDist"

        # sources
        "srcs"
        "patches"
        "patchFlags"

        # make
        "makeFlags"
        "makefile"
        "buildFlags"
        "buildFlagsArray"
        "installFlags"
        "installFlagsArray"
        "installTargets"
        "checkFlags"
        "checkFlagsArray"
        "checkTarget"
        "installCheckFlags"
        "installCheckFlagsArray"
        "installCheckTarget"
        "distFlags"
        "distFlagsArray"
        "distTarget"
        "tarballs"
        "dontCopyDist"

        # configure
        "configureScript"
        "configureFlags"
        "configureFlagsArray"
        "prefix"
        "prefixKey"
        "dontAddPrefix"
        "dontAddDisableDepTrack"
        "dontDisableStatic"
        "dontPatchShebangsInConfigure"

        # fixup
        "dontStrip"
        "dontStripHost"
        "dontStripTarget"
        "stripAllList"
        "stripAllFlags"
        "stripDebugList"
        "stripDebugFlags"
        "dontPatchELF"
        "dontPatchShebangs"
        "setupHook"
        "setupHooks"
        "propagatedBuildInputs"
        "propagatedNativeBuildInputs"
        "propagatedUserEnvPkgs"

        # misc
        "dontMakeSourcesWritable"
        "sourceRoot"
        "enableParallelBuilding"
        "enableParallelChecking"
        "enableParallelInstalling"

        # internal
        "__nu_builder"
        "__nu_debug"
        "__nu_env"
        "__nu_extra_attrs"
        "__nu_nushell"
      ];

      extraAttrs = removeAttrs attrs reservedAttrs;
    in
    derivation (
      {
        # Core
        inherit
          name
          src
          packages
          system
          outputs
          envFile
          ;

        # Phases
        inherit
          unpack
          patch
          configure
          build
          check
          install
          fixup
          installCheck
          dist
          ;

        # Hooks
        inherit
          preUnpack
          postUnpack
          prePatch
          postPatch
          preConfigure
          postConfigure
          preBuild
          postBuild
          preCheck
          postCheck
          preInstall
          postInstall
          preFixup
          postFixup
          preInstallCheck
          postInstallCheck
          preDist
          postDist
          ;

        # Phase ordering
        inherit
          phases
          prePhases
          preConfigurePhases
          preBuildPhases
          preInstallPhases
          preFixupPhases
          preDistPhases
          postPhases
          ;

        # Phase control
        inherit
          dontUnpack
          dontPatch
          dontConfigure
          dontBuild
          doCheck
          dontInstall
          dontFixup
          doInstallCheck
          doDist
          ;

        # Sources
        inherit srcs patches patchFlags;

        # make
        inherit
          makeFlags
          makefile
          buildFlags
          buildFlagsArray
          installFlags
          installFlagsArray
          installTargets
          checkFlags
          checkFlagsArray
          checkTarget
          installCheckFlags
          installCheckFlagsArray
          installCheckTarget
          distFlags
          distFlagsArray
          distTarget
          tarballs
          dontCopyDist
          ;

        # configure
        inherit
          configureScript
          configureFlags
          configureFlagsArray
          prefix
          prefixKey
          dontAddPrefix
          dontAddDisableDepTrack
          dontDisableStatic
          dontPatchShebangsInConfigure
          ;

        # fixup
        inherit
          dontStrip
          dontStripHost
          dontStripTarget
          stripAllList
          stripAllFlags
          stripDebugList
          stripDebugFlags
          dontPatchELF
          dontPatchShebangs
          setupHook
          setupHooks
          propagatedBuildInputs
          propagatedNativeBuildInputs
          propagatedUserEnvPkgs
          ;

        # misc
        inherit
          dontMakeSourcesWritable
          sourceRoot
          enableParallelBuilding
          enableParallelChecking
          enableParallelInstalling
          ;

        # Build infrastructure
        builder = "${nushell}/bin/nu";
        args = [ "${nuenvDir}/bootstrap.nu" ];

        # When this is set, Nix writes the environment to a JSON file at
        # $NIX_BUILD_TOP/.attrs.json. Because Nushell can handle JSON natively, this approach
        __structuredAttrs = true;

        __nu_builder = "${nuenvDir}/builder.nu";
        __nu_debug = debug;
        __nu_env = [ "${nuenvDir}/env.nu" ];
        __nu_extra_attrs = extraAttrs;
        __nu_nushell = "${nushell}/bin/nu";
      }
      // extraAttrs
    )
  ) (if builtins.isFunction fpOrAttrs then let self = fpOrAttrs self; in self else fpOrAttrs);

  # An analogue to writeScriptBin but for Nushell rather than Bash scripts.
  mkNushellScript =
    nushell: # nixpkgs.nushell (from overlay)
    writeTextFile: # Utility function (from overlay)

    {
      name,
      script,
      bin ? name,
    }:

    let
      nu = "${nushell}/bin/nu";
    in
    writeTextFile {
      inherit name;
      destination = "/bin/${bin}";
      text = ''
        #!${nu}

        ${script}
      '';
      executable = true;
    };
}
