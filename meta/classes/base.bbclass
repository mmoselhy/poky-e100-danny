BB_DEFAULT_TASK ?= "build"
CLASSOVERRIDE ?= "class-target"

inherit patch
inherit staging

inherit mirrors
inherit utils
inherit utility-tasks
inherit metadata_scm
inherit logging

OE_IMPORTS += "os sys time oe.path oe.utils oe.data oe.package oe.packagegroup oe.sstatesig oe.lsb oe.cachedpath"
OE_IMPORTS[type] = "list"

def oe_import(d):
    import sys

    bbpath = d.getVar("BBPATH", True).split(":")
    sys.path[0:0] = [os.path.join(dir, "lib") for dir in bbpath]

    def inject(name, value):
        """Make a python object accessible from the metadata"""
        if hasattr(bb.utils, "_context"):
            bb.utils._context[name] = value
        else:
            __builtins__[name] = value

    import oe.data
    for toimport in oe.data.typed_value("OE_IMPORTS", d):
        imported = __import__(toimport)
        inject(toimport.split(".", 1)[0], imported)

python oe_import_eh () {
    if isinstance(e, bb.event.ConfigParsed):
        oe_import(e.data)
        e.data.setVar("NATIVELSBSTRING", lsb_distro_identifier(e.data))
}

addhandler oe_import_eh

def lsb_distro_identifier(d):
    adjust = d.getVar('LSB_DISTRO_ADJUST', True)
    adjust_func = None
    if adjust:
        try:
            adjust_func = globals()[adjust]
        except KeyError:
            pass
    return oe.lsb.distro_identifier(adjust_func)

die() {
	bbfatal "$*"
}

oe_runmake() {
	bbnote ${MAKE} ${EXTRA_OEMAKE} "$@"
	${MAKE} ${EXTRA_OEMAKE} "$@" || die "oe_runmake failed"
}


def base_dep_prepend(d):
    #
    # Ideally this will check a flag so we will operate properly in
    # the case where host == build == target, for now we don't work in
    # that case though.
    #

    deps = ""
    # INHIBIT_DEFAULT_DEPS doesn't apply to the patch command.  Whether or  not
    # we need that built is the responsibility of the patch function / class, not
    # the application.
    if not d.getVar('INHIBIT_DEFAULT_DEPS'):
        if (d.getVar('HOST_SYS', True) != d.getVar('BUILD_SYS', True)):
            deps += " virtual/${TARGET_PREFIX}gcc virtual/${TARGET_PREFIX}compilerlibs virtual/libc "
    return deps

BASEDEPENDS = "${@base_dep_prepend(d)}"

DEPENDS_prepend="${BASEDEPENDS} "

FILESPATH = "${@base_set_filespath(["${FILE_DIRNAME}/${BP}", "${FILE_DIRNAME}/${BPN}", "${FILE_DIRNAME}/files"], d)}"
# THISDIR only works properly with imediate expansion as it has to run
# in the context of the location its used (:=)
THISDIR = "${@os.path.dirname(d.getVar('FILE', True))}"

def extra_path_elements(d):
    path = ""
    elements = (d.getVar('EXTRANATIVEPATH', True) or "").split()
    for e in elements:
        path = path + "${STAGING_BINDIR_NATIVE}/" + e + ":"
    return path

PATH_prepend = "${@extra_path_elements(d)}"

addtask fetch
do_fetch[dirs] = "${DL_DIR}"
do_fetch[file-checksums] = "${@bb.fetch.get_checksum_file_list(d)}"
python base_do_fetch() {

    src_uri = (d.getVar('SRC_URI', True) or "").split()
    if len(src_uri) == 0:
        return

    localdata = bb.data.createCopy(d)
    bb.data.update_data(localdata)

    try:
        fetcher = bb.fetch2.Fetch(src_uri, localdata)
        fetcher.download()
    except bb.fetch2.BBFetchException, e:
        raise bb.build.FuncFailed(e)
}

addtask unpack after do_fetch
do_unpack[dirs] = "${WORKDIR}"
do_unpack[cleandirs] = "${S}/patches"
python base_do_unpack() {
    src_uri = (d.getVar('SRC_URI', True) or "").split()
    if len(src_uri) == 0:
        return

    localdata = bb.data.createCopy(d)
    bb.data.update_data(localdata)

    rootdir = localdata.getVar('WORKDIR', True)

    try:
        fetcher = bb.fetch2.Fetch(src_uri, localdata)
        fetcher.unpack(rootdir)
    except bb.fetch2.BBFetchException, e:
        raise bb.build.FuncFailed(e)
}

