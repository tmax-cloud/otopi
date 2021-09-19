#!/bin/bash -ex
DISTVER="$(rpm --eval "%dist"|cut -c2-4)"
installer=dnf

# stdci seems to ignore check-patch.packages
${installer} install -y $(cat automation/check-patch.packages)

autopoint
autoreconf -ivf
./configure
make distcheck

automation/build-artifacts.sh

${installer} install -y $(find "$PWD/exported-artifacts" -iname \*noarch\*.rpm)

LOGS=exported-artifacts/otopi_logs
mkdir -p "${LOGS}"

cov_otopi() {
	local otopi="$1"
	local name="$2"
	shift 2
	local log_dir="${LOGS}/otopi-$(date +"%Y%m%d-%H%M%S")-${name}"
	mkdir -p "${log_dir}"
	local stderrfile="${log_dir}/otopi-stderr-${name}.log"
	local rc=0

	OTOPI_DEBUG=1 OTOPI_COVERAGE=1 COVERAGE_PROCESS_START="${PWD}/automation/coverage.rc" COVERAGE_FILE=$(mktemp -p $PWD .coverage.XXXXXX) "${otopi}" CORE/logFileNamePrefix="str:${otopi}-${name}" CORE/logDir=str:"${log_dir}" "$@" 2> "${stderrfile}" || rc=$?
	if [ "${rc}" -ne 0 ]; then
		echo "cov_otopi: Failed: [rc=$rc] ${name}"
		tail -20 "${stderrfile}"
		return "${rc}"
	fi
}

# Test packager
prepare_test_repo() {
	pushd automation/testRPMs
	mkdir repos
	for p in testpackage*; do
		tar czf "${p}.tar.gz" "${p}"
		rpmbuild -D "_topdir $PWD/repos" -ta "${p}.tar.gz"
	done
	createrepo_c repos
	for yumdnfconf in /etc/yum.conf /etc/dnf/dnf.conf; do
		if [ -f "${yumdnfconf}" ]; then
			cat << __EOF__ >> "${yumdnfconf}"
[testpackages]
name=packages for testing otopi
baseurl=file://${PWD}/repos
gpgcheck=0
enabled=1
__EOF__
		fi
	done
	popd
}

prepare_test_updates_repo() {
	pushd automation/testRPMsUpdates
	mkdir repos_updates
	for p in testpackage*; do
		tar czf "${p}.tar.gz" "${p}"
		rpmbuild -D "_topdir $PWD/repos_updates" -ta "${p}.tar.gz"
	done
	createrepo_c repos_updates
	for yumdnfconf in /etc/yum.conf /etc/dnf/dnf.conf; do
		if [ -f "${yumdnfconf}" ]; then
			cat << __EOF__ >> "${yumdnfconf}"
[testpackagesupdates]
name=packages for testing otopi - updates
baseurl=file://${PWD}/repos_updates
gpgcheck=0
enabled=1
__EOF__
		fi
	done
	popd
}

prepare_test_repo
cov_otopi otopi packager-install-testpackage2 ODEBUG/packagesAction=str:install ODEBUG/packages=str:testpackage2
cov_otopi otopi packager-query-testpackages ODEBUG/packagesAction=str:queryPackages ODEBUG/packages=str:testpackage\*
cov_otopi otopi packager-checksafeupdate ODEBUG/packagesAction=str:checkForSafeUpdate ODEBUG/packages=str:testpackage1,testpackage2
cov_otopi otopi packager-remove-testpackage1 ODEBUG/packagesAction=str:remove ODEBUG/packages=str:testpackage1
cov_otopi otopi packager-queryGroups ODEBUG/packagesAction=str:queryGroups

# Group install/remove. TODO: Create our own group in automation/testRPMs and use that, instead of 'ftp-server'.
cov_otopi otopi packager-install-group-ftp-server ODEBUG/packagesAction=str:installGroup ODEBUG/packages=str:ftp-server
cov_otopi otopi packager-remove-group-ftp-server ODEBUG/packagesAction=str:removeGroup ODEBUG/packages=str:ftp-server

# Test command
PATH="${PWD}/automation/testbin:$PATH" OTOPI_TEST_COMMAND=1 cov_otopi otopi command

