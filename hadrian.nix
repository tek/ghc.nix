{ version, bindist, rev ? null }:
{ lib
, stdenv
, pkgsBuildTarget
, pkgsHostTarget
, targetPackages
, fetchpatch

# build-tools
, autoconf
, automake
, coreutils
, fetchurl
, fetchgit
, perl
, python3
, m4
, sphinx
, xattr
, bash
, srcOnly
, autoPatchelfHook

, libiconv ? null, ncurses, numactl
, glibcLocales ? null

, # GHC can be built with system libffi or a bundled one.
  libffi ? null

, useLLVM ? !(stdenv.targetPlatform.isx86
              || stdenv.targetPlatform.isPower
              || stdenv.targetPlatform.isSparc
              || stdenv.targetPlatform.isAarch64
              || stdenv.targetPlatform.isGhcjs)
, # LLVM is conceptually a run-time-only dependency, but for
  # non-x86, we need LLVM to bootstrap later stages, so it becomes a
  # build-time dependency too.
  buildTargetLlvmPackages
, llvmPackages

, # If enabled, GHC will be built with the GPL-free but slightly slower native
  # bignum backend instead of the faster but GPLed gmp backend.
  enableNativeBignum ? !(lib.meta.availableOn stdenv.hostPlatform gmp
                         && lib.meta.availableOn stdenv.targetPlatform gmp)
                       || stdenv.targetPlatform.isGhcjs
, gmp

, # If enabled, use -fPIC when compiling static libs.
  enableRelocatedStaticLibs ? stdenv.targetPlatform != stdenv.hostPlatform

, # Whether to build terminfo.
  enableTerminfo ? !(stdenv.targetPlatform.isWindows
                     || stdenv.targetPlatform.isGhcjs)

, # Libdw.c only supports x86_64, i686 and s390x as of 2022-08-04
  enableDwarf ? (stdenv.targetPlatform.isx86 ||
                 (stdenv.targetPlatform.isS390 && stdenv.targetPlatform.is64bit)) &&
                lib.meta.availableOn stdenv.hostPlatform elfutils &&
                lib.meta.availableOn stdenv.targetPlatform elfutils &&
                # HACK: elfutils is marked as broken on static platforms
                # which availableOn can't tell.
                !stdenv.targetPlatform.isStatic &&
                !stdenv.hostPlatform.isStatic
, elfutils

}:

assert !enableNativeBignum -> gmp != null;

let
  inherit (stdenv) hostPlatform targetPlatform;

  # TODO(@Ericson2314) Make unconditional
  targetPrefix = lib.optionalString
    (targetPlatform != hostPlatform)
    "${targetPlatform.config}-";

  hadrianSettings =
    # -fexternal-dynamic-refs apparently (because it's not clear from the
    # documentation) makes the GHC RTS able to load static libraries, which may
    # be needed for TemplateHaskell. This solution was described in
    # https://www.tweag.io/blog/2020-09-30-bazel-static-haskell
    lib.optionals enableRelocatedStaticLibs [
      "*.*.ghc.*.opts += -fPIC -fexternal-dynamic-refs"
    ];

  # Splicer will pull out correct variations
  libDeps = platform: lib.optional enableTerminfo ncurses
    ++ [numactl]
    ++ lib.optionals (!targetPlatform.isGhcjs) [libffi]
    # Bindist configure script fails w/o elfutils in linker search path
    # https://gitlab.haskell.org/ghc/ghc/-/issues/22081
    ++ lib.optional enableDwarf elfutils
    ++ lib.optional (!enableNativeBignum) gmp
    ++ lib.optional (platform.libc != "glibc" && !targetPlatform.isWindows && !targetPlatform.isGhcjs) libiconv;

  # TODO(@sternenseemann): is buildTarget LLVM unnecessary?
  # GHC doesn't seem to have {LLC,OPT}_HOST
  toolsForTarget = [
    (if targetPlatform.isGhcjs
     then pkgsBuildTarget.emscripten
     else pkgsBuildTarget.targetPackages.stdenv.cc)
  ] ++ lib.optional useLLVM buildTargetLlvmPackages.llvm;

  targetCC = builtins.head toolsForTarget;

  # toolPath calculates the absolute path to the name tool associated with a
  # given `stdenv.cc` derivation, i.e. it picks the correct derivation to take
  # the tool from (cc, cc.bintools, cc.bintools.bintools) and adds the correct
  # subpath of the tool.
  toolPath = name: cc:
    let
      tools = {
        "cc" = cc;
        "c++" = cc;
        as = cc.bintools.bintools;

        ar = cc.bintools.bintools;
        ranlib = cc.bintools.bintools;
        nm = cc.bintools.bintools;
        readelf = cc.bintools.bintools;

        ld = cc.bintools;
        "ld.gold" = cc.bintools;

        otool = cc.bintools.bintools;

        # GHC needs install_name_tool on all darwin platforms. On aarch64-darwin it is
        # part of the bintools wrapper (due to codesigning requirements), but not on
        # x86_64-darwin. We decide based on target platform to have consistent tools
        # across all GHC stages.
        install_name_tool =
          if stdenv.targetPlatform.isAarch64
          then cc.bintools
          else cc.bintools.bintools;
        # Same goes for strip.
        strip =
          # TODO(@sternenseemann): also use wrapper if linker == "bfd" or "gold"
          if stdenv.targetPlatform.isAarch64 && stdenv.targetPlatform.isDarwin
          then cc.bintools
          else cc.bintools.bintools;
      }.${name};
    in
    "${tools}/bin/${tools.targetPrefix}${name}";

  # Use gold either following the default, or to avoid the BFD linker due to some bugs / perf issues.
  # But we cannot avoid BFD when using musl libc due to https://sourceware.org/bugzilla/show_bug.cgi?id=23856
  # see #84670 and #49071 for more background.
  useLdGold = targetPlatform.linker == "gold" ||
    (targetPlatform.linker == "bfd" && (targetCC.bintools.bintools.hasGold or false) && !targetPlatform.isMusl);

  # Makes debugging easier to see which variant is at play in `nix-store -q --tree`.
  variantSuffix = lib.concatStrings [
    (lib.optionalString stdenv.hostPlatform.isMusl "-musl")
    (lib.optionalString enableNativeBignum "-native-bignum")
  ];