def pkgarch_mapping(d):
    # Compatibility mappings of TUNE_PKGARCH (opt in)
    if d.getVar("PKGARCHCOMPAT_ARMV7A", True):
        if d.getVar("TUNE_PKGARCH", True) == "armv7a-vfp-neon":
            d.setVar("TUNE_PKGARCH", "armv7a")

def preferred_ml_updates(d):
    # If any PREFERRED_PROVIDER or PREFERRED_VERSION are set,
    # we need to mirror these variables in the multilib case;
    # likewise the PNBLACKLIST flags.
    multilibs = d.getVar('MULTILIBS', True) or ""
    if not multilibs:
        return

    prefixes = []
    for ext in multilibs.split():
        eext = ext.split(':')
        if len(eext) > 1 and eext[0] == 'multilib':
            prefixes.append(eext[1])

    versions = []
    providers = []
    blacklists = d.getVarFlags('PNBLACKLIST') or {}
    for v in d.keys():
        if v.startswith("PREFERRED_VERSION_"):
            versions.append(v)
        if v.startswith("PREFERRED_PROVIDER_"):
            providers.append(v)

    for pkg, reason in blacklists.items():
        if pkg.endswith(("-native", "-crosssdk")) or pkg.startswith(("nativesdk-", "virtual/nativesdk-")) or 'cross-canadian' in pkg:
            continue
        for p in prefixes:
            newpkg = p + "-" + pkg
            if not d.getVarFlag('PNBLACKLIST', newpkg, True):
                d.setVarFlag('PNBLACKLIST', newpkg, reason)

    for v in versions:
        val = d.getVar(v, False)
        pkg = v.replace("PREFERRED_VERSION_", "")
        if pkg.endswith(("-native", "-crosssdk")) or pkg.startswith(("nativesdk-", "virtual/nativesdk-")):
            continue
        if 'cross-canadian' in pkg:
            for p in prefixes:
                localdata = bb.data.createCopy(d)
                override = ":virtclass-multilib-" + p
                localdata.setVar("OVERRIDES", localdata.getVar("OVERRIDES", False) + override)
                bb.data.update_data(localdata)
                newname = localdata.expand(v)
                if newname != v:
                    newval = localdata.expand(val)
                    d.setVar(newname, newval)
            # Avoid future variable key expansion
            vexp = d.expand(v)
            if v != vexp and d.getVar(v, False):
                d.renameVar(v, vexp)
            continue
        for p in prefixes:
            newname = "PREFERRED_VERSION_" + p + "-" + pkg
            if not d.getVar(newname, False):
                d.setVar(newname, val)

    for prov in providers:
        val = d.getVar(prov, False)
        pkg = prov.replace("PREFERRED_PROVIDER_", "")
        if pkg.endswith(("-native", "-crosssdk")) or pkg.startswith(("nativesdk-", "virtual/nativesdk-")):
            continue
        if 'cross-canadian' in pkg:
            for p in prefixes:
                localdata = bb.data.createCopy(d)
                override = ":virtclass-multilib-" + p
                localdata.setVar("OVERRIDES", localdata.getVar("OVERRIDES", False) + override)
                bb.data.update_data(localdata)
                newname = localdata.expand(prov)
                if newname != prov:
                    newval = localdata.expand(val)
                    d.setVar(newname, newval)
            # Avoid future variable key expansion
            provexp = d.expand(prov)
            if prov != provexp and d.getVar(prov, False):
                d.renameVar(prov, provexp)
            continue
        virt = ""
        if pkg.startswith("virtual/"):
            pkg = pkg.replace("virtual/", "")
            virt = "virtual/"
        for p in prefixes:
            if pkg != "kernel":
                val = p + "-" + val

            # implement variable keys
            localdata = bb.data.createCopy(d)
            override = ":virtclass-multilib-" + p
            localdata.setVar("OVERRIDES", localdata.getVar("OVERRIDES", False) + override)
            bb.data.update_data(localdata)
            newname = localdata.expand(prov)
            if newname != prov and not d.getVar(newname, False):
                d.setVar(newname, localdata.expand(val))

            # implement alternative multilib name
            newname = localdata.expand("PREFERRED_PROVIDER_" + virt + p + "-" + pkg)
            if not d.getVar(newname, False):
                d.setVar(newname, val)
        # Avoid future variable key expansion
        provexp = d.expand(prov)
        if prov != provexp and d.getVar(prov, False):
            d.renameVar(prov, provexp)


    mp = (d.getVar("MULTI_PROVIDER_WHITELIST", True) or "").split()
    extramp = []
    for p in mp:
        if p.endswith(("-native", "-crosssdk")) or p.startswith(("nativesdk-", "virtual/nativesdk-")) or 'cross-canadian' in p:
            continue
        virt = ""
        if p.startswith("virtual/"):
            p = p.replace("virtual/", "")
            virt = "virtual/"
        for pref in prefixes:
            extramp.append(virt + pref + "-" + p)
    d.setVar("MULTI_PROVIDER_WHITELIST", " ".join(mp + extramp))


