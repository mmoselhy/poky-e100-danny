SUMMARY = "The basic file, shell and text manipulation utilities."
DESCRIPTION = "The GNU Core Utilities provide the basic file, shell and text \
manipulation utilities. These are the core utilities which are expected to exist on \
every system."
HOMEPAGE = "http://www.gnu.org/software/coreutils/"
BUGTRACKER = "http://debbugs.gnu.org/coreutils"
LICENSE = "GPLv3+"
LIC_FILES_CHKSUM = "file://COPYING;md5=d32239bcb673463ab874e80d47fae504\
                    file://src/ls.c;beginline=5;endline=16;md5=38b79785ca88537b75871782a2a3c6b8"
PR = "r0"
DEPENDS = "gmp libcap"
DEPENDS_class-native = ""

inherit autotools gettext

SRC_URI = "${GNU_MIRROR}/coreutils/${BP}.tar.xz \
           file://remove-usr-local-lib-from-m4.patch \
           file://coreutils-build-with-acl.patch \
           file://dummy_help2man.patch \
          "

SRC_URI[md5sum] = "065ba41828644eca5dd8163446de5d64"
SRC_URI[sha256sum] = "adaa44bdab3fa5eb352e80d8a31fdbf957b78653d0c2cd30d63e161444288e18"

EXTRA_OECONF = "--disable-acl"
EXTRA_OECONF_class-native = "--disable-acl --without-gmp"

# [ df mktemp base64 gets a special treatment and is not included in this
bindir_progs = "basename chcon cksum comm csplit cut dir dircolors dirname du \
                env expand expr factor fmt fold groups head hostid id install \
                join link logname md5sum mkfifo nice nl nohup nproc od paste pathchk \
                pinky pr printenv printf ptx readlink runcon seq sha1sum sha224sum sha256sum \
                sha384sum sha512sum shred shuf sort split stat stdbuf sum tac tail tee test timeout\
                tr truncate tsort tty unexpand uniq unlink uptime users vdir wc who whoami yes"

# hostname gets a special treatment and is not included in this
base_bindir_progs = "cat chgrp chmod chown cp date dd echo false kill ln ls mkdir \
                     mknod mv pwd rm rmdir sleep stty sync touch true uname"

sbindir_progs= "chroot"

# Deal with a separate builddir failure if src doesn't exist when creating version.c/version.h
do_compile_prepend () {
	mkdir -p ${B}/src
}

do_install_append() {
	for i in df mktemp base64; do mv ${D}${bindir}/$i ${D}${bindir}/$i.${BPN}; done

	install -d ${D}${base_bindir}
	[ "${base_bindir}" != "${bindir}" ] && for i in ${base_bindir_progs}; do mv ${D}${bindir}/$i ${D}${base_bindir}/$i.${BPN}; done

	install -d ${D}${sbindir}
	[ "${sbindir}" != "${bindir}" ] && for i in ${sbindir_progs}; do mv ${D}${bindir}/$i ${D}${sbindir}/$i.${BPN}; done

	# [ requires special handling because [.coreutils will cause the sed stuff
	# in update-alternatives to fail, therefore use lbracket - the name used
	# for the actual source file.
	mv ${D}${bindir}/[ ${D}${bindir}/lbracket.${BPN}
	install -d ${D}${libdir}/coreutils
	mv ${D}${libexecdir}/coreutils/libstdbuf.so ${D}${libdir}/coreutils
}

inherit update-alternatives

ALTERNATIVE_PRIORITY = "100"
ALTERNATIVE_${PN} = "lbracket ${bindir_progs} ${base_bindir_progs} ${sbindir_progs} base64 mktemp df"

ALTERNATIVE_LINK_NAME[base64] = "${base_bindir}/base64"
ALTERNATIVE_TARGET[base64] = "${bindir}/base64.${BPN}"

ALTERNATIVE_LINK_NAME[mktemp] = "${base_bindir}/mktemp"
ALTERNATIVE_TARGET[mktemp] = "${bindir}/mktemp.${BPN}"

ALTERNATIVE_LINK_NAME[df] = "${base_bindir}/df"
ALTERNATIVE_TARGET[df] = "${bindir}/df.${BPN}"

ALTERNATIVE_LINK_NAME[lbracket] = "${bindir}/["
ALTERNATIVE_TARGET[lbracket] = "${bindir}/lbracket.${BPN}"

python __anonymous() {
	for prog in d.getVar('base_bindir_progs', True).split():
		d.setVarFlag('ALTERNATIVE_LINK_NAME', prog, '%s/%s' % (d.getVar('base_bindir', True), prog))

	for prog in d.getVar('sbindir_progs', True).split():
		d.setVarFlag('ALTERNATIVE_LINK_NAME', prog, '%s/%s' % (d.getVar('sbindir', True), prog))
}

BBCLASSEXTEND = "native"
