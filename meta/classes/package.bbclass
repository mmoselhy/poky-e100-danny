#
# Packaging process
#
# Executive summary: This class iterates over the functions listed in PACKAGEFUNCS
# Taking D and splitting it up into the packages listed in PACKAGES, placing the
# resulting output in PKGDEST.
#
# There are the following default steps but PACKAGEFUNCS can be extended:
#
# a) package_get_auto_pr - get PRAUTO from remote PR service
#
# b) perform_packagecopy - Copy D into PKGD
#
# c) package_do_split_locales - Split out the locale files, updates FILES and PACKAGES
#
# d) split_and_strip_files - split the files into runtime and debug and strip them.
#    Debug files include debug info split, and associated sources that end up in -dbg packages
#
# e) fixup_perms - Fix up permissions in the package before we split it.
#
# f) populate_packages - Split the files in PKGD into separate packages in PKGDEST/<pkgname>
#    Also triggers the binary stripping code to put files in -dbg packages.
#
# g) package_do_filedeps - Collect perfile run-time dependency metadata
#    The data is stores in FILER{PROVIDES,DEPENDS}_file_pkg variables with
#    a list of affected files in FILER{PROVIDES,DEPENDS}FLIST_pkg
#
# h) package_do_shlibs - Look at the shared libraries generated and autotmatically add any
#    depenedencies found. Also stores the package name so anyone else using this library
#    knows which package to depend on.
#
# i) package_do_pkgconfig - Keep track of which packages need and provide which .pc files
#
# j) read_shlibdeps - Reads the stored shlibs information into the metadata
#
# k) package_depchains - Adds automatic dependencies to -dbg and -dev packages
#
# l) emit_pkgdata - saves the packaging data into PKGDATA_DIR for use in later
#    packaging steps

inherit packagedata
inherit prserv
inherit chrpath

PKGD    = "${WORKDIR}/package"
PKGDEST = "${WORKDIR}/packages-split"

LOCALE_SECTION ?= ''

ALL_MULTILIB_PACKAGE_ARCHS = "${@all_multilib_tune_values(d, 'PACKAGE_ARCHS')}"

# rpm is used for the per-file dependency identification
PACKAGE_DEPENDS += "rpm-native"

def legitimize_package_name(s):
    """
    Make sure package names are legitimate strings
    """
    import re

    def fixutf(m):
        cp = m.group(1)
        if cp:
            return ('\u%s' % cp).decode('unicode_escape').encode('utf-8')

    # Handle unicode codepoints encoded as <U0123>, as in glibc locale files.
    s = re.sub('<U([0-9A-Fa-f]{1,4})>', fixutf, s)

    # Remaining package name validity fixes
    return s.lower().replace('_', '-').replace('@', '+').replace(',', '+').replace('/', '-')

def do_split_packages(d, root, file_regex, output_pattern, description, postinst=None, recursive=False, hook=None, extra_depends=None, aux_files_pattern=None, postrm=None, allow_dirs=False, prepend=False, match_path=False, aux_files_pattern_verbatim=None, allow_links=False):
    """
    Used in .bb files to split up dynamically generated subpackages of a
    given package, usually plugins or modules.

    Arguments:
    root           -- the path in which to search
    file_regex     -- regular expression to match searched files. Use
                      parentheses () to mark the part of this expression
                      that should be used to derive the module name (to be
                      substituted where %s is used in other function
                      arguments as noted below)
    output_pattern -- pattern to use for the package names. Must include %s.
    description    -- description to set for each package. Must include %s.
    postinst       -- postinstall script to use for all packages (as a
                      string)
    recursive      -- True to perform a recursive search - default False
    hook           -- a hook function to be called for every match. The
                      function will be called with the following arguments
                      (in the order listed):
                        f: full path to the file/directory match
                        pkg: the package name
                        file_regex: as above
                        output_pattern: as above
                        modulename: the module name derived using file_regex
    extra_depends  -- extra runtime dependencies (RDEPENDS) to be set for
                      all packages. The default value of None causes a
                      dependency on the main package (${PN}) - if you do
                      not want this, pass '' for this parameter.
    aux_files_pattern -- extra item(s) to be added to FILES for each
                      package. Can be a single string item or a list of
                      strings for multiple items.  Must include %s.
    postrm         -- postrm script to use for all packages (as a string)
    allow_dirs     -- True allow directories to be matched - default False
    prepend        -- if True, prepend created packages to PACKAGES instead
                      of the default False which appends them
    match_path     -- match file_regex on the whole relative path to the
                      root rather than just the file name
    aux_files_pattern_verbatim -- extra item(s) to be added to FILES for
                      each package, using the actual derived module name
                      rather than converting it to something legal for a
                      package name. Can be a single string item or a list
                      of strings for multiple items. Must include %s.
    allow_links    -- True to allow symlinks to be matched - default False

    """

    dvar = d.getVar('PKGD', True)

    # If the root directory doesn't exist, don't error out later but silently do
    # no splitting.
    if not os.path.exists(dvar + root):
        return

    ml = d.getVar("MLPREFIX", True)
    if ml:
        if not output_pattern.startswith(ml):
            output_pattern = ml + output_pattern

        newdeps = []
        for dep in (extra_depends or "").split():
            if dep.startswith(ml):
                newdeps.append(dep)
            else:
                newdeps.append(ml + dep)
        if newdeps:
            extra_depends = " ".join(newdeps)


    packages = d.getVar('PACKAGES', True).split()
    split_packages = []

    if postinst:
        postinst = '#!/bin/sh\n' + postinst + '\n'
    if postrm:
        postrm = '#!/bin/sh\n' + postrm + '\n'
    if not recursive:
        objs = os.listdir(dvar + root)
    else:
        objs = []
        for walkroot, dirs, files in os.walk(dvar + root):
            for file in files:
                relpath = os.path.join(walkroot, file).replace(dvar + root + '/', '', 1)
                if relpath:
                    objs.append(relpath)

    if extra_depends == None:
        extra_depends = d.getVar("PN", True)

    for o in sorted(objs):
        import re, stat
        if match_path:
            m = re.match(file_regex, o)
        else:
            m = re.match(file_regex, os.path.basename(o))

        if not m:
            continue
        f = os.path.join(dvar + root, o)
        mode = os.lstat(f).st_mode
        if not (stat.S_ISREG(mode) or (allow_links and stat.S_ISLNK(mode)) or (allow_dirs and stat.S_ISDIR(mode))):
            continue
        on = legitimize_package_name(m.group(1))
        pkg = output_pattern % on
        split_packages.append(pkg)
        if not pkg in packages:
            if prepend:
                packages = [pkg] + packages
            else:
                packages.append(pkg)
        oldfiles = d.getVar('FILES_' + pkg, True)
        if not oldfiles:
            the_files = [os.path.join(root, o)]
            if aux_files_pattern:
                if type(aux_files_pattern) is list:
                    for fp in aux_files_pattern:
                        the_files.append(fp % on)
                else:
                    the_files.append(aux_files_pattern % on)
            if aux_files_pattern_verbatim:
                if type(aux_files_pattern_verbatim) is list:
                    for fp in aux_files_pattern_verbatim:
                        the_files.append(fp % m.group(1))
                else:
                    the_files.append(aux_files_pattern_verbatim % m.group(1))
            d.setVar('FILES_' + pkg, " ".join(the_files))
            if extra_depends != '':
                d.appendVar('RDEPENDS_' + pkg, ' ' + extra_depends)
            d.setVar('DESCRIPTION_' + pkg, description % on)
            if postinst:
                d.setVar('pkg_postinst_' + pkg, postinst)
            if postrm:
                d.setVar('pkg_postrm_' + pkg, postrm)
        else:
            d.setVar('FILES_' + pkg, oldfiles + " " + os.path.join(root, o))
        if callable(hook):
            hook(f, pkg, file_regex, output_pattern, m.group(1))

    d.setVar('PACKAGES', ' '.join(packages))
    return split_packages

PACKAGE_DEPENDS += "file-native"

python () {
    if d.getVar('PACKAGES', True) != '':
        deps = ""
        for dep in (d.getVar('PACKAGE_DEPENDS', True) or "").split():
            deps += " %s:do_populate_sysroot" % dep
        d.appendVarFlag('do_package', 'depends', deps)

        # shlibs requires any DEPENDS to have already packaged for the *.list files
        d.appendVarFlag('do_package', 'deptask', " do_packagedata")

    elif not bb.data.inherits_class('image', d):
        d.setVar("PACKAGERDEPTASK", "")
}