in

# C compiler, bintools and LLVM are used at build time, but will also leak into
# the resulting GHC's settings file and used at runtime. This means that we are
# currently only able to build GHC if hostPlatform == buildPlatform.
assert !targetPlatform.isGhcjs -> targetCC == pkgsHostTarget.targetPackages.stdenv.cc;
assert buildTargetLlvmPackages.llvm == llvmPackages.llvm;
assert stdenv.targetPlatform.isDarwin -> buildTargetLlvmPackages.clang == llvmPackages.clang;

stdenv.mkDerivation ({
  pname = "${targetPrefix}ghc${variantSuffix}";
  inherit version;

  src = bindist;

  enableParallelBuilding = true;

  postPatch = ''
    patchShebangs --build .
  '';

  # GHC needs the locale configured during the Haddock phase.
  LANG = "en_US.UTF-8";

  preConfigure = ''
    for env in $(env | grep '^TARGET_' | sed -E 's|\+?=.*||'); do
      export "''${env#TARGET_}=''${!env}"
    done
    # GHC is a bit confused on its cross terminology, as these would normally be
    # the *host* tools.
    export CC="${toolPath "cc" targetCC}"
    export CXX="${toolPath "c++" targetCC}"
    # Use gold to work around https://sourceware.org/bugzilla/show_bug.cgi?id=16177
    export LD="${toolPath "ld${lib.optionalString useLdGold ".gold"}" targetCC}"
    export AS="${toolPath "as" targetCC}"
    export AR="${toolPath "ar" targetCC}"
    export NM="${toolPath "nm" targetCC}"
    export RANLIB="${toolPath "ranlib" targetCC}"
    export READELF="${toolPath "readelf" targetCC}"
    export STRIP="${toolPath "strip" targetCC}"
  '' + lib.optionalString (stdenv.targetPlatform.linker == "cctools") ''
    export OTOOL="${toolPath "otool" targetCC}"
    export INSTALL_NAME_TOOL="${toolPath "install_name_tool" targetCC}"
    export InstallNameToolCmd=$INSTALL_NAME_TOOL
    export OtoolCmd=$OTOOL
  '' + lib.optionalString useLLVM ''
    export LLC="${lib.getBin buildTargetLlvmPackages.llvm}/bin/llc"
    export OPT="${lib.getBin buildTargetLlvmPackages.llvm}/bin/opt"
  '' + lib.optionalString (useLLVM && stdenv.targetPlatform.isDarwin) ''
    # LLVM backend on Darwin needs clang: https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/codegens.html#llvm-code-generator-fllvm
    export CLANG="${buildTargetLlvmPackages.clang}/bin/${buildTargetLlvmPackages.clang.targetPrefix}clang"
  '' +
  lib.optionalString (stdenv.isLinux && hostPlatform.libc == "glibc") ''
    export LOCALE_ARCHIVE="${glibcLocales}/lib/locale/locale-archive"
  '' + lib.optionalString (!stdenv.isDarwin) ''
    export NIX_LDFLAGS+=" -rpath $out/lib/ghc-${version}"
  '' + lib.optionalString stdenv.isDarwin ''
    export NIX_LDFLAGS+=" -no_dtrace_dof"

    # GHC tries the host xattr /usr/bin/xattr by default which fails since it expects python to be 2.7
    export XATTR=${lib.getBin xattr}/bin/xattr
  ''
  + ''
    hadrianFlagsArray=(
      "-j$NIX_BUILD_CORES"
      ${lib.escapeShellArgs hadrianSettings}
    )
  '';

  configurePlatforms = [ "build" "host" ]
    ++ lib.optional (targetPlatform != hostPlatform) "target";

  # `--with` flags for libraries needed for RTS linker
  configureFlags = [
    "--datadir=$doc/share/doc/ghc"
    "--with-curses-includes=${ncurses.dev}/include"
    "--with-curses-libraries=${ncurses.out}/lib"
    "--with-libnuma-includes=${numactl}/include"
    "--with-libnuma-libraries=${numactl}/lib"
  ] ++ lib.optionals (libffi != null && !targetPlatform.isGhcjs) [
    "--with-system-libffi"
    "--with-ffi-includes=${targetPackages.libffi.dev}/include"
    "--with-ffi-libraries=${targetPackages.libffi.out}/lib"
  ] ++ lib.optionals (targetPlatform == hostPlatform && !enableNativeBignum) [
    "--with-gmp-includes=${targetPackages.gmp.dev}/include"
    "--with-gmp-libraries=${targetPackages.gmp.out}/lib"
  ] ++ lib.optionals (targetPlatform == hostPlatform && hostPlatform.libc != "glibc" && !targetPlatform.isWindows) [
    "--with-iconv-includes=${libiconv}/include"
    "--with-iconv-libraries=${libiconv}/lib"
  ] ++ lib.optionals (targetPlatform != hostPlatform) [
    "--enable-bootstrap-with-devel-snapshot"
  ] ++ lib.optionals useLdGold [
    "CFLAGS=-fuse-ld=gold"
    "CONF_GCC_LINKER_OPTS_STAGE1=-fuse-ld=gold"
    "CONF_GCC_LINKER_OPTS_STAGE2=-fuse-ld=gold"
  ] ++ lib.optionals enableDwarf [
    "--enable-dwarf-unwind"
    "--with-libdw-includes=${lib.getDev targetPackages.elfutils}/include"
    "--with-libdw-libraries=${lib.getLib targetPackages.elfutils}/lib"
  ] ++ lib.optionals targetPlatform.isDarwin [
    # Darwin uses llvm-ar. GHC will try to use `-L` with `ar` when it is `llvm-ar`
    # but it doesn’t currently work because Cabal never uses `-L` on Darwin. See:
    # https://gitlab.haskell.org/ghc/ghc/-/issues/23188
    # https://github.com/haskell/cabal/issues/8882
    "fp_cv_prog_ar_supports_dash_l=no"
  ];

  # Make sure we never relax`$PATH` and hooks support for compatibility.
  strictDeps = true;

  # Don’t add -liconv to LDFLAGS automatically so that GHC will add it itself.
  dontAddExtraLibs = true;

  nativeBuildInputs = [
    perl
    # autoconf and friends are necessary for hadrian to create the bindist
    autoconf automake m4
    # Python is used in a few scripts invoked by hadrian to generate e.g. rts headers.
    python3
    autoPatchelfHook
  ];

  # For building runtime libs
  depsBuildTarget = toolsForTarget;

  buildInputs = [ perl bash ] ++ (libDeps hostPlatform);

  depsTargetTarget = map lib.getDev (libDeps targetPlatform);
  depsTargetTargetPropagated = map (lib.getOutput "out") (libDeps targetPlatform);

  buildPhase = ''
    runHook preBuild
    addAutoPatchelfSearchPath lib
    autoPatchelf bin/ghc-pkg-9.8.2
    extraAutoPatchelfLibs=()
    runHook postBuild
  '';

  preFixup = ''
    patchelf --remove-rpath $out/lib/ghc-9.8.2/bin/ghc-pkg-9.8.2
    addAutoPatchelfSearchPath "$out/lib/ghc-9.8.2/lib/x86_64-linux-ghc-9.8.2"
  '';

  dontStrip = true;
  dontPatchELF = true;

  # required, because otherwise all symbols from HSffi.o are stripped, and
  # that in turn causes GHCi to abort
  # stripDebugFlags = [ "-S" ] ++ lib.optional (!targetPlatform.isDarwin) "--keep-file-symbols";

  checkTarget = "test";

  hardeningDisable =
    [ "format" ]
    # In nixpkgs, musl based builds currently enable `pie` hardening by default
    # (see `defaultHardeningFlags` in `make-derivation.nix`).
    # But GHC cannot currently produce outputs that are ready for `-pie` linking.
    # Thus, disable `pie` hardening, otherwise `recompile with -fPIE` errors appear.
    # See:
    # * https://github.com/NixOS/nixpkgs/issues/129247
    # * https://gitlab.haskell.org/ghc/ghc/-/issues/19580
    ++ lib.optional stdenv.targetPlatform.isMusl "pie";

  # big-parallel allows us to build with more than 2 cores on
  # Hydra which already warrants a significant speedup
  requiredSystemFeatures = [ "big-parallel" ];

  outputs = [ "out" "doc" ];

  passthru = {
    inherit targetPrefix;
    inherit llvmPackages;
    haskellCompilerName = "ghc-${version}";
    hasHaddock = stdenv.hostPlatform == stdenv.targetPlatform;
    enableShared = true;
  };

  meta = {
    homepage = "http://haskell.org/ghc";
    description = "Glasgow Haskell Compiler";
    maintainers = [];
    timeout = 24 * 3600;
    license = lib.licenses.bsd3;
    platforms = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  };
})