# Test machine dialog
cov_otopi otopi machine DIALOG/dialect=str:machine

cov_otopi otopi change_env_type "APPEND:BASE/pluginPath=str:${PWD}/automation/testplugins" "APPEND:BASE/pluginGroups=str:change_env_type"

# Test failures
cov_otopi_rc() {
	local expected_rc=$1
	shift
	local rc=0
	cov_otopi "$@" || rc=$?
	if [ "${rc}" -ne "${expected_rc}" ]; then
		echo ERROR: otopi was supposed to have exit code ${expected_rc} but had instead ${rc}
		exit 1
	else
		echo otopi exited with exit code ${rc} and this is ok
	fi
}

cov_failing_otopi() {
	cov_otopi_rc 1 "$@"
}

OTOPI_FORCE_FAIL_STAGE=STAGE_MISC cov_failing_otopi otopi force_fail
cov_failing_otopi otopi bad_before_after "APPEND:BASE/pluginPath=str:${PWD}/automation/testplugins" "APPEND:BASE/pluginGroups=str:bad_plugin1"
cov_failing_otopi otopi cyclic_dep "APPEND:BASE/pluginPath=str:${PWD}/automation/testplugins" "APPEND:BASE/pluginGroups=str:event_cyclic_dep"
cov_failing_otopi otopi non_existent_before_after "APPEND:BASE/pluginPath=str:${PWD}/automation/testplugins" "APPEND:BASE/pluginGroups=str:non_existent_before_after CORE/ignoreMissingBeforeAfter=bool:False"
cov_failing_otopi otopi duplicate_method_names "APPEND:BASE/pluginPath=str:${PWD}/automation/testplugins" "APPEND:BASE/pluginGroups=str:duplicate_method_names"

# Test packager rollback. testpackage1 should not be installed at this point, because we remove it earlier
if rpm -q testpackage1 2>&1; then
	echo "ERROR: Packager rollback: testpackage1 found before testing, failing"
	exit 1
fi
OTOPI_FORCE_FAIL_STAGE=STAGE_MISC cov_failing_otopi otopi packager-install-testpackage1-undo ODEBUG/packagesAction=str:install ODEBUG/packages=str:testpackage1
# force_fail should fail it, so using 'cov_failing_otopi', but we also want to verify that testpackage1's installation was reverted
if rpm -q testpackage1 2>&1; then
	echo "ERROR: Packager rollback: testpackage1 found after testing, failing"
	exit 1
fi

cov_otopi otopi packager-install-testpackage1 ODEBUG/packagesAction=str:install ODEBUG/packages=str:testpackage1
prepare_test_updates_repo
# 101 is EXIT_CODE_DEBUG_PACKAGER_ROLLBACK_EXISTS - there is an update, and if we fail to update, we can rollback
cov_otopi_rc 101 otopi packager-checksafeupdate-with-update ODEBUG/packagesAction=str:checkForSafeUpdate ODEBUG/packages=str:testpackage1,testpackage2
dnf config-manager --disable testpackages
# 102 is EXIT_CODE_DEBUG_PACKAGER_ROLLBACK_MISSING - there is an update, but if we fail to update, can't rollback, because existing installed package can't be found in current repos
cov_otopi_rc 102 otopi packager-checksafeupdate-with-disabled-current ODEBUG/packagesAction=str:checkForSafeUpdate ODEBUG/packages=str:testpackage1,testpackage2
dnf config-manager --enable testpackages
cov_otopi_rc 101 otopi packager-checksafeupdate-with-update ODEBUG/packagesAction=str:checkForSafeUpdate ODEBUG/packages=str:testpackage1,testpackage2
# Try again to update, but force failing - to test that rollback to current version works
OTOPI_FORCE_FAIL_STAGE=STAGE_MISC cov_failing_otopi otopi packager-install-update-testpackage1-undo ODEBUG/packagesAction=str:install ODEBUG/packages=str:testpackage1
cov_otopi_rc 101 otopi packager-checksafeupdate-with-update ODEBUG/packagesAction=str:checkForSafeUpdate ODEBUG/packages=str:testpackage1,testpackage2
cov_otopi otopi packager-install-update-testpackage1-do ODEBUG/packagesAction=str:install ODEBUG/packages=str:testpackage1
if ! rpm -q testpackage1 2>&1 | grep 'testpackage1-1.0.1'; then
	echo "ERROR: testpackage1-1.0.1 not found, update failed"
	exit 1