def splitdebuginfo(file, debugfile, debugsrcdir, d):
    # Function to split a single file into two components, one is the stripped
    # target system binary, the other contains any debugging information. The
    # two files are linked to reference each other.
    #
    # sourcefile is also generated containing a list of debugsources

    import commands, stat, subprocess

    dvar = d.getVar('PKGD', True)
    objcopy = d.getVar("OBJCOPY", True)
    debugedit = d.expand("${STAGING_LIBDIR_NATIVE}/rpm/bin/debugedit")
    workdir = d.getVar("WORKDIR", True)
    workparentdir = d.getVar("DEBUGSRC_OVERRIDE_PATH", True) or os.path.dirname(os.path.dirname(workdir))
    sourcefile = d.expand("${WORKDIR}/debugsources.list")

    bb.utils.remove(sourcefile)

    # We ignore kernel modules, we don't generate debug info files.
    if file.find("/lib/modules/") != -1 and file.endswith(".ko"):
        return 1

    newmode = None
    if not os.access(file, os.W_OK) or os.access(file, os.R_OK):
        origmode = os.stat(file)[stat.ST_MODE]
        newmode = origmode | stat.S_IWRITE | stat.S_IREAD
        os.chmod(file, newmode)

    # We need to extract the debug src information here...
    if debugsrcdir:
        cmd = "'%s' -b '%s' -d '%s' -i -l '%s' '%s'" % (debugedit, workparentdir, debugsrcdir, sourcefile, file)
        retval = subprocess.call(cmd, shell=True)
        if retval:
            bb.fatal("debugedit failed with exit code %s (cmd was %s)" % (retval, cmd))

    bb.utils.mkdirhier(os.path.dirname(debugfile))

    cmd = "'%s' --only-keep-debug '%s' '%s'" % (objcopy, file, debugfile)
    retval = subprocess.call(cmd, shell=True)
    if retval:
        bb.fatal("objcopy failed with exit code %s (cmd was %s)" % (retval, cmd))

    # Set the debuglink to have the view of the file path on the target
    cmd = "'%s' --add-gnu-debuglink='%s' '%s'" % (objcopy, debugfile, file)
    retval = subprocess.call(cmd, shell=True)
    if retval:
        bb.fatal("objcopy failed with exit code %s (cmd was %s)" % (retval, cmd))

    if newmode:
        os.chmod(file, origmode)

    return 0

def copydebugsources(debugsrcdir, d):
    # The debug src information written out to sourcefile is further procecessed
    # and copied to the destination here.

    import commands, stat, subprocess

    sourcefile = d.expand("${WORKDIR}/debugsources.list")
    if debugsrcdir and os.path.isfile(sourcefile):
        dvar = d.getVar('PKGD', True)
        strip = d.getVar("STRIP", True)
        objcopy = d.getVar("OBJCOPY", True)
        debugedit = d.expand("${STAGING_LIBDIR_NATIVE}/rpm/bin/debugedit")
        workdir = d.getVar("WORKDIR", True)
        workparentdir = os.path.dirname(os.path.dirname(workdir))
        workbasedir = os.path.basename(os.path.dirname(workdir)) + "/" + os.path.basename(workdir)

        nosuchdir = []
        basepath = dvar
        for p in debugsrcdir.split("/"):
            basepath = basepath + "/" + p
            if not cpath.exists(basepath):
                nosuchdir.append(basepath)
        bb.utils.mkdirhier(basepath)
        cpath.updatecache(basepath)

        processdebugsrc =  "LC_ALL=C ; sort -z -u '%s' | egrep -v -z '(<internal>|<built-in>)$' | "
        # We need to ignore files that are not actually ours
        # we do this by only paying attention to items from this package
        processdebugsrc += "fgrep -z '%s' | "
        processdebugsrc += "(cd '%s' ; cpio -pd0mlL --no-preserve-owner '%s%s' 2>/dev/null)"

        cmd = processdebugsrc % (sourcefile, workbasedir, workparentdir, dvar, debugsrcdir)
        retval = subprocess.call(cmd, shell=True)
        # Can "fail" if internal headers/transient sources are attempted
        #if retval:
        #    bb.fatal("debug source copy failed with exit code %s (cmd was %s)" % (retval, cmd))


        # The copy by cpio may have resulted in some empty directories!  Remove these
        cmd = "find %s%s -empty -type d -delete" % (dvar, debugsrcdir)
        retval = subprocess.call(cmd, shell=True)
        if retval:
            bb.fatal("empty directory removal failed with exit code %s (cmd was %s)" % (retval, cmd))

        # Also remove debugsrcdir if its empty
        for p in nosuchdir[::-1]:
            if os.path.exists(p) and not os.listdir(p):
                os.rmdir(p)

#
# Package data handling routines
#

def get_package_mapping (pkg, d):
    import oe.packagedata

    data = oe.packagedata.read_subpkgdata(pkg, d)
    key = "PKG_%s" % pkg

    if key in data:
        return data[key]

    return pkg

def runtime_mapping_rename (varname, d):
    #bb.note("%s before: %s" % (varname, d.getVar(varname, True)))

    new_depends = {}
    deps = bb.utils.explode_dep_versions2(d.getVar(varname, True) or "")
    for depend in deps:
        new_depend = get_package_mapping(depend, d)
        new_depends[new_depend] = deps[depend]

    d.setVar(varname, bb.utils.join_deps(new_depends, commasep=False))

    #bb.note("%s after: %s" % (varname, d.getVar(varname, True)))

#
# Package functions suitable for inclusion in PACKAGEFUNCS
#

python package_get_auto_pr() {
    # per recipe PRSERV_HOST
    pn = d.getVar('PN', True)
    host = d.getVar("PRSERV_HOST_" + pn, True)
    if not (host is None):
        d.setVar("PRSERV_HOST", host)

    if d.getVar('PRSERV_HOST', True):
        try:
            auto_pr=prserv_get_pr_auto(d)
        except Exception as e:
            bb.fatal("Can NOT get PRAUTO, exception %s" %  str(e))
            return
        if auto_pr is None:
            if d.getVar('PRSERV_LOCKDOWN', True):
                bb.fatal("Can NOT get PRAUTO from lockdown exported file")
            else:
                bb.fatal("Can NOT get PRAUTO from remote PR service")
            return
        d.setVar('PRAUTO',str(auto_pr))
    else:
        pkgv = d.getVar("PKGV", True)
        if 'AUTOINC' in pkgv:
            d.setVar("PKGV", pkgv.replace("AUTOINC", "0"))
}

LOCALEBASEPN ??= "${PN}"

python package_do_split_locales() {
    if (d.getVar('PACKAGE_NO_LOCALE', True) == '1'):
        bb.debug(1, "package requested not splitting locales")
        return

    packages = (d.getVar('PACKAGES', True) or "").split()

    datadir = d.getVar('datadir', True)
    if not datadir:
        bb.note("datadir not defined")
        return

    dvar = d.getVar('PKGD', True)
    pn = d.getVar('LOCALEBASEPN', True)

    if pn + '-locale' in packages:
        packages.remove(pn + '-locale')

    localedir = os.path.join(dvar + datadir, 'locale')

    if not cpath.isdir(localedir):
        bb.debug(1, "No locale files in this package")
        return

    locales = os.listdir(localedir)

    summary = d.getVar('SUMMARY', True) or pn
    description = d.getVar('DESCRIPTION', True) or ""
    locale_section = d.getVar('LOCALE_SECTION', True)
    mlprefix = d.getVar('MLPREFIX', True) or ""
    for l in sorted(locales):
        ln = legitimize_package_name(l)
        pkg = pn + '-locale-' + ln
        packages.append(pkg)
        d.setVar('FILES_' + pkg, os.path.join(datadir, 'locale', l))
        d.setVar('RRECOMMENDS_' + pkg, '%svirtual-locale-%s' % (mlprefix, ln))
        d.setVar('RPROVIDES_' + pkg, '%s-locale %s%s-translation' % (pn, mlprefix, ln))
        d.setVar('SUMMARY_' + pkg, '%s - %s translations' % (summary, l))
        d.setVar('DESCRIPTION_' + pkg, '%s  This package contains language translation files for the %s locale.' % (description, l))
        if locale_section:
            d.setVar('SECTION_' + pkg, locale_section)

    d.setVar('PACKAGES', ' '.join(packages))

    # Disabled by RP 18/06/07
    # Wildcards aren't supported in debian
    # They break with ipkg since glibc-locale* will mean that
    # glibc-localedata-translit* won't install as a dependency
    # for some other package which breaks meta-toolchain
    # Probably breaks since virtual-locale- isn't provided anywhere
    #rdep = (d.getVar('RDEPENDS_%s' % pn, True) or "").split()
    #rdep.append('%s-locale*' % pn)
    #d.setVar('RDEPENDS_%s' % pn, ' '.join(rdep))
}

python perform_packagecopy () {
    import subprocess
    dest = d.getVar('D', True)
    dvar = d.getVar('PKGD', True)

    # Start by package population by taking a copy of the installed
    # files to operate on
    # Preserve sparse files and hard links
    cmd = 'tar -cf - -C %s -ps . | tar -xf - -C %s' % (dest, dvar)
    retval = subprocess.call(cmd, shell=True)
    if retval:
        bb.fatal("file copy failed with exit code %s (cmd was %s)" % (retval, cmd))

    # replace RPATHs for the nativesdk binaries, to make them relocatable
    if bb.data.inherits_class('nativesdk', d) or bb.data.inherits_class('cross-canadian', d):
        rpath_replace (dvar, d)
}
perform_packagecopy[cleandirs] = "${PKGD}"
perform_packagecopy[dirs] = "${PKGD}"