def get_layers_branch_rev(d):
    layers = (d.getVar("BBLAYERS", True) or "").split()
    layers_branch_rev = ["%-17s = \"%s:%s\"" % (os.path.basename(i), \
        base_get_metadata_git_branch(i, None).strip(), \
        base_get_metadata_git_revision(i, None)) \
            for i in layers]
    i = len(layers_branch_rev)-1
    p1 = layers_branch_rev[i].find("=")
    s1 = layers_branch_rev[i][p1:]
    while i > 0:
        p2 = layers_branch_rev[i-1].find("=")
        s2= layers_branch_rev[i-1][p2:]
        if s1 == s2:
            layers_branch_rev[i-1] = layers_branch_rev[i-1][0:p2]
            i -= 1
        else:
            i -= 1
            p1 = layers_branch_rev[i].find("=")
            s1= layers_branch_rev[i][p1:]
    return layers_branch_rev


BUILDCFG_FUNCS ??= "buildcfg_vars get_layers_branch_rev buildcfg_neededvars"
BUILDCFG_FUNCS[type] = "list"

def buildcfg_vars(d):
    statusvars = oe.data.typed_value('BUILDCFG_VARS', d)
    for var in statusvars:
        value = d.getVar(var, True)
        if value is not None:
            yield '%-17s = "%s"' % (var, value)

def buildcfg_neededvars(d):
    needed_vars = oe.data.typed_value("BUILDCFG_NEEDEDVARS", d)
    pesteruser = []
    for v in needed_vars:
        val = d.getVar(v, True)
        if not val or val == 'INVALID':
            pesteruser.append(v)

    if pesteruser:
        bb.fatal('The following variable(s) were not set: %s\nPlease set them directly, or choose a MACHINE or DISTRO that sets them.' % ', '.join(pesteruser))

addhandler base_eventhandler
python base_eventhandler() {
    if isinstance(e, bb.event.ConfigParsed):
        e.data.setVar('BB_VERSION', bb.__version__)
        pkgarch_mapping(e.data)
        preferred_ml_updates(e.data)
        oe.utils.features_backfill("DISTRO_FEATURES", e.data)
        oe.utils.features_backfill("MACHINE_FEATURES", e.data)

    if isinstance(e, bb.event.BuildStarted):
        statuslines = []
        for func in oe.data.typed_value('BUILDCFG_FUNCS', e.data):
            g = globals()
            if func not in g:
                bb.warn("Build configuration function '%s' does not exist" % func)
            else:
                flines = g[func](e.data)
                if flines:
                    statuslines.extend(flines)

        statusheader = e.data.getVar('BUILDCFG_HEADER', True)
        bb.plain('\n%s\n%s\n' % (statusheader, '\n'.join(statuslines)))
}

addtask configure after do_patch
do_configure[dirs] = "${S} ${B}"
do_configure[deptask] = "do_populate_sysroot"
base_do_configure() {
	:
}

addtask compile after do_configure
do_compile[dirs] = "${S} ${B}"
base_do_compile() {
	if [ -e Makefile -o -e makefile -o -e GNUmakefile ]; then
		oe_runmake || die "make failed"
	else
		bbnote "nothing to compile"
	fi
}

addtask install after do_compile
do_install[dirs] = "${D} ${S} ${B}"
# Remove and re-create ${D} so that is it guaranteed to be empty
do_install[cleandirs] = "${D}"

base_do_install() {
	:
}

base_do_package() {
	:
}