fi

# Do some minimal testing for python3, even if we default to python2 in the
# rest of the tests. Test if python3 is "supported" simply by running otopi
# with python3 and see if this works. Disable the packagers so that problems
# in them will be revealed in the actual test (and also so that it runs very
# fast).
if OTOPI_PYTHON=python3 otopi PACKAGER/dnfpackagerEnabled=bool:False PACKAGER/yumpackagerEnabled=bool:False > /dev/null 2>&1; then
	OTOPI_PYTHON=python3 cov_otopi otopi packager-python3 ODEBUG/packagesAction=str:install ODEBUG/packages=str:yelp-tools
fi

coverage combine --rcfile="${PWD}/automation/coverage.rc"
coverage html -d exported-artifacts/coverage_html_report --rcfile="${PWD}/automation/coverage.rc"
cp automation/index.html exported-artifacts/

# Validate a bundle on a system without otopi installed
bundle_exec="/usr/share/otopi/otopi-bundle"
bundle_dir="$(mktemp -d)"
selfinst="$(mktemp /tmp/otopi-installer-XXXXX.sh)"

if [ -x ${bundle_exec} ]; then
    ${bundle_exec} --target="${bundle_dir}"
    makeself --follow "${bundle_dir}" "${selfinst}" "Test ${name}" ./otopi packager ODEBUG/packagesAction=str:install ODEBUG/packages=str:zziplib,zsh
fi

try_on_centos_stream() {
	echo "Testing CentOS Stream"
	# Copied from ovirt-release, keep variable PACKAGER although it's also hardcoded there now
	PACKAGER=dnf
	export PACKAGER

	# Restoring sane yum environment
	rm -f /etc/yum.conf
	${PACKAGER} reinstall -y system-release ${PACKAGER}
	[[ -d /etc/dnf ]] && [[ -x /usr/bin/dnf ]] && dnf -y reinstall dnf-conf
	[[ -d /etc/dnf ]] && sed -i -re 's#^(reposdir *= *).*$#\1/etc/yum.repos.d#' '/etc/dnf/dnf.conf'
	[[ -e /etc/dnf/dnf.conf ]] && echo "deltarpm=False" >> /etc/dnf/dnf.conf
	${PACKAGER} install -y https://resources.ovirt.org/pub/yum-repo/ovirt-release-master.rpm
	rm -f /etc/yum/yum.conf

	${PACKAGER} install -y centos-release-stream
	${PACKAGER} repolist enabled
	${PACKAGER} --releasever=8-stream --disablerepo=* --enablerepo=Stream-BaseOS download centos-stream-repos
	${PACKAGER} install -y centos-stream-release
	rpm -e --nodeps centos-linux-repos
	rpm -i centos-stream-repo*
	rm -fv centos-stream-repo*
	ls -l /etc/yum.repos.d/
	${PACKAGER} distro-sync -y
	# Install again, because distro-sync above downgraded for some reason, didn't check
	# TODO remove this "Stream support" if/when we move fully to Stream.
	${installer} install -y $(find "$PWD/exported-artifacts" -iname \*noarch\*.rpm)
	${PACKAGER} repolist enabled
	${PACKAGER} clean all
	cov_otopi otopi packager-stream-install-testpackage2 ODEBUG/packagesAction=str:install ODEBUG/packages=str:testpackage2
	cov_otopi otopi packager-stream-remove-testpackage1 ODEBUG/packagesAction=str:remove ODEBUG/packages=str:testpackage1
	cov_otopi otopi packager-stream-queryGroups ODEBUG/packagesAction=str:queryGroups
}

if ! try_on_centos_stream; then
	echo "WARNING: Failed to try on Centos Stream, not failing the build"
fi

${installer} remove "*otopi*" zsh
${selfinst}

cp ${selfinst} exported-artifacts/