# We generate a master list of directories to process, we start by
# seeding this list with reasonable defaults, then load from
# the fs-perms.txt files
python fixup_perms () {
    import pwd, grp

    # init using a string with the same format as a line as documented in
    # the fs-perms.txt file
    # <path> <mode> <uid> <gid> <walk> <fmode> <fuid> <fgid>
    # <path> link <link target>
    #
    # __str__ can be used to print out an entry in the input format
    #
    # if fs_perms_entry.path is None:
    #    an error occured
    # if fs_perms_entry.link, you can retrieve:
    #    fs_perms_entry.path = path
    #    fs_perms_entry.link = target of link
    # if not fs_perms_entry.link, you can retrieve:
    #    fs_perms_entry.path = path
    #    fs_perms_entry.mode = expected dir mode or None
    #    fs_perms_entry.uid = expected uid or -1
    #    fs_perms_entry.gid = expected gid or -1
    #    fs_perms_entry.walk = 'true' or something else
    #    fs_perms_entry.fmode = expected file mode or None
    #    fs_perms_entry.fuid = expected file uid or -1
    #    fs_perms_entry_fgid = expected file gid or -1
    class fs_perms_entry():
        def __init__(self, line):
            lsplit = line.split()
            if len(lsplit) == 3 and lsplit[1].lower() == "link":
                self._setlink(lsplit[0], lsplit[2])
            elif len(lsplit) == 8:
                self._setdir(lsplit[0], lsplit[1], lsplit[2], lsplit[3], lsplit[4], lsplit[5], lsplit[6], lsplit[7])
            else:
                bb.error("Fixup Perms: invalid config line %s" % line)
                self.path = None
                self.link = None

        def _setdir(self, path, mode, uid, gid, walk, fmode, fuid, fgid):
            self.path = os.path.normpath(path)
            self.link = None
            self.mode = self._procmode(mode)
            self.uid  = self._procuid(uid)
            self.gid  = self._procgid(gid)
            self.walk = walk.lower()
            self.fmode = self._procmode(fmode)
            self.fuid = self._procuid(fuid)
            self.fgid = self._procgid(fgid)

        def _setlink(self, path, link):
            self.path = os.path.normpath(path)
            self.link = link

        def _procmode(self, mode):
            if not mode or (mode and mode == "-"):
                return None
            else:
                return int(mode,8)

        # Note uid/gid -1 has special significance in os.lchown
        def _procuid(self, uid):
            if uid is None or uid == "-":
                return -1
            elif uid.isdigit():
                return int(uid)
            else:
                return pwd.getpwnam(uid).pw_uid

        def _procgid(self, gid):
            if gid is None or gid == "-":
                return -1
            elif gid.isdigit():
                return int(gid)
            else:
                return grp.getgrnam(gid).gr_gid

        # Use for debugging the entries
        def __str__(self):
            if self.link:
                return "%s link %s" % (self.path, self.link)
            else:
                mode = "-"
                if self.mode:
                    mode = "0%o" % self.mode
                fmode = "-"
                if self.fmode:
                    fmode = "0%o" % self.fmode
                uid = self._mapugid(self.uid)
                gid = self._mapugid(self.gid)
                fuid = self._mapugid(self.fuid)
                fgid = self._mapugid(self.fgid)
                return "%s %s %s %s %s %s %s %s" % (self.path, mode, uid, gid, self.walk, fmode, fuid, fgid)

        def _mapugid(self, id):
            if id is None or id == -1:
                return "-"
            else:
                return "%d" % id

    # Fix the permission, owner and group of path
    def fix_perms(path, mode, uid, gid, dir):
        if mode and not os.path.islink(path):
            #bb.note("Fixup Perms: chmod 0%o %s" % (mode, dir))
            os.chmod(path, mode)
        # -1 is a special value that means don't change the uid/gid
        # if they are BOTH -1, don't bother to lchown
        if not (uid == -1 and gid == -1):
            #bb.note("Fixup Perms: lchown %d:%d %s" % (uid, gid, dir))
            os.lchown(path, uid, gid)

    # Return a list of configuration files based on either the default
    # files/fs-perms.txt or the contents of FILESYSTEM_PERMS_TABLES
    # paths are resolved via BBPATH
    def get_fs_perms_list(d):
        str = ""
        bbpath = d.getVar('BBPATH', True)
        fs_perms_tables = d.getVar('FILESYSTEM_PERMS_TABLES', True)
        if not fs_perms_tables:
            fs_perms_tables = 'files/fs-perms.txt'
        for conf_file in fs_perms_tables.split():
            str += " %s" % bb.utils.which(bbpath, conf_file)
        return str



    dvar = d.getVar('PKGD', True)

    fs_perms_table = {}

    # By default all of the standard directories specified in
    # bitbake.conf will get 0755 root:root.
    target_path_vars = [    'base_prefix',
                'prefix',
                'exec_prefix',
                'base_bindir',
                'base_sbindir',
                'base_libdir',
                'datadir',
                'sysconfdir',
                'servicedir',
                'sharedstatedir',
                'localstatedir',
                'infodir',
                'mandir',
                'docdir',
                'bindir',
                'sbindir',
                'libexecdir',
                'libdir',
                'includedir',
                'oldincludedir' ]

    for path in target_path_vars:
        dir = d.getVar(path, True) or ""
        if dir == "":
            continue
        fs_perms_table[dir] = fs_perms_entry(bb.data.expand("%s 0755 root root false - - -" % (dir), d))

    # Now we actually load from the configuration files
    for conf in get_fs_perms_list(d).split():
        if os.path.exists(conf):
            f = open(conf)
            for line in f:
                if line.startswith('#'):
                    continue
                lsplit = line.split()
                if len(lsplit) == 0:
                    continue
                if len(lsplit) != 8 and not (len(lsplit) == 3 and lsplit[1].lower() == "link"):
                    bb.error("Fixup perms: %s invalid line: %s" % (conf, line))
                    continue
                entry = fs_perms_entry(d.expand(line))
                if entry and entry.path:
                    fs_perms_table[entry.path] = entry
            f.close()

    # Debug -- list out in-memory table
    #for dir in fs_perms_table:
    #    bb.note("Fixup Perms: %s: %s" % (dir, str(fs_perms_table[dir])))

    # We process links first, so we can go back and fixup directory ownership
    # for any newly created directories
    for dir in fs_perms_table:
        if not fs_perms_table[dir].link:
            continue

        origin = dvar + dir
        if not (cpath.exists(origin) and cpath.isdir(origin) and not cpath.islink(origin)):
            continue

        link = fs_perms_table[dir].link
        if link[0] == "/":
            target = dvar + link
            ptarget = link
        else:
            target = os.path.join(os.path.dirname(origin), link)
            ptarget = os.path.join(os.path.dirname(dir), link)
        if os.path.exists(target):
            bb.error("Fixup Perms: Unable to correct directory link, target already exists: %s -> %s" % (dir, ptarget))
            continue

        # Create path to move directory to, move it, and then setup the symlink
        bb.utils.mkdirhier(os.path.dirname(target))
        #bb.note("Fixup Perms: Rename %s -> %s" % (dir, ptarget))
        os.rename(origin, target)
        #bb.note("Fixup Perms: Link %s -> %s" % (dir, link))
        os.symlink(link, origin)

    for dir in fs_perms_table:
        if fs_perms_table[dir].link:
            continue

        origin = dvar + dir
        if not (cpath.exists(origin) and cpath.isdir(origin)):
            continue

        fix_perms(origin, fs_perms_table[dir].mode, fs_perms_table[dir].uid, fs_perms_table[dir].gid, dir)

        if fs_perms_table[dir].walk == 'true':
            for root, dirs, files in os.walk(origin):
                for dr in dirs:
                    each_dir = os.path.join(root, dr)
                    fix_perms(each_dir, fs_perms_table[dir].mode, fs_perms_table[dir].uid, fs_perms_table[dir].gid, dir)
                for f in files:
                    each_file = os.path.join(root, f)
                    fix_perms(each_file, fs_perms_table[dir].fmode, fs_perms_table[dir].fuid, fs_perms_table[dir].fgid, dir)
}