addtask build after do_populate_sysroot
do_build = ""
do_build[func] = "1"
do_build[noexec] = "1"
do_build[recrdeptask] += "do_deploy"
do_build () {
	:
}

def set_packagetriplet(d):
    archs = []
    tos = []
    tvs = []

    archs.append(d.getVar("PACKAGE_ARCHS", True).split())
    tos.append(d.getVar("TARGET_OS", True))
    tvs.append(d.getVar("TARGET_VENDOR", True))

    def settriplet(d, varname, archs, tos, tvs):
        triplets = []
        for i in range(len(archs)):
            for arch in archs[i]:
                triplets.append(arch + tvs[i] + "-" + tos[i])
        triplets.reverse()
        d.setVar(varname, " ".join(triplets))

    settriplet(d, "PKGTRIPLETS", archs, tos, tvs)

    variants = d.getVar("MULTILIB_VARIANTS", True) or ""
    for item in variants.split():
        localdata = bb.data.createCopy(d)
        overrides = localdata.getVar("OVERRIDES", False) + ":virtclass-multilib-" + item
        localdata.setVar("OVERRIDES", overrides)
        bb.data.update_data(localdata)

        archs.append(localdata.getVar("PACKAGE_ARCHS", True).split())
        tos.append(localdata.getVar("TARGET_OS", True))
        tvs.append(localdata.getVar("TARGET_VENDOR", True))

    settriplet(d, "PKGMLTRIPLETS", archs, tos, tvs)

