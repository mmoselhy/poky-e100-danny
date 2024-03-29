# The list of packages that should have systemd packaging scripts added.  For
# each entry, optionally have a SYSTEMD_SERVICE_[package] that lists the service
# files in this package.  If this variable isn't set, [package].service is used.
SYSTEMD_PACKAGES ?= "${PN}"

# Whether to enable or disable the services on installation.
SYSTEMD_AUTO_ENABLE ??= "enable"

# This class will be included in any recipe that supports systemd init scripts,
# even if the systemd DISTRO_FEATURE isn't enabled.  As such don't make any
# changes directly but check the DISTRO_FEATURES first.
python __anonymous() {
    features = d.getVar("DISTRO_FEATURES", True).split()
    # If the distro features have systemd but not sysvinit, inhibit update-rcd
    # from doing any work so that pure-systemd images don't have redundant init
    # files.
    if "systemd" in features:
        d.appendVar("DEPENDS", " systemd-systemctl-native")
        if "sysvinit" not in features:
            d.setVar("INHIBIT_UPDATERCD_BBCLASS", "1")
}

systemd_postinst() {
OPTS=""

if [ -n "$D" ]; then
    OPTS="--root=$D"
fi

if type systemctl >/dev/null 2>/dev/null; then
	systemctl $OPTS ${SYSTEMD_AUTO_ENABLE} ${SYSTEMD_SERVICE}

	if [ -z "$D" -a "${SYSTEMD_AUTO_ENABLE}" = "enable" ]; then
		systemctl start ${SYSTEMD_SERVICE}
	fi
fi
}

systemd_prerm() {
if type systemctl >/dev/null 2>/dev/null; then
	if [ -z "$D" ]; then
		systemctl stop ${SYSTEMD_SERVICE}
	fi

	systemctl disable ${SYSTEMD_SERVICE}
fi
}

python systemd_populate_packages() {
    if "systemd" not in d.getVar("DISTRO_FEATURES", True).split():
        return

    def get_package_var(d, var, pkg):
        val = (d.getVar('%s_%s' % (var, pkg), True) or "").strip()
        if val == "":
            val = (d.getVar(var, True) or "").strip()
        return val

    # Check if systemd-packages already included in PACKAGES
    def systemd_check_package(pkg_systemd):
        packages = d.getVar('PACKAGES', True)
        if not pkg_systemd in packages.split():
            bb.error('%s does not appear in package list, please add it' % pkg_systemd)


    def systemd_generate_package_scripts(pkg):
        bb.debug(1, 'adding systemd calls to postinst/postrm for %s' % pkg)

        # Add pkg to the overrides so that it finds the SYSTEMD_SERVICE_pkg
        # variable.
        localdata = d.createCopy()
        localdata.prependVar("OVERRIDES", pkg + ":")
        bb.data.update_data(localdata)

        postinst = d.getVar('pkg_postinst_%s' % pkg, True)
        if not postinst:
            postinst = '#!/bin/sh\n'
        postinst += localdata.getVar('systemd_postinst', True)
        d.setVar('pkg_postinst_%s' % pkg, postinst)

        prerm = d.getVar('pkg_prerm_%s' % pkg, True)
        if not prerm:
            prerm = '#!/bin/sh\n'
        prerm += localdata.getVar('systemd_prerm', True)
        d.setVar('pkg_prerm_%s' % pkg, prerm)


    # Add files to FILES_*-systemd if existent and not already done
    def systemd_append_file(pkg_systemd, file_append):
        appended = False
        if os.path.exists(oe.path.join(d.getVar("D", True), file_append)):
            var_name = "FILES_" + pkg_systemd
            files = d.getVar(var_name, False) or ""
            if file_append not in files.split():
                d.appendVar(var_name, " " + file_append)
                appended = True
        return appended

    # Add systemd files to FILES_*-systemd, parse for Also= and follow recursive
    def systemd_add_files_and_parse(pkg_systemd, path, service, keys):
        # avoid infinite recursion
        if systemd_append_file(pkg_systemd, oe.path.join(path, service)):
            fullpath = oe.path.join(d.getVar("D", True), path, service)
            if service.find('.service') != -1:
                # for *.service add *@.service
                service_base = service.replace('.service', '')
                systemd_add_files_and_parse(pkg_systemd, path, service_base + '@.service', keys)
            if service.find('.socket') != -1:
                # for *.socket add *.service and *@.service
                service_base = service.replace('.socket', '')
                systemd_add_files_and_parse(pkg_systemd, path, service_base + '.service', keys)
                systemd_add_files_and_parse(pkg_systemd, path, service_base + '@.service', keys)
            for key in keys.split():
                # recurse all dependencies found in keys ('Also';'Conflicts';..) and add to files
                cmd = "grep %s %s | sed 's,%s=,,g' | tr ',' '\\n'" % (key, fullpath, key)
                pipe = os.popen(cmd, 'r')
                line = pipe.readline()
                while line:
                    line = line.replace('\n', '')
                    systemd_add_files_and_parse(pkg_systemd, path, line, keys)
                    line = pipe.readline()
                pipe.close()

    # Check service-files and call systemd_add_files_and_parse for each entry
    def systemd_check_services():
        searchpaths = [oe.path.join(d.getVar("sysconfdir", True), "systemd", "system"),]
        searchpaths.append(oe.path.join(d.getVar("nonarch_base_libdir", True), "systemd", "system"))
        searchpaths.append(oe.path.join(d.getVar("exec_prefix", True), d.getVar("nonarch_base_libdir", True), "systemd", "system"))
        systemd_packages = d.getVar('SYSTEMD_PACKAGES', True)
        has_exactly_one_service = len(systemd_packages.split()) == 1
        if has_exactly_one_service:
            has_exactly_one_service = len(get_package_var(d, 'SYSTEMD_SERVICE', systemd_packages).split()) == 1

        keys = 'Also' # Conflicts??
        if has_exactly_one_service:
            # single service gets also the /dev/null dummies
            keys = 'Also Conflicts'
        # scan for all in SYSTEMD_SERVICE[]
        for pkg_systemd in systemd_packages.split():
            for service in get_package_var(d, 'SYSTEMD_SERVICE', pkg_systemd).split():
                path_found = ''
                for path in searchpaths:
                    if os.path.exists(oe.path.join(d.getVar("D", True), path, service)):
                        path_found = path
                        break
                if path_found != '':
                    systemd_add_files_and_parse(pkg_systemd, path_found, service, keys)
                else:
                    raise bb.build.FuncFailed, "\n\nSYSTEMD_SERVICE_%s value %s does not exist" % \
                        (pkg_systemd, service)

    # Run all modifications once when creating package
    if os.path.exists(d.getVar("D", True)):
        for pkg in d.getVar('SYSTEMD_PACKAGES', True).split():
            systemd_check_package(pkg)
            if d.getVar('SYSTEMD_SERVICE_' + pkg, True):
                systemd_generate_package_scripts(pkg)
        systemd_check_services()
}

PACKAGESPLITFUNCS_prepend = "systemd_populate_packages "