python split_and_strip_files () {
    import commands, stat, errno, subprocess

    dvar = d.getVar('PKGD', True)
    pn = d.getVar('PN', True)

    # We default to '.debug' style
    if d.getVar('PACKAGE_DEBUG_SPLIT_STYLE', True) == 'debug-file-directory':
        # Single debug-file-directory style debug info
        debugappend = ".debug"
        debugdir = ""
        debuglibdir = "/usr/lib/debug"
        debugsrcdir = "/usr/src/debug"
    elif d.getVar('PACKAGE_DEBUG_SPLIT_STYLE', True) == 'debug-without-src':
        # Original OE-core, a.k.a. ".debug", style debug info, but without sources in /usr/src/debug
        debugappend = ""
        debugdir = "/.debug"
        debuglibdir = ""
        debugsrcdir = ""
    else:
        # Original OE-core, a.k.a. ".debug", style debug info
        debugappend = ""
        debugdir = "/.debug"
        debuglibdir = ""
        debugsrcdir = "/usr/src/debug"

    os.chdir(dvar)

    # Return type (bits):
    # 0 - not elf
    # 1 - ELF
    # 2 - stripped
    # 4 - executable
    # 8 - shared library
    # 16 - kernel module
    def isELF(path):
        type = 0
        ret, result = commands.getstatusoutput("file '%s'" % path)

        if ret:
            bb.error("split_and_strip_files: 'file %s' failed" % path)
            return type

        # Not stripped
        if "ELF" in result:
            type |= 1
            if "not stripped" not in result:
                type |= 2
            if "executable" in result:
                type |= 4
            if "shared" in result:
                type |= 8
        return type


    #
    # First lets figure out all of the files we may have to process ... do this only once!
    #
    elffiles = {}
    symlinks = {}
    hardlinks = {}
    kernmods = []
    libdir = os.path.abspath(dvar + os.sep + d.getVar("libdir", True))
    baselibdir = os.path.abspath(dvar + os.sep + d.getVar("base_libdir", True))
    if (d.getVar('INHIBIT_PACKAGE_DEBUG_SPLIT', True) != '1') and \
            (d.getVar('INHIBIT_PACKAGE_STRIP', True) != '1'):
        for root, dirs, files in cpath.walk(dvar):
            for f in files:
                file = os.path.join(root, f)
                if file.endswith(".ko") and file.find("/lib/modules/") != -1:
                    kernmods.append(file)
                    continue

                # Skip debug files
                if debugappend and file.endswith(debugappend):
                    continue
                if debugdir and debugdir in os.path.dirname(file[len(dvar):]):
                    continue

                try:
                    ltarget = cpath.realpath(file, dvar, False)
                    s = cpath.lstat(ltarget)
                except OSError, (err, strerror):
                    if err != errno.ENOENT:
                        raise
                    # Skip broken symlinks
                    continue
                if not s:
                    continue
                # Check its an excutable
                if (s[stat.ST_MODE] & stat.S_IXUSR) or (s[stat.ST_MODE] & stat.S_IXGRP) or (s[stat.ST_MODE] & stat.S_IXOTH) \
                        or ((file.startswith(libdir) or file.startswith(baselibdir)) and ".so" in f):
                    # If it's a symlink, and points to an ELF file, we capture the readlink target
                    if cpath.islink(file):
                        target = os.readlink(file)
                        if isELF(ltarget):
                            #bb.note("Sym: %s (%d)" % (ltarget, isELF(ltarget)))
                            symlinks[file] = target
                        continue
                    # It's a file (or hardlink), not a link
                    # ...but is it ELF, and is it already stripped?
                    elf_file = isELF(file)
                    if elf_file & 1:
                        if elf_file & 2:
                            bb.warn("File '%s' from %s was already stripped, this will prevent future debugging!" % (file[len(dvar):], pn))
                            continue
                        # Check if it's a hard link to something else
                        if s.st_nlink > 1:
                            file_reference = "%d_%d" % (s.st_dev, s.st_ino)
                            # Hard link to something else
                            hardlinks[file] = file_reference
                            continue
                        elffiles[file] = elf_file

    #
    # First lets process debug splitting
    #
    if (d.getVar('INHIBIT_PACKAGE_DEBUG_SPLIT', True) != '1'):
        hardlinkmap = {}
        # For hardlinks, process only one of the files
        for file in hardlinks:
            file_reference = hardlinks[file]
            if file_reference not in hardlinkmap:
                # If this is a new file, add it as a reference, and
                # update it's type, so we can fall through and split
                elffiles[file] = isELF(file)
                hardlinkmap[file_reference] = file

        for file in elffiles:
            src = file[len(dvar):]
            dest = debuglibdir + os.path.dirname(src) + debugdir + "/" + os.path.basename(src) + debugappend
            fpath = dvar + dest

            # Split the file...
            bb.utils.mkdirhier(os.path.dirname(fpath))
            #bb.note("Split %s -> %s" % (file, fpath))
            # Only store off the hard link reference if we successfully split!
            splitdebuginfo(file, fpath, debugsrcdir, d)

        # Hardlink our debug symbols to the other hardlink copies
        for file in hardlinks:
            if file not in elffiles:
                src = file[len(dvar):]
                dest = debuglibdir + os.path.dirname(src) + debugdir + "/" + os.path.basename(src) + debugappend
                fpath = dvar + dest
                file_reference = hardlinks[file]
                target = hardlinkmap[file_reference][len(dvar):]
                ftarget = dvar + debuglibdir + os.path.dirname(target) + debugdir + "/" + os.path.basename(target) + debugappend
                bb.utils.mkdirhier(os.path.dirname(fpath))
                #bb.note("Link %s -> %s" % (fpath, ftarget))
                os.link(ftarget, fpath)

        # Create symlinks for all cases we were able to split symbols
        for file in symlinks:
            src = file[len(dvar):]
            dest = debuglibdir + os.path.dirname(src) + debugdir + "/" + os.path.basename(src) + debugappend
            fpath = dvar + dest
            # Skip it if the target doesn't exist
            try:
                s = os.stat(fpath)
            except OSError, (err, strerror):
                if err != errno.ENOENT:
                    raise
                continue

            ltarget = symlinks[file]
            lpath = os.path.dirname(ltarget)
            lbase = os.path.basename(ltarget)
            ftarget = ""
            if lpath and lpath != ".":
                ftarget += lpath + debugdir + "/"
            ftarget += lbase + debugappend
            if lpath.startswith(".."):
                ftarget = os.path.join("..", ftarget)
            bb.utils.mkdirhier(os.path.dirname(fpath))
            #bb.note("Symlink %s -> %s" % (fpath, ftarget))
            os.symlink(ftarget, fpath)

        # Process the debugsrcdir if requested...
        # This copies and places the referenced sources for later debugging...
        copydebugsources(debugsrcdir, d)
    #
    # End of debug splitting
    #

    #
    # Now lets go back over things and strip them
    #
    if (d.getVar('INHIBIT_PACKAGE_STRIP', True) != '1'):
        strip = d.getVar("STRIP", True)
        sfiles = []
        for file in elffiles:
            elf_file = int(elffiles[file])
            #bb.note("Strip %s" % file)
            sfiles.append((file, elf_file, strip))
        for f in kernmods:
            sfiles.append((f, 16, strip))


        import multiprocessing
        nproc = multiprocessing.cpu_count()
        pool = bb.utils.multiprocessingpool(nproc)
        processed = pool.imap(oe.package.runstrip, sfiles)
        pool.close()
        pool.join()

    #
    # End of strip
    #
}

python populate_packages () {
    import glob, re, subprocess

    workdir = d.getVar('WORKDIR', True)
    outdir = d.getVar('DEPLOY_DIR', True)
    dvar = d.getVar('PKGD', True)
    packages = d.getVar('PACKAGES', True)
    pn = d.getVar('PN', True)

    bb.utils.mkdirhier(outdir)
    os.chdir(dvar)

    # Sanity check PACKAGES for duplicates and for LICENSE_EXCLUSION
    # Sanity should be moved to sanity.bbclass once we have the infrastucture
    package_list = []

    for pkg in packages.split():
        if d.getVar('LICENSE_EXCLUSION-' + pkg, True):
            bb.warn("%s has an incompatible license. Excluding from packaging." % pkg)
        elif pkg in package_list:
            bb.error("%s is listed in PACKAGES multiple times, this leads to packaging errors." % pkg)
        else:
            package_list.append(pkg)
    d.setVar('PACKAGES', ' '.join(package_list))
    pkgdest = d.getVar('PKGDEST', True)

    seen = []

    for pkg in package_list:
        root = os.path.join(pkgdest, pkg)
        bb.utils.mkdirhier(root)

        filesvar = d.getVar('FILES_%s' % pkg, True) or ""
        if "//" in filesvar:
            bb.warn("FILES variable for package %s contains '//' which is invalid. Attempting to fix this but you should correct the metadata.\n" % pkg)
            filesvar.replace("//", "/")
        files = filesvar.split()
        for file in files:
            if os.path.isabs(file):
                file = '.' + file
            if not cpath.islink(file):
                if cpath.isdir(file):
                    newfiles =  [ os.path.join(file,x) for x in os.listdir(file) ]
                    if newfiles:
                        files += newfiles
                        continue
            globbed = glob.glob(file)
            if globbed:
                if [ file ] != globbed:
                    files += globbed
                    continue
            if (not cpath.islink(file)) and (not cpath.exists(file)):
                continue
            if file in seen:
                continue
            seen.append(file)

            def mkdir(src, dest, p):
                src = os.path.join(src, p)
                dest = os.path.join(dest, p)
                fstat = cpath.stat(src)
                os.mkdir(dest, fstat.st_mode)
                os.chown(dest, fstat.st_uid, fstat.st_gid)
                if p not in seen:
                    seen.append(p)
                cpath.updatecache(dest)

            def mkdir_recurse(src, dest, paths):
                if cpath.exists(dest + '/' + paths):
                    return
                while paths.startswith("./"):
                    paths = paths[2:]
                p = "."
                for c in paths.split("/"):
                    p = os.path.join(p, c)
                    if not cpath.exists(os.path.join(dest, p)):
                        mkdir(src, dest, p)

            if cpath.isdir(file) and not cpath.islink(file):
                mkdir_recurse(dvar, root, file)
                continue

            mkdir_recurse(dvar, root, os.path.dirname(file))
            fpath = os.path.join(root,file)
            if not cpath.islink(file):
                os.link(file, fpath)
                fstat = cpath.stat(file)
                os.chmod(fpath, fstat.st_mode)
                os.chown(fpath, fstat.st_uid, fstat.st_gid)
                continue
            ret = bb.utils.copyfile(file, fpath)
            if ret is False or ret == 0:
                raise bb.build.FuncFailed("File population failed")

    os.chdir(workdir)

    unshipped = []
    for root, dirs, files in cpath.walk(dvar):
        dir = root[len(dvar):]
        if not dir:
            dir = os.sep
        for f in (files + dirs):
            path = os.path.join(dir, f)
            if ('.' + path) not in seen:
                unshipped.append(path)

    if unshipped != []:
        msg = pn + ": Files/directories were installed but not shipped"
        if "installed_vs_shipped" in (d.getVar('INSANE_SKIP_' + pn, True) or "").split():
            bb.note("Package %s skipping QA tests: installed_vs_shipped" % pn)
        else:
            for f in unshipped:
                msg = msg + "\n  " + f
            package_qa_handle_error("installed_vs_shipped", msg, d)
}
populate_packages[dirs] = "${D}"