python () {
    import exceptions, string, re

    # Handle PACKAGECONFIG
    #
    # These take the form:
    #
    # PACKAGECONFIG ?? = "<default options>"
    # PACKAGECONFIG[foo] = "--enable-foo,--disable-foo,foo_depends,foo_runtime_depends"
    pkgconfigflags = d.getVarFlags("PACKAGECONFIG") or {}
    if pkgconfigflags:
        pkgconfig = (d.getVar('PACKAGECONFIG', True) or "").split()
        pn = d.getVar("PN", True)
        mlprefix = d.getVar("MLPREFIX", True)

        def expandFilter(appends, extension, prefix):
            appends = bb.utils.explode_deps(d.expand(" ".join(appends)))
            newappends = []
            for a in appends:
                if a.endswith("-native") or a.endswith("-cross"):
                    newappends.append(a)
                elif a.startswith("virtual/"):
                    subs = a.split("/", 1)[1]
                    newappends.append("virtual/" + prefix + subs + extension)
                else:
                    if a.startswith(prefix):
                        newappends.append(a + extension)
                    else:
                        newappends.append(prefix + a + extension)
            return newappends

        def appendVar(varname, appends):
            if not appends:
                return
            if varname.find("DEPENDS") != -1:
                if pn.startswith("nativesdk-"):
                    appends = expandFilter(appends, "", "nativesdk-")
                if pn.endswith("-native"):
                    appends = expandFilter(appends, "-native", "")
                if mlprefix:
                    appends = expandFilter(appends, "", mlprefix)
            varname = d.expand(varname)
            d.appendVar(varname, " " + " ".join(appends))

        extradeps = []
        extrardeps = []
        extraconf = []
        for flag, flagval in pkgconfigflags.items():
            if flag == "defaultval":
                continue
            items = flagval.split(",")
            num = len(items)
            if num > 4:
                bb.error("Only enable,disable,depend,rdepend can be specified!")

            if flag in pkgconfig:
                if num >= 3 and items[2]:
                    extradeps.append(items[2])
                if num >= 4 and items[3]:
                    extrardeps.append(items[3])
                if num >= 1 and items[0]:
                    extraconf.append(items[0])
            elif num >= 2 and items[1]:
                    extraconf.append(items[1])
        appendVar('DEPENDS', extradeps)
        appendVar('RDEPENDS_${PN}', extrardeps)
        if bb.data.inherits_class('cmake', d):
            appendVar('EXTRA_OECMAKE', extraconf)
        else:
            appendVar('EXTRA_OECONF', extraconf)

    # If PRINC is set, try and increase the PR value by the amount specified
    princ = d.getVar('PRINC', True)
    if princ and princ != "0":
        pr = d.getVar('PR', True)
        pr_prefix = re.search("\D+",pr)
        prval = re.search("\d+",pr)
        if pr_prefix is None or prval is None:
            bb.error("Unable to analyse format of PR variable: %s" % pr)
        nval = int(prval.group(0)) + int(princ)
        pr = pr_prefix.group(0) + str(nval) + pr[prval.end():]
        d.setVar('PR', pr)

    pn = d.getVar('PN', True)
    license = d.getVar('LICENSE', True)
    if license == "INVALID":
        bb.fatal('This recipe does not have the LICENSE field set (%s)' % pn)

    if bb.data.inherits_class('license', d):
        unmatched_license_flag = check_license_flags(d)
        if unmatched_license_flag:
            bb.debug(1, "Skipping %s because it has a restricted license not"
                 " whitelisted in LICENSE_FLAGS_WHITELIST" % pn)
            raise bb.parse.SkipPackage("because it has a restricted license not"
                 " whitelisted in LICENSE_FLAGS_WHITELIST")

    # If we're building a target package we need to use fakeroot (pseudo)
    # in order to capture permissions, owners, groups and special files
    if not bb.data.inherits_class('native', d) and not bb.data.inherits_class('cross', d):
        d.setVarFlag('do_configure', 'umask', 022)
        d.setVarFlag('do_compile', 'umask', 022)
        d.appendVarFlag('do_install', 'depends', ' virtual/fakeroot-native:do_populate_sysroot')
        d.setVarFlag('do_install', 'fakeroot', 1)
        d.setVarFlag('do_install', 'umask', 022)
        d.appendVarFlag('do_package', 'depends', ' virtual/fakeroot-native:do_populate_sysroot')
        d.setVarFlag('do_package', 'fakeroot', 1)
        d.setVarFlag('do_package', 'umask', 022)
        d.setVarFlag('do_package_setscene', 'fakeroot', 1)
        d.setVarFlag('do_devshell', 'fakeroot', 1)
        d.appendVarFlag('do_devshell', 'depends', ' virtual/fakeroot-native:do_populate_sysroot')
    source_mirror_fetch = d.getVar('SOURCE_MIRROR_FETCH', 0)
    if not source_mirror_fetch:
        need_host = d.getVar('COMPATIBLE_HOST', True)
        if need_host:
            import re
            this_host = d.getVar('HOST_SYS', True)
            if not re.match(need_host, this_host):
                raise bb.parse.SkipPackage("incompatible with host %s (not in COMPATIBLE_HOST)" % this_host)

        need_machine = d.getVar('COMPATIBLE_MACHINE', True)
        if need_machine:
            import re
            this_machine = d.getVar('MACHINE', True)
            if this_machine and not re.match(need_machine, this_machine):
                this_soc_family = d.getVar('SOC_FAMILY', True)
                if (this_soc_family and not re.match(need_machine, this_soc_family)) or not this_soc_family:
                    raise bb.parse.SkipPackage("incompatible with machine %s (not in COMPATIBLE_MACHINE)" % this_machine)


        bad_licenses = (d.getVar('INCOMPATIBLE_LICENSE', True) or "").split()

        check_license = False if pn.startswith("nativesdk-") else True
        for t in ["-native", "-cross", "-cross-initial", "-cross-intermediate",
              "-crosssdk-intermediate", "-crosssdk", "-crosssdk-initial",
              "-cross-canadian-" + d.getVar('TRANSLATED_TARGET_ARCH', True)]:
            if pn.endswith(t):
                check_license = False

        if check_license and bad_licenses:
            whitelist = []
            for lic in bad_licenses:
                for w in ["HOSTTOOLS_WHITELIST_", "LGPLv2_WHITELIST_", "WHITELIST_"]:
                    whitelist.extend((d.getVar(w + lic, True) or "").split())
                spdx_license = return_spdx(d, lic)
                if spdx_license:
                    whitelist.extend((d.getVar('HOSTTOOLS_WHITELIST_%s' % spdx_license, True) or "").split())
            if not pn in whitelist:
                recipe_license = d.getVar('LICENSE', True)
                pkgs = d.getVar('PACKAGES', True).split()
                skipped_pkgs = []
                unskipped_pkgs = []
                for pkg in pkgs:
                    if incompatible_license(d, bad_licenses, pkg):
                        skipped_pkgs.append(pkg)
                    else:
                        unskipped_pkgs.append(pkg)
                all_skipped = skipped_pkgs and not unskipped_pkgs
                if unskipped_pkgs:
                    for pkg in skipped_pkgs:
                        bb.debug(1, "SKIPPING the package " + pkg + " at do_rootfs because it's " + recipe_license)
                        d.setVar('LICENSE_EXCLUSION-' + pkg, 1)
                    for pkg in unskipped_pkgs:
                        bb.debug(1, "INCLUDING the package " + pkg)
                elif all_skipped or incompatible_license(d, bad_licenses):
                    bb.debug(1, "SKIPPING recipe %s because it's %s" % (pn, recipe_license))
                    raise bb.parse.SkipPackage("incompatible with license %s" % recipe_license)

    srcuri = d.getVar('SRC_URI', True)
    # Svn packages should DEPEND on subversion-native
    if "svn://" in srcuri:
        d.appendVarFlag('do_fetch', 'depends', ' subversion-native:do_populate_sysroot')

    # Git packages should DEPEND on git-native
    if "git://" in srcuri:
        d.appendVarFlag('do_fetch', 'depends', ' git-native:do_populate_sysroot')

    # Mercurial packages should DEPEND on mercurial-native
    elif "hg://" in srcuri:
        d.appendVarFlag('do_fetch', 'depends', ' mercurial-native:do_populate_sysroot')

    # OSC packages should DEPEND on osc-native
    elif "osc://" in srcuri:
        d.appendVarFlag('do_fetch', 'depends', ' osc-native:do_populate_sysroot')

    # *.xz should depends on xz-native for unpacking
    # Not endswith because of "*.patch.xz;patch=1". Need bb.decodeurl in future
    if '.xz' in srcuri:
        d.appendVarFlag('do_unpack', 'depends', ' xz-native:do_populate_sysroot')

    # unzip-native should already be staged before unpacking ZIP recipes
    if ".zip" in srcuri:
        d.appendVarFlag('do_unpack', 'depends', ' unzip-native:do_populate_sysroot')

    set_packagetriplet(d)

    # 'multimachine' handling
    mach_arch = d.getVar('MACHINE_ARCH', True)
    pkg_arch = d.getVar('PACKAGE_ARCH', True)

    if (pkg_arch == mach_arch):
        # Already machine specific - nothing further to do
        return

    #
    # We always try to scan SRC_URI for urls with machine overrides
    # unless the package sets SRC_URI_OVERRIDES_PACKAGE_ARCH=0
    #
    override = d.getVar('SRC_URI_OVERRIDES_PACKAGE_ARCH', True)
    if override != '0':
        paths = []
        fpaths = (d.getVar('FILESPATH', True) or '').split(':')
        machine = d.getVar('MACHINE', True)
        for p in fpaths:
            if os.path.basename(p) == machine and os.path.isdir(p):
                paths.append(p)

        if len(paths) != 0:
            for s in srcuri.split():
                if not s.startswith("file://"):
                    continue
                fetcher = bb.fetch2.Fetch([s], d)
                local = fetcher.localpath(s)
                for mp in paths:
                    if local.startswith(mp):
                        #bb.note("overriding PACKAGE_ARCH from %s to %s for %s" % (pkg_arch, mach_arch, pn))
                        d.setVar('PACKAGE_ARCH', "${MACHINE_ARCH}")
                        return

    packages = d.getVar('PACKAGES', True).split()
    for pkg in packages:
        pkgarch = d.getVar("PACKAGE_ARCH_%s" % pkg, True)

        # We could look for != PACKAGE_ARCH here but how to choose
        # if multiple differences are present?
        # Look through PACKAGE_ARCHS for the priority order?
        if pkgarch and pkgarch == mach_arch:
            d.setVar('PACKAGE_ARCH', "${MACHINE_ARCH}")
            bb.warn("Recipe %s is marked as only being architecture specific but seems to have machine specific packages?! The recipe may as well mark itself as machine specific directly." % d.getVar("PN", True))
}

addtask cleansstate after do_clean
python do_cleansstate() {
        sstate_clean_cachefiles(d)
}

addtask cleanall after do_cleansstate
python do_cleanall() {
    src_uri = (d.getVar('SRC_URI', True) or "").split()
    if len(src_uri) == 0:
        return

    localdata = bb.data.createCopy(d)
    bb.data.update_data(localdata)

    try:
        fetcher = bb.fetch2.Fetch(src_uri, localdata)
        fetcher.clean()
    except bb.fetch2.BBFetchException, e:
        raise bb.build.FuncFailed(e)
}
do_cleanall[nostamp] = "1"


EXPORT_FUNCTIONS do_fetch do_unpack do_configure do_compile do_install do_package