python package_fixsymlinks () {
    import errno
    pkgdest = d.getVar('PKGDEST', True)
    packages = d.getVar("PACKAGES").split()

    dangling_links = {}
    pkg_files = {}
    for pkg in packages:
        dangling_links[pkg] = []
        pkg_files[pkg] = []
        inst_root = os.path.join(pkgdest, pkg)
        for path in pkgfiles[pkg]:
                rpath = path[len(inst_root):]
                pkg_files[pkg].append(rpath)
                rtarget = cpath.realpath(path, inst_root, True, assume_dir = True)
                if not cpath.lexists(rtarget):
                    dangling_links[pkg].append(os.path.normpath(rtarget[len(inst_root):]))

    newrdepends = {}
    for pkg in dangling_links:
        for l in dangling_links[pkg]:
            found = False
            bb.debug(1, "%s contains dangling link %s" % (pkg, l))
            for p in packages:
                if l in pkg_files[p]:
                        found = True
                        bb.debug(1, "target found in %s" % p)
                        if p == pkg:
                            break
                        if pkg not in newrdepends:
                            newrdepends[pkg] = []
                        newrdepends[pkg].append(p)
                        break
            if found == False:
                bb.note("%s contains dangling symlink to %s" % (pkg, l))

    for pkg in newrdepends:
        rdepends = bb.utils.explode_dep_versions2(d.getVar('RDEPENDS_' + pkg, True) or "")
        for p in newrdepends[pkg]:
            if p not in rdepends:
                rdepends[p] = []
        d.setVar('RDEPENDS_' + pkg, bb.utils.join_deps(rdepends, commasep=False))
}

PKGDESTWORK = "${WORKDIR}/pkgdata"

python emit_pkgdata() {
    from glob import glob

    def write_if_exists(f, pkg, var):
        def encode(str):
            import codecs
            c = codecs.getencoder("string_escape")
            return c(str)[0]

        val = d.getVar('%s_%s' % (var, pkg), True)
        if val:
            f.write('%s_%s: %s\n' % (var, pkg, encode(val)))
            return
        val = d.getVar('%s' % (var), True)
        if val:
            f.write('%s: %s\n' % (var, encode(val)))
        return

    def get_directory_size(dir):
        if os.listdir(dir):
            size = int(os.popen('du -sk %s' % dir).readlines()[0].split('\t')[0])
        else:
            size = 0
        return size

    def write_extra_pkgs(variants, pn, packages, pkgdatadir):
        for variant in variants:
            with open("%s/%s-%s" % (pkgdatadir, variant, pn), 'w') as fd:
                fd.write("PACKAGES: %s\n" % ' '.join(
                            map(lambda pkg: '%s-%s' % (variant, pkg), packages.split())))

    def write_extra_runtime_pkgs(variants, packages, pkgdatadir):
        for variant in variants:
            for pkg in packages.split():
                ml_pkg = "%s-%s" % (variant, pkg)
                subdata_file = "%s/runtime/%s" % (pkgdatadir, ml_pkg)
                with open(subdata_file, 'w') as fd:
                    fd.write("PKG_%s: %s" % (ml_pkg, pkg))

    packages = d.getVar('PACKAGES', True)
    pkgdest = d.getVar('PKGDEST', True)
    pkgdatadir = d.getVar('PKGDESTWORK', True)

    # Take shared lock since we're only reading, not writing
    lf = bb.utils.lockfile(d.expand("${PACKAGELOCK}"), True)

    data_file = pkgdatadir + d.expand("/${PN}" )
    f = open(data_file, 'w')
    f.write("PACKAGES: %s\n" % packages)
    f.close()

    pn = d.getVar('PN', True)
    global_variants = (d.getVar('MULTILIB_GLOBAL_VARIANTS', True) or "").split()
    variants = (d.getVar('MULTILIB_VARIANTS', True) or "").split()

    if bb.data.inherits_class('kernel', d) or bb.data.inherits_class('module-base', d):
        write_extra_pkgs(variants, pn, packages, pkgdatadir)

    if (bb.data.inherits_class('allarch', d) and not bb.data.inherits_class('packagegroup', d)):
        write_extra_pkgs(global_variants, pn, packages, pkgdatadir)

    workdir = d.getVar('WORKDIR', True)

    for pkg in packages.split():
        items = {}
        for files_list in pkgfiles[pkg]:
             item_name = os.path.basename(files_list)
             item_path = os.path.dirname(files_list)
             if item_path not in items:
                 items[item_path] = []
             items[item_path].append(item_name)
        subdata_file = pkgdatadir + "/runtime/%s" % pkg

        pkgval = d.getVar('PKG_%s' % pkg, True)
        if pkgval is None:
            pkgval = pkg
            d.setVar('PKG_%s' % pkg, pkg)

        d.setVar('FILES_INFO', str(items))

        sf = open(subdata_file, 'w')
        write_if_exists(sf, pkg, 'PN')
        write_if_exists(sf, pkg, 'PV')
        write_if_exists(sf, pkg, 'PR')
        write_if_exists(sf, pkg, 'PKGV')
        write_if_exists(sf, pkg, 'PKGR')
        write_if_exists(sf, pkg, 'LICENSE')
        write_if_exists(sf, pkg, 'DESCRIPTION')
        write_if_exists(sf, pkg, 'SUMMARY')
        write_if_exists(sf, pkg, 'RDEPENDS')
        write_if_exists(sf, pkg, 'RPROVIDES')
        write_if_exists(sf, pkg, 'RRECOMMENDS')
        write_if_exists(sf, pkg, 'RSUGGESTS')
        write_if_exists(sf, pkg, 'RREPLACES')
        write_if_exists(sf, pkg, 'RCONFLICTS')
        write_if_exists(sf, pkg, 'SECTION')
        write_if_exists(sf, pkg, 'PKG')
        write_if_exists(sf, pkg, 'ALLOW_EMPTY')
        write_if_exists(sf, pkg, 'FILES')
        write_if_exists(sf, pkg, 'pkg_postinst')
        write_if_exists(sf, pkg, 'pkg_postrm')
        write_if_exists(sf, pkg, 'pkg_preinst')
        write_if_exists(sf, pkg, 'pkg_prerm')
        write_if_exists(sf, pkg, 'FILERPROVIDESFLIST')
        write_if_exists(sf, pkg, 'FILES_INFO')
        for dfile in (d.getVar('FILERPROVIDESFLIST_' + pkg, True) or "").split():
            write_if_exists(sf, pkg, 'FILERPROVIDES_' + dfile)

        write_if_exists(sf, pkg, 'FILERDEPENDSFLIST')
        for dfile in (d.getVar('FILERDEPENDSFLIST_' + pkg, True) or "").split():
            write_if_exists(sf, pkg, 'FILERDEPENDS_' + dfile)

        sf.write('%s_%s: %s\n' % ('PKGSIZE', pkg, get_directory_size(pkgdest + "/%s" % pkg)))
        sf.close()

        # Symlinks needed for reverse lookups (from the final package name)
        subdata_sym = pkgdatadir + "/runtime-reverse/%s" % pkgval
        oe.path.symlink("../runtime/%s" % pkg, subdata_sym, True)

        allow_empty = d.getVar('ALLOW_EMPTY_%s' % pkg, True)
        if not allow_empty:
            allow_empty = d.getVar('ALLOW_EMPTY', True)
        root = "%s/%s" % (pkgdest, pkg)
        os.chdir(root)
        g = glob('*')
        if g or allow_empty == "1":
            packagedfile = pkgdatadir + '/runtime/%s.packaged' % pkg
            file(packagedfile, 'w').close()

    if bb.data.inherits_class('kernel', d) or bb.data.inherits_class('module-base', d):
        write_extra_runtime_pkgs(variants, packages, pkgdatadir)

    if bb.data.inherits_class('allarch', d) and not bb.data.inherits_class('packagegroup', d):
        write_extra_runtime_pkgs(global_variants, packages, pkgdatadir)

    bb.utils.unlockfile(lf)
}
emit_pkgdata[dirs] = "${PKGDESTWORK}/runtime ${PKGDESTWORK}/runtime-reverse"

ldconfig_postinst_fragment() {
if [ x"$D" = "x" ]; then
	if [ -x /sbin/ldconfig ]; then /sbin/ldconfig ; fi
fi
}

RPMDEPS = "${STAGING_LIBDIR_NATIVE}/rpm/bin/rpmdeps-oecore --macros ${STAGING_LIBDIR_NATIVE}/rpm/macros --define '_rpmfc_magic_path ${STAGING_DIR_NATIVE}${datadir_native}/misc/magic.mgc' --rpmpopt ${STAGING_LIBDIR_NATIVE}/rpm/rpmpopt"

# Collect perfile run-time dependency metadata
# Output:
#  FILERPROVIDESFLIST_pkg - list of all files w/ deps
#  FILERPROVIDES_filepath_pkg - per file dep
#
#  FILERDEPENDSFLIST_pkg - list of all files w/ deps
#  FILERDEPENDS_filepath_pkg - per file dep

python package_do_filedeps() {
    if d.getVar('SKIP_FILEDEPS', True) == '1':
        return

    pkgdest = d.getVar('PKGDEST', True)
    packages = d.getVar('PACKAGES', True)
    rpmdeps = d.getVar('RPMDEPS', True)

    def chunks(files, n):
        return [files[i:i+n] for i in range(0, len(files), n)]

    pkglist = []
    for pkg in packages.split():
        if d.getVar('SKIP_FILEDEPS_' + pkg, True) == '1':
            continue
        if pkg.endswith('-dbg') or pkg.endswith('-doc') or pkg.find('-locale-') != -1 or pkg.find('-localedata-') != -1 or pkg.find('-gconv-') != -1 or pkg.find('-charmap-') != -1 or pkg.startswith('kernel-module-'):
            continue
        for files in chunks(pkgfiles[pkg], 100):
            pkglist.append((pkg, files, rpmdeps, pkgdest))

    import multiprocessing
    nproc = multiprocessing.cpu_count()
    pool =  bb.utils.multiprocessingpool(nproc)
    processed = pool.imap(oe.package.filedeprunner, pkglist)
    pool.close()
    pool.join()

    provides_files = {}
    requires_files = {}

    for result in processed:
        (pkg, provides, requires) = result

        if pkg not in provides_files:
            provides_files[pkg] = []
        if pkg not in requires_files:
            requires_files[pkg] = []

        for file in provides:
            provides_files[pkg].append(file)
            key = "FILERPROVIDES_" + file + "_" + pkg
            d.setVar(key, " ".join(provides[file]))

        for file in requires:
            requires_files[pkg].append(file)
            key = "FILERDEPENDS_" + file + "_" + pkg
            d.setVar(key, " ".join(requires[file]))

    for pkg in requires_files:
        d.setVar("FILERDEPENDSFLIST_" + pkg, " ".join(requires_files[pkg]))
    for pkg in provides_files:
        d.setVar("FILERPROVIDESFLIST_" + pkg, " ".join(provides_files[pkg]))
}

def getshlibsdirs(d):
    dirs = []
    triplets = (d.getVar("PKGTRIPLETS") or "").split()
    for t in triplets:
        dirs.append("${TMPDIR}/pkgdata/" + t + "/shlibs/")
    return " ".join(dirs)
getshlibsdirs[vardepsexclude] = "PKGTRIPLETS"

SHLIBSDIRS = "${@getshlibsdirs(d)}"
SHLIBSDIR = "${TMPDIR}/pkgdata/${PACKAGE_ARCH}${TARGET_VENDOR}-${TARGET_OS}/shlibs"
SHLIBSWORKDIR = "${PKGDESTWORK}/shlibs"

python package_do_shlibs() {
    import re, pipes

    exclude_shlibs = d.getVar('EXCLUDE_FROM_SHLIBS', 0)
    if exclude_shlibs:
        bb.note("not generating shlibs")
        return

    lib_re = re.compile("^.*\.so")
    libdir_re = re.compile(".*/%s$" % d.getVar('baselib', True))

    packages = d.getVar('PACKAGES', True)
    targetos = d.getVar('TARGET_OS', True)

    workdir = d.getVar('WORKDIR', True)

    ver = d.getVar('PKGV', True)
    if not ver:
        bb.error("PKGV not defined")
        return

    pkgdest = d.getVar('PKGDEST', True)

    shlibs_dirs = d.getVar('SHLIBSDIRS', True).split()
    shlibswork_dir = d.getVar('SHLIBSWORKDIR', True)

    # Take shared lock since we're only reading, not writing
    lf = bb.utils.lockfile(d.expand("${PACKAGELOCK}"))

    def linux_so(file):
        needs_ldconfig = False
        cmd = d.getVar('OBJDUMP', True) + " -p " + pipes.quote(file) + " 2>/dev/null"
        fd = os.popen(cmd)
        lines = fd.readlines()
        fd.close()
        for l in lines:
            m = re.match("\s+NEEDED\s+([^\s]*)", l)
            if m:
                if m.group(1) not in needed[pkg]:
                    needed[pkg].append(m.group(1))
            m = re.match("\s+SONAME\s+([^\s]*)", l)
            if m:
                this_soname = m.group(1)
                if not this_soname in sonames:
                    # if library is private (only used by package) then do not build shlib for it
                    if not private_libs or -1 == private_libs.find(this_soname):
                        sonames.append(this_soname)
                if libdir_re.match(os.path.dirname(file)):
                    needs_ldconfig = True
                if snap_symlinks and (os.path.basename(file) != this_soname):
                    renames.append((file, os.path.join(os.path.dirname(file), this_soname)))
        return needs_ldconfig

    def darwin_so(file):
        if not os.path.exists(file):
            return

        def get_combinations(base):
            #
            # Given a base library name, find all combinations of this split by "." and "-"
            #
            combos = []
            options = base.split(".")
            for i in range(1, len(options) + 1):
                combos.append(".".join(options[0:i]))
            options = base.split("-")
            for i in range(1, len(options) + 1):
                combos.append("-".join(options[0:i]))
            return combos

        if (file.endswith('.dylib') or file.endswith('.so')) and not pkg.endswith('-dev') and not pkg.endswith('-dbg'):
            # Drop suffix
            name = file.rsplit(".",1)[0]
            # Find all combinations
            combos = get_combinations(name)
            for combo in combos:
                if not combo in sonames:
                    sonames.append(combo)
        if file.endswith('.dylib') or file.endswith('.so'):
            lafile = file.replace(os.path.join(pkgdest, pkg), d.getVar('PKGD', True))
            # Drop suffix
            lafile = lafile.rsplit(".",1)[0]
            lapath = os.path.dirname(lafile)
            lafile = os.path.basename(lafile)
            # Find all combinations
            combos = get_combinations(lafile)
            for combo in combos:
                if os.path.exists(lapath + '/' + combo + '.la'):
                    break
            lafile = lapath + '/' + combo + '.la'

            #bb.note("Foo2: %s" % lafile)
            #bb.note("Foo %s" % file)
            if os.path.exists(lafile):
                fd = open(lafile, 'r')
                lines = fd.readlines()
                fd.close()
                for l in lines:
                    m = re.match("\s*dependency_libs=\s*'(.*)'", l)
                    if m:
                        deps = m.group(1).split(" ")
                        for dep in deps:
                            #bb.note("Trying %s for %s" % (dep, pkg))
                            name = None
                            if dep.endswith(".la"):
                                name = os.path.basename(dep).replace(".la", "")
                            elif dep.startswith("-l"):
                                name = dep.replace("-l", "lib")
                            if pkg not in needed:
                                needed[pkg] = []
                            if name and name not in needed[pkg]:
                                needed[pkg].append(name)
                                #bb.note("Adding %s for %s" % (name, pkg))

    if d.getVar('PACKAGE_SNAP_LIB_SYMLINKS', True) == "1":
        snap_symlinks = True
    else:
        snap_symlinks = False

    if (d.getVar('USE_LDCONFIG', True) or "1") == "1":
        use_ldconfig = True
    else:
        use_ldconfig = False

    needed = {}
    shlib_provider = {}
    for pkg in packages.split():
        private_libs = d.getVar('PRIVATE_LIBS_' + pkg, True) or d.getVar('PRIVATE_LIBS', True)
        needs_ldconfig = False
        bb.debug(2, "calculating shlib provides for %s" % pkg)

        pkgver = d.getVar('PKGV_' + pkg, True)
        if not pkgver:
            pkgver = d.getVar('PV_' + pkg, True)
        if not pkgver:
            pkgver = ver

        needed[pkg] = []
        sonames = list()
        renames = list()
        for file in pkgfiles[pkg]:
                soname = None
                if cpath.islink(file):
                    continue
                if targetos == "darwin" or targetos == "darwin8":
                    darwin_so(file)
                elif os.access(file, os.X_OK) or lib_re.match(file):
                    ldconfig = linux_so(file)
                    needs_ldconfig = needs_ldconfig or ldconfig
        for (old, new) in renames:
            bb.note("Renaming %s to %s" % (old, new))
            os.rename(old, new)
        shlibs_file = os.path.join(shlibswork_dir, pkg + ".list")
        shver_file = os.path.join(shlibswork_dir, pkg + ".ver")
        if len(sonames):
            fd = open(shlibs_file, 'w')
            for s in sonames:
                fd.write(s + '\n')
                shlib_provider[s] = (pkg, pkgver)
            fd.close()
            fd = open(shver_file, 'w')
            fd.write(pkgver + '\n')
            fd.close()
        if needs_ldconfig and use_ldconfig:
            bb.debug(1, 'adding ldconfig call to postinst for %s' % pkg)
            postinst = d.getVar('pkg_postinst_%s' % pkg, True)
            if not postinst:
                postinst = '#!/bin/sh\n'
            postinst += d.getVar('ldconfig_postinst_fragment', True)
            d.setVar('pkg_postinst_%s' % pkg, postinst)

    list_re = re.compile('^(.*)\.list$')
    # Go from least to most specific since the last one found wins
    for dir in reversed(shlibs_dirs):
        if not os.path.exists(dir):
            continue
        for file in os.listdir(dir):
            m = list_re.match(file)
            if m:
                dep_pkg = m.group(1)
                fd = open(os.path.join(dir, file))
                lines = fd.readlines()
                fd.close()
                ver_file = os.path.join(dir, dep_pkg + '.ver')
                lib_ver = None
                if os.path.exists(ver_file):
                    fd = open(ver_file)
                    lib_ver = fd.readline().rstrip()
                    fd.close()
                for l in lines:
                    shlib_provider[l.rstrip()] = (dep_pkg, lib_ver)

    bb.utils.unlockfile(lf)

    assumed_libs = d.getVar('ASSUME_SHLIBS', True)
    if assumed_libs:
        for e in assumed_libs.split():
            l, dep_pkg = e.split(":")
            lib_ver = None
            dep_pkg = dep_pkg.rsplit("_", 1)
            if len(dep_pkg) == 2:
                lib_ver = dep_pkg[1]
            dep_pkg = dep_pkg[0]
            shlib_provider[l] = (dep_pkg, lib_ver)

    for pkg in packages.split():
        bb.debug(2, "calculating shlib requirements for %s" % pkg)

        deps = list()
        for n in needed[pkg]:
            if n in shlib_provider.keys():
                (dep_pkg, ver_needed) = shlib_provider[n]

                bb.debug(2, '%s: Dependency %s requires package %s' % (pkg, n, dep_pkg))

                if dep_pkg == pkg:
                    continue

                if ver_needed:
                    dep = "%s (>= %s)" % (dep_pkg, ver_needed)
                else:
                    dep = dep_pkg
                if not dep in deps:
                    deps.append(dep)
            else:
                bb.note("Couldn't find shared library provider for %s" % n)

        deps_file = os.path.join(pkgdest, pkg + ".shlibdeps")
        if os.path.exists(deps_file):
            os.remove(deps_file)
        if len(deps):
            fd = open(deps_file, 'w')
            for dep in deps:
                fd.write(dep + '\n')
            fd.close()
}

python package_do_pkgconfig () {
    import re

    packages = d.getVar('PACKAGES', True)
    workdir = d.getVar('WORKDIR', True)
    pkgdest = d.getVar('PKGDEST', True)

    shlibs_dirs = d.getVar('SHLIBSDIRS', True).split()
    shlibswork_dir = d.getVar('SHLIBSWORKDIR', True)

    pc_re = re.compile('(.*)\.pc$')
    var_re = re.compile('(.*)=(.*)')
    field_re = re.compile('(.*): (.*)')

    pkgconfig_provided = {}
    pkgconfig_needed = {}
    for pkg in packages.split():
        pkgconfig_provided[pkg] = []
        pkgconfig_needed[pkg] = []
        for file in pkgfiles[pkg]:
                m = pc_re.match(file)
                if m:
                    pd = bb.data.init()
                    name = m.group(1)
                    pkgconfig_provided[pkg].append(name)
                    if not os.access(file, os.R_OK):
                        continue
                    f = open(file, 'r')
                    lines = f.readlines()
                    f.close()
                    for l in lines:
                        m = var_re.match(l)
                        if m:
                            name = m.group(1)
                            val = m.group(2)
                            pd.setVar(name, pd.expand(val))
                            continue
                        m = field_re.match(l)
                        if m:
                            hdr = m.group(1)
                            exp = bb.data.expand(m.group(2), pd)
                            if hdr == 'Requires':
                                pkgconfig_needed[pkg] += exp.replace(',', ' ').split()

    # Take shared lock since we're only reading, not writing
    lf = bb.utils.lockfile(d.expand("${PACKAGELOCK}"))

    for pkg in packages.split():
        pkgs_file = os.path.join(shlibswork_dir, pkg + ".pclist")
        if pkgconfig_provided[pkg] != []:
            f = open(pkgs_file, 'w')
            for p in pkgconfig_provided[pkg]:
                f.write('%s\n' % p)
            f.close()

    # Go from least to most specific since the last one found wins
    for dir in reversed(shlibs_dirs):
        if not os.path.exists(dir):
            continue
        for file in os.listdir(dir):
            m = re.match('^(.*)\.pclist$', file)
            if m:
                pkg = m.group(1)
                fd = open(os.path.join(dir, file))
                lines = fd.readlines()
                fd.close()
                pkgconfig_provided[pkg] = []
                for l in lines:
                    pkgconfig_provided[pkg].append(l.rstrip())

    for pkg in packages.split():
        deps = []
        for n in pkgconfig_needed[pkg]:
            found = False
            for k in pkgconfig_provided.keys():
                if n in pkgconfig_provided[k]:
                    if k != pkg and not (k in deps):
                        deps.append(k)
                    found = True
            if found == False:
                bb.note("couldn't find pkgconfig module '%s' in any package" % n)
        deps_file = os.path.join(pkgdest, pkg + ".pcdeps")
        if len(deps):
            fd = open(deps_file, 'w')
            for dep in deps:
                fd.write(dep + '\n')
            fd.close()

    bb.utils.unlockfile(lf)
}

def read_libdep_files(d):
    pkglibdeps = {}
    packages = d.getVar('PACKAGES', True).split()
    for pkg in packages:
        pkglibdeps[pkg] = {}
        for extension in ".shlibdeps", ".pcdeps", ".clilibdeps":
            depsfile = d.expand("${PKGDEST}/" + pkg + extension)
            if os.access(depsfile, os.R_OK):
                fd = file(depsfile)
                lines = fd.readlines()
                fd.close()
                for l in lines:
                    l.rstrip()
                    deps = bb.utils.explode_dep_versions2(l)
                    for dep in deps:
                        if not dep in pkglibdeps[pkg]:
                            pkglibdeps[pkg][dep] = deps[dep]
    return pkglibdeps

python read_shlibdeps () {
    pkglibdeps = read_libdep_files(d)

    packages = d.getVar('PACKAGES', True).split()
    for pkg in packages:
        rdepends = bb.utils.explode_dep_versions2(d.getVar('RDEPENDS_' + pkg, True) or "")
        for dep in pkglibdeps[pkg]:
            # Add the dep if it's not already there, or if no comparison is set
            if dep not in rdepends:
                rdepends[dep] = []
            for v in pkglibdeps[pkg][dep]:
                if v not in rdepends[dep]:
                    rdepends[dep].append(v)
        d.setVar('RDEPENDS_' + pkg, bb.utils.join_deps(rdepends, commasep=False))
}

python package_depchains() {
    """
    For a given set of prefix and postfix modifiers, make those packages
    RRECOMMENDS on the corresponding packages for its RDEPENDS.

    Example:  If package A depends upon package B, and A's .bb emits an
    A-dev package, this would make A-dev Recommends: B-dev.

    If only one of a given suffix is specified, it will take the RRECOMMENDS
    based on the RDEPENDS of *all* other packages. If more than one of a given
    suffix is specified, its will only use the RDEPENDS of the single parent
    package.
    """

    packages  = d.getVar('PACKAGES', True)
    postfixes = (d.getVar('DEPCHAIN_POST', True) or '').split()
    prefixes  = (d.getVar('DEPCHAIN_PRE', True) or '').split()

    def pkg_adddeprrecs(pkg, base, suffix, getname, depends, d):

        #bb.note('depends for %s is %s' % (base, depends))
        rreclist = bb.utils.explode_dep_versions2(d.getVar('RRECOMMENDS_' + pkg, True) or "")

        for depend in depends:
            if depend.find('-native') != -1 or depend.find('-cross') != -1 or depend.startswith('virtual/'):
                #bb.note("Skipping %s" % depend)
                continue
            if depend.endswith('-dev'):
                depend = depend[:-4]
            if depend.endswith('-dbg'):
                depend = depend[:-4]
            pkgname = getname(depend, suffix)
            #bb.note("Adding %s for %s" % (pkgname, depend))
            if pkgname not in rreclist and pkgname != pkg:
                rreclist[pkgname] = []

        #bb.note('setting: RRECOMMENDS_%s=%s' % (pkg, ' '.join(rreclist)))
        d.setVar('RRECOMMENDS_%s' % pkg, bb.utils.join_deps(rreclist, commasep=False))

    def pkg_addrrecs(pkg, base, suffix, getname, rdepends, d):

        #bb.note('rdepends for %s is %s' % (base, rdepends))
        rreclist = bb.utils.explode_dep_versions2(d.getVar('RRECOMMENDS_' + pkg, True) or "")

        for depend in rdepends:
            if depend.find('virtual-locale-') != -1:
                #bb.note("Skipping %s" % depend)
                continue
            if depend.endswith('-dev'):
                depend = depend[:-4]
            if depend.endswith('-dbg'):
                depend = depend[:-4]
            pkgname = getname(depend, suffix)
            #bb.note("Adding %s for %s" % (pkgname, depend))
            if pkgname not in rreclist and pkgname != pkg:
                rreclist[pkgname] = []

        #bb.note('setting: RRECOMMENDS_%s=%s' % (pkg, ' '.join(rreclist)))
        d.setVar('RRECOMMENDS_%s' % pkg, bb.utils.join_deps(rreclist, commasep=False))

    def add_dep(list, dep):
        if dep not in list:
            list.append(dep)

    depends = []
    for dep in bb.utils.explode_deps(d.getVar('DEPENDS', True) or ""):
        add_dep(depends, dep)

    rdepends = []
    for pkg in packages.split():
        for dep in bb.utils.explode_deps(d.getVar('RDEPENDS_' + pkg, True) or ""):
            add_dep(rdepends, dep)

    #bb.note('rdepends is %s' % rdepends)

    def post_getname(name, suffix):
        return '%s%s' % (name, suffix)
    def pre_getname(name, suffix):
        return '%s%s' % (suffix, name)

    pkgs = {}
    for pkg in packages.split():
        for postfix in postfixes:
            if pkg.endswith(postfix):
                if not postfix in pkgs:
                    pkgs[postfix] = {}
                pkgs[postfix][pkg] = (pkg[:-len(postfix)], post_getname)

        for prefix in prefixes:
            if pkg.startswith(prefix):
                if not prefix in pkgs:
                    pkgs[prefix] = {}
                pkgs[prefix][pkg] = (pkg[:-len(prefix)], pre_getname)

    if "-dbg" in pkgs:
        pkglibdeps = read_libdep_files(d)
        pkglibdeplist = []
        for pkg in pkglibdeps:
            for k in pkglibdeps[pkg]:
                add_dep(pkglibdeplist, k)
        # FIXME this should not look at PN once all task recipes inherit from task.bbclass
        dbgdefaultdeps = ((d.getVar('DEPCHAIN_DBGDEFAULTDEPS', True) == '1') or (d.getVar('PN', True) or '').startswith('packagegroup-'))

    for suffix in pkgs:
        for pkg in pkgs[suffix]:
            if d.getVarFlag('RRECOMMENDS_' + pkg, 'nodeprrecs'):
                continue
            (base, func) = pkgs[suffix][pkg]
            if suffix == "-dev":
                pkg_adddeprrecs(pkg, base, suffix, func, depends, d)
            elif suffix == "-dbg":
                if not dbgdefaultdeps:
                    pkg_addrrecs(pkg, base, suffix, func, pkglibdeplist, d)
                    continue
            if len(pkgs[suffix]) == 1:
                pkg_addrrecs(pkg, base, suffix, func, rdepends, d)
            else:
                rdeps = []
                for dep in bb.utils.explode_deps(d.getVar('RDEPENDS_' + base, True) or ""):
                    add_dep(rdeps, dep)
                pkg_addrrecs(pkg, base, suffix, func, rdeps, d)
}

# Since bitbake can't determine which variables are accessed during package
# iteration, we need to list them here:
PACKAGEVARS = "FILES RDEPENDS RRECOMMENDS SUMMARY DESCRIPTION RSUGGESTS RPROVIDES RCONFLICTS PKG ALLOW_EMPTY pkg_postinst pkg_postrm INITSCRIPT_NAME INITSCRIPT_PARAMS DEBIAN_NOAUTONAME ALTERNATIVE PKGE PKGV PKGR"

def gen_packagevar(d):
    ret = []
    pkgs = (d.getVar("PACKAGES", True) or "").split()
    vars = (d.getVar("PACKAGEVARS", True) or "").split()
    for p in pkgs:
        for v in vars:
            ret.append(v + "_" + p)
    return " ".join(ret)

PACKAGE_PREPROCESS_FUNCS ?= ""
# Functions for setting up PKGD
PACKAGEBUILDPKGD ?= " \
                perform_packagecopy \
                ${PACKAGE_PREPROCESS_FUNCS} \
                split_and_strip_files \
                fixup_perms \
                "
# Functions which split PKGD up into separate packages
PACKAGESPLITFUNCS ?= " \
                package_do_split_locales \
                populate_packages"
# Functions which process metadata based on split packages
PACKAGEFUNCS ?= " \
                package_fixsymlinks \
                package_name_hook \
                package_do_filedeps \
                package_do_shlibs \
                package_do_pkgconfig \
                read_shlibdeps \
                package_depchains \
                emit_pkgdata"

python do_package () {
    # Change the following version to cause sstate to invalidate the package
    # cache.  This is useful if an item this class depends on changes in a
    # way that the output of this class changes.  rpmdeps is a good example
    # as any change to rpmdeps requires this to be rerun.
    # PACKAGE_BBCLASS_VERSION = "1"

    # Init cachedpath
    global cpath
    cpath = oe.cachedpath.CachedPath()

    ###########################################################################
    # Sanity test the setup
    ###########################################################################

    packages = (d.getVar('PACKAGES', True) or "").split()
    if len(packages) < 1:
        bb.debug(1, "No packages to build, skipping do_package")
        return

    workdir = d.getVar('WORKDIR', True)
    outdir = d.getVar('DEPLOY_DIR', True)
    dest = d.getVar('D', True)
    dvar = d.getVar('PKGD', True)
    pn = d.getVar('PN', True)

    if not workdir or not outdir or not dest or not dvar or not pn:
        bb.error("WORKDIR, DEPLOY_DIR, D, PN and PKGD all must be defined, unable to package")
        return

    bb.build.exec_func("package_get_auto_pr", d)

    ###########################################################################
    # Optimisations
    ###########################################################################

    # Contunually rexpanding complex expressions is inefficient, particularly when
    # we write to the datastore and invalidate the expansion cache. This code 
    # pre-expands some frequently used variables

    def expandVar(x, d):
        d.setVar(x, d.getVar(x, True))

    for x in 'PN', 'PV', 'BPN', 'TARGET_SYS', 'EXTENDPRAUTO':
        expandVar(x, d)

    ###########################################################################
    # Setup PKGD (from D)
    ###########################################################################

    for f in (d.getVar('PACKAGEBUILDPKGD', True) or '').split():
        bb.build.exec_func(f, d)

    ###########################################################################
    # Split up PKGD into PKGDEST
    ###########################################################################

    cpath = oe.cachedpath.CachedPath()

    for f in (d.getVar('PACKAGESPLITFUNCS', True) or '').split():
        bb.build.exec_func(f, d)

    ###########################################################################
    # Process PKGDEST
    ###########################################################################

    # Build global list of files in each split package
    global pkgfiles
    pkgfiles = {}
    packages = d.getVar('PACKAGES', True).split()
    pkgdest = d.getVar('PKGDEST', True)
    for pkg in packages:
        pkgfiles[pkg] = []
        for walkroot, dirs, files in cpath.walk(pkgdest + "/" + pkg):
            for file in files:
                pkgfiles[pkg].append(walkroot + os.sep + file)

    for f in (d.getVar('PACKAGEFUNCS', True) or '').split():
        bb.build.exec_func(f, d)
}

do_package[dirs] = "${SHLIBSWORKDIR} ${PKGDESTWORK} ${D}"
do_package[vardeps] += "${PACKAGEBUILDPKGD} ${PACKAGESPLITFUNCS} ${PACKAGEFUNCS} ${@gen_packagevar(d)}"
addtask package before do_build after do_install

PACKAGELOCK = "${STAGING_DIR}/package-output.lock"
SSTATETASKS += "do_package"
do_package[sstate-name] = "package"
do_package[cleandirs] = "${PKGDEST} ${PKGDESTWORK}"
do_package[sstate-plaindirs] = "${PKGD} ${PKGDEST} ${PKGDESTWORK}"
do_package[sstate-lockfile-shared] = "${PACKAGELOCK}"
do_package_setscene[dirs] = "${STAGING_DIR}"

python do_package_setscene () {
    sstate_setscene(d)
}
addtask do_package_setscene

do_packagedata () {
	:
}

addtask packagedata before do_build after do_package

SSTATETASKS += "do_packagedata"
do_packagedata[sstate-name] = "packagedata"
do_packagedata[sstate-inputdirs] = "${PKGDESTWORK}"
do_packagedata[sstate-outputdirs] = "${PKGDATA_DIR}"
do_packagedata[sstate-lockfile-shared] = "${PACKAGELOCK}"

python do_packagedata_setscene () {
    sstate_setscene(d)
}
addtask do_packagedata_setscene

# Dummy task to mark when all packaging is complete
do_package_write () {
	:
}
do_package_write[noexec] = "1"
PACKAGERDEPTASK = "do_package_write"
do_build[recrdeptask] += "${PACKAGERDEPTASK}"
addtask package_write before do_build after do_packagedata

#
# Helper functions for the package writing classes
#

def mapping_rename_hook(d):
    """
    Rewrite variables to account for package renaming in things
    like debian.bbclass or manual PKG variable name changes
    """
    runtime_mapping_rename("RDEPENDS", d)
    runtime_mapping_rename("RRECOMMENDS", d)
    runtime_mapping_rename("RSUGGESTS", d)
    runtime_mapping_rename("RPROVIDES", d)
    runtime_mapping_rename("RREPLACES", d)
    runtime_mapping_rename("RCONFLICTS", d)

