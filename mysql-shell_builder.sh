#!/usr/bin/env bash
set -o pipefail

shell_quote_string() {
    echo "$1" | sed -e 's,\([^A-Za-z0-9_\-\.\,\:\/\@\n]\),\\\1,g'
}

usage () {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given :
        --builddir=DIR        Absolute path to the dir where all actions will be performed
        --get_sources=1       Download sources from github and create the source tarball
        --build_src_rpm=1     Build the src.rpm
        --build_source_deb=1  Build the source deb (.dsc)
        --build_rpm=1         Build the rpm
        --build_deb=1         Build the deb
        --build_tarball=1     Build the binary tarball
        --install_deps=1      Install build dependencies (requires root)
        --verify=1            Install the built package in a clean container and run runtime checks
        --verify_inplace=1    Verify on the build host instead (unreliable: build paths still resolve)
        --repo=URL            Database repo (default: percona-server)
        --branch_db=BRANCH    Branch/tag of the database repo
        --repo_mysqlshell=URL mysql-shell repo (default: upstream)
        --mysqlshell_branch=T mysql-shell tag, e.g. 9.7.1 or 8.4.10
        --with_js=0|1         Build the GraalVM JS library (default: 1)
        --apply_patches=0|1   Apply the Percona patch series (default: 1; 0 builds vanilla upstream)
        --refresh_patches=0|1 Regenerate Percona patches from the fork first (default: 1)
        --antlr_version=X     Bundled ANTLR C++ runtime version (default: ${ANTLR_VERSION_DEFAULT})
        --graalvm_version=X   GraalVM JDK version for the JS library (default: ${GRAALVM_VERSION_DEFAULT})
        --rpm_release=N       RPM release (default: 1)
        --deb_release=N       DEB release (default: 1)
        --help

Example:
  $0 --builddir=/tmp/PS --get_sources=1 --build_src_rpm=1 --build_rpm=1 \\
     --mysqlshell_branch=9.7.1 --branch_db=release-9.6.0-1
EOF
        exit 1
}

append_arg_to_args () {
    args="$args "$(shell_quote_string "$1")
}

parse_arguments() {
    pick_args=
    if test "$1" = PICK-ARGS-FROM-ARGV
    then
        pick_args=1
        shift
    fi
    for arg do
        val=$(echo "$arg" | sed -e 's;^--[^=]*=;;')
        case "$arg" in
            --builddir=*) WORKDIR="$val" ;;
            --build_src_rpm=*) SRPM="$val" ;;
            --build_source_deb=*) SDEB="$val" ;;
            --build_rpm=*) RPM="$val" ;;
            --build_deb=*) DEB="$val" ;;
            --get_sources=*) SOURCE="$val" ;;
            --build_tarball=*) TARBALL="$val" ;;
            --install_deps=*) INSTALL="$val" ;;
            --verify=*) VERIFY="$val" ;;
            --verify_inplace=*) VERIFY_INPLACE="$val" ;;
            --branch_db=*) BRANCH="$val" ;;
            --repo=*) REPO="$val" ;;
            --repo_mysqlshell=*) SHELL_REPO="$val" ;;
            --mysqlshell_branch=*) SHELL_BRANCH="$val" ;;
            --with_js=*) WITH_JS="$val" ;;
            --refresh_patches=*) REFRESH_PATCHES="$val" ;;
            --apply_patches=*) APPLY_PATCHES="$val" ;;
            --antlr_version=*) ANTLR_VERSION="$val" ;;
            --graalvm_version=*) GRAALVM_VERSION="$val" ;;
            --rpm_release=*) RPM_RELEASE="$val" ;;
            --deb_release=*) DEB_RELEASE="$val" ;;
            --help) usage ;;
            *)
                if test -n "$pick_args"
                then
                    append_arg_to_args "$arg"
                fi
            ;;
        esac
    done
}

die() { echo "ERROR: $*" >&2; exit 1; }

check_workdir(){
    if [ "x$WORKDIR" = "x$CURDIR" ]; then
        echo >&2 "Current directory cannot be used for building!"
        exit 1
    fi
    if [ ! -d "$WORKDIR" ]; then
        die "$WORKDIR is not a directory."
    fi
}

get_system(){
    ARCH=$(uname -m)
    if [ -f /etc/redhat-release ] || [ -f /etc/system-release ]; then
        OS="rpm"
        if [ -f /etc/amazon-linux-release ] || grep -qi 'amazon' /etc/system-release 2>/dev/null; then
            RHEL=$(rpm --eval %amzn)
            OS_NAME="amzn$RHEL"
            DIST_TAG=".amzn$RHEL"
        else
            RHEL=$(rpm --eval %rhel)
            OS_NAME="el$RHEL"
            DIST_TAG=".el$RHEL"
        fi
    else
        OS="deb"
        if [ -r /etc/os-release ]; then
            OS_NAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
        fi
        if [ -z "${OS_NAME}" ] && command -v lsb_release >/dev/null 2>&1; then
            OS_NAME="$(lsb_release -sc)"
        fi
        RHEL=0
        DIST_TAG=""
    fi
    export OS OS_NAME RHEL ARCH DIST_TAG

    case "$OS_NAME" in
        el8|el9|el10|amzn2023|bookworm|trixie|jammy|noble|resolute) ;;
        *) die "Unsupported distribution '$OS_NAME'. Supported: el8 el9 el10 amzn2023 bookworm trixie jammy noble resolute" ;;
    esac
    if [ "${OS_NAME}" = "resolute" ]; then
        export CMAKE_POLICY_VERSION_MINIMUM=3.5
        export DEB_CPPFLAGS_STRIP="-D_FORTIFY_SOURCE=3"
    fi
    echo "Building on ${OS_NAME} (${OS}) ${ARCH}"
}

shell_series(){
    echo "${SHELL_BRANCH}" | awk -F'.' '{print $1"."$2}'
}

add_percona_yum_repo(){
    curl -sL --connect-timeout 15 --max-time 60 --retry 2 \
        -o /etc/yum.repos.d/percona-dev.repo \
        https://jenkins.percona.com/yum-repo/percona-dev.repo || true
}

add_percona_apt_repo(){
    wget -q --timeout=15 --tries=2 -O - http://jenkins.percona.com/apt-repo/8507EFA5.pub \
        | apt-key add - 2>/dev/null || true
    echo "deb http://jenkins.percona.com/apt-repo/ @@DIST@@ main" \
        | sed "s:@@DIST@@:$OS_NAME:g" > /etc/apt/sources.list.d/percona-dev.list
    apt-get update -qq || true
}

install_deps() {
    if [ $INSTALL = 0 ]; then
        echo "Dependencies will not be installed"
        return
    fi
    [ "$(id -u)" -eq 0 ] || die "It is not possible to install dependencies. Please run as root"

    if [ "x$OS" = "xrpm" ]; then
        if [ "$OS_NAME" = "amzn2023" ]; then
            dnf -y install --allowerasing 'dnf-command(config-manager)' || true
        else
            dnf -y install dnf-plugins-core "oracle-epel-release-el${RHEL}" || \
                dnf -y install dnf-plugins-core epel-release || true
            dnf config-manager --enable "ol${RHEL}_codeready_builder" || \
                dnf config-manager --enable crb || true
            dnf config-manager --enable "ol${RHEL}_developer_EPEL" >/dev/null 2>&1 || true
        fi
        add_percona_yum_repo

        RPM_PKGS="git wget tar gzip patch diffutils which findutils make cmake bison
                  pkgconf-pkg-config rpm-build rpmdevtools
                  openssl-devel ncurses-devel zlib-devel libcurl-devel libssh-devel
                  libtirpc-devel rpcgen patchelf
                  cyrus-sasl-devel cyrus-sasl-scram cyrus-sasl-gssapi
                  krb5-devel openldap-devel systemd-devel
                  libaio-devel numactl-devel perl-Digest-MD5 perl-Env"
        command -v curl >/dev/null 2>&1 || RPM_PKGS="$RPM_PKGS curl"
        if [ -n "${OS_TOOLSET:-}" ]; then
            RPM_PKGS="$RPM_PKGS gcc-toolset-14"
        else
            RPM_PKGS="$RPM_PKGS gcc gcc-c++"
        fi
        if [ "${RHEL}" = "8" ]; then
            dnf -y module enable python38 || true
            RPM_PKGS="$RPM_PKGS python38-devel python38-pip"
        else
            RPM_PKGS="$RPM_PKGS python3-devel python3-pip"
        fi
        # shellcheck disable=SC2086
        dnf -y install $RPM_PKGS || die "dependency installation failed"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        add_percona_apt_repo

        DEB_PKGS="git wget curl ca-certificates tar gzip patch diffutils make cmake bison
                  build-essential pkg-config lsb-release
                  debhelper devscripts dpkg-dev fakeroot
                  libssl-dev libncurses-dev libudev-dev libcurl4-openssl-dev libssh-dev
                  zlib1g-dev liblz4-dev libsasl2-dev libsasl2-modules-gssapi-mit
                  libkrb5-dev libldap-dev
                  python3 python3-dev python3-pip python3-venv patchelf
                  libaio-dev libnuma-dev libtirpc-dev"
        # shellcheck disable=SC2086
        apt-get -y install --no-install-recommends $DEB_PKGS || die "dependency installation failed"
    fi
}

enable_toolset(){
    if [ -n "${OS_TOOLSET:-}" ] && [ -f "${OS_TOOLSET}" ]; then
        # shellcheck disable=SC1090
        . "${OS_TOOLSET}"
        echo "Enabled toolchain: ${OS_TOOLSET} ($(gcc --version | head -1))"
    fi
    command -v gcc >/dev/null || die "no C compiler on PATH (run with --install_deps=1?)"
    command -v g++ >/dev/null || die "no C++ compiler on PATH"
}

build_antlr(){
    if [ -d "${ANTLR_PREFIX}/include" ]; then
        echo "ANTLR already built at ${ANTLR_PREFIX}"
        return
    fi
    echo "Building ANTLR C++ runtime ${ANTLR_VERSION}"
    cd "${WORKDIR}" || die "no workdir"
    rm -rf antlr4-runtime
    git clone -q --depth 1 --branch "${ANTLR_VERSION}" --sparse \
        https://github.com/antlr/antlr4.git antlr4-runtime || die "antlr clone failed"
    ( cd antlr4-runtime && git sparse-checkout set runtime/Cpp ) || die "antlr sparse checkout failed"
    mkdir -p antlr4-runtime/build
    ( cd antlr4-runtime/build \
      && cmake ../runtime/Cpp -DCMAKE_BUILD_TYPE=Release -DANTLR_BUILD_CPP_TESTS=OFF \
      && cmake --build . --parallel "$(nproc)" \
      && cmake --install . --prefix "${ANTLR_PREFIX}" ) || die "antlr build failed"
}

build_jitexecutor(){
    if [ "$WITH_JS" = "0" ]; then
        echo "JS support disabled, skipping jitexecutor"
        return
    fi
    if [ -f "${JITEXECUTOR_DIR}/libjitexecutor.so" ]; then
        echo "jitexecutor already built at ${JITEXECUTOR_DIR}"
        return
    fi
    local src_tree="$1"
    [ -d "${src_tree}/ext/polyglot" ] || die "no ext/polyglot in ${src_tree}"

    cd "${WORKDIR}" || die "no workdir"

    if [ "x$ARCH" = "xx86_64" ]; then
        GRAAL_TARBALL="graalvm-community-jdk-${GRAALVM_VERSION}_linux-x64_bin.tar.gz"
    else
        GRAAL_TARBALL="graalvm-community-jdk-${GRAALVM_VERSION}_linux-aarch64_bin.tar.gz"
    fi

    if [ ! -x "${WORKDIR}/graalvm/bin/native-image" ]; then
        wget -nv "https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${GRAALVM_VERSION}/${GRAAL_TARBALL}" \
            || die "graalvm download failed"
        mkdir -p "${WORKDIR}/graalvm"
        tar xzf "${GRAAL_TARBALL}" -C "${WORKDIR}/graalvm" --strip-components=1 || die "graalvm unpack failed"
        rm -f "${GRAAL_TARBALL}"
    fi

    if [ ! -x "${WORKDIR}/maven/bin/mvn" ]; then
        wget -nv "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
            || die "maven download failed"
        mkdir -p "${WORKDIR}/maven"
        tar xzf "apache-maven-${MAVEN_VERSION}-bin.tar.gz" -C "${WORKDIR}/maven" --strip-components=1
        rm -f "apache-maven-${MAVEN_VERSION}-bin.tar.gz"
    fi

    if [ ! -d "${WORKDIR}/graal/substratevm" ]; then
        rm -rf "${WORKDIR}/graal"
        git clone -q --depth 1 --branch "${GRAAL_TAG}" --filter=blob:none --sparse \
            https://github.com/oracle/graal.git "${WORKDIR}/graal" || die "graal clone failed"
        ( cd "${WORKDIR}/graal" && git sparse-checkout set substratevm/src/org.graalvm.polyglot.nativeapi ) \
            || die "graal sparse checkout failed"
    fi

    mkdir -p "${HOME}/.m2"
    cat > "${HOME}/.m2/settings.xml" <<'EOM'
<settings>
  <mirrors>
    <mirror>
      <id>central-for-oracle-internal</id>
      <mirrorOf>artifactory.libs-release</mirrorOf>
      <url>https://repo1.maven.org/maven2</url>
    </mirror>
  </mirrors>
</settings>
EOM

    export JAVA_HOME="${WORKDIR}/graalvm"
    export GRAALVM_HOME="${WORKDIR}/graalvm"
    export GRAALJDK_ROOT="${WORKDIR}/graal"
    export PATH="${WORKDIR}/graalvm/bin:${WORKDIR}/maven/bin:${PATH}"

    ( cd "${src_tree}/ext/polyglot" && mvn -B package ) || die "jitexecutor build failed"

    mkdir -p "${JITEXECUTOR_DIR}"
    cp "${src_tree}/ext/polyglot/polyglot-nativeapi-native-library/target/libjitexecutor.so" "${JITEXECUTOR_DIR}/" \
        || die "libjitexecutor.so not produced"
    cp "${src_tree}"/ext/polyglot/polyglot-nativeapi-native-library/target/*.h "${JITEXECUTOR_DIR}/"
    echo "jitexecutor built: $(ls -la "${JITEXECUTOR_DIR}/libjitexecutor.so")"
}

get_database(){
    cd "${WORKDIR}" || die "no workdir"
    local repo_name
    repo_name=$(basename "${REPO}" .git)
    if [ -d "${repo_name}/.git" ] \
       && [ "$(cd "${repo_name}" && git rev-parse --verify -q HEAD)" = \
            "$(cd "${repo_name}" && git rev-parse --verify -q "${BRANCH}")" ]; then
        echo "Reusing existing ${repo_name} at ${BRANCH}"
    else
        rm -rf "${repo_name}"
        git clone "${REPO}" || die "database repo clone failed"
        cd "${repo_name}" || die "no ${repo_name}"
        git checkout "${BRANCH}" || die "cannot checkout ${BRANCH}"
        git submodule update --init --recursive || die "submodule update failed"
        cd "${WORKDIR}"
    fi

    cd "${repo_name}" || die "no ${repo_name}"
    if [ -f build-ps/rpm/mysql-5.7-sharedlib-rename.patch ] && [ ! -f .sharedlib_rename_applied ]; then
        patch -p0 < build-ps/rpm/mysql-5.7-sharedlib-rename.patch \
            || die "sharedlib rename patch failed to apply"
        touch .sharedlib_rename_applied
        rm -rf bld
    fi
    export DB_SOURCE_DIR="${WORKDIR}/${repo_name}"
    cd "${WORKDIR}"
}

build_database(){
    [ -n "${DB_SOURCE_DIR:-}" ] || die "get_database must run first"
    if [ -f "${DB_SOURCE_DIR}/bld/runtime_output_directory/mysqlbinlog" ]; then
        echo "Percona Server client libraries already built"
        return
    fi
    mkdir -p "${DB_SOURCE_DIR}/bld"
    cd "${DB_SOURCE_DIR}/bld" || die "no db build dir"

    local db_flags=()
    case "${OS_NAME}" in
        jammy|noble|resolute)
            db_flags+=( -DCMAKE_C_FLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2"
                        -DCMAKE_CXX_FLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2" ) ;;
    esac

    cmake .. \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DWITH_AUTHENTICATION_CLIENT_PLUGINS=YES \
        -DWITH_TIRPC=bundled \
        "${db_flags[@]}" \
        -DDOWNLOAD_BOOST=1 -DWITH_BOOST="${WORKDIR}/boost" 2>&1 \
        | tee "${DB_SOURCE_DIR}/bld/configure.log" || die "database cmake failed"

    cmake --build . --parallel "$(nproc)" --target \
        mysqlclient mysqlxclient mysqlxclient_lite libprotobuf-lite \
        mysql_config_editor mysql_binlog_event_standalone mysqlbinlog \
        routing_guidelines-objects || die "database build failed"

    local t targets
    targets=$(cmake --build . --target help 2>/dev/null | sed -n 's/^\.\.\. //p' | awk '{print $1}')
    for t in mysql_native_password authentication_oci_client \
             authentication_openid_connect_client authentication_webauthn_client \
             authentication_ldap_sasl_client authentication_kerberos_client ; do
        if [ -n "${targets}" ] && ! printf '%s\n' "${targets}" | grep -qx "${t}"; then
            echo "NOTE: ${t} is not a target of this server build, skipping"
            continue
        fi
        cmake --build . --parallel "$(nproc)" --target "$t" \
            || die "server target ${t} failed to build"
    done

    echo "Client plugins built:"
    find . -name 'authentication_*_client.so' -o -name 'mysql_native_password.so' \
        | sed 's|.*/|  |' | sort
    find . -name 'libfido2.so*' | sed 's|^|  |' | sort

    if [ -z "$(find . -name 'libfido2.so*' -print -quit)" ]; then
        echo "FIDO and libudev decisions from the server configure:"
        grep -iE "fido|libudev|udev_system_library" "${DB_SOURCE_DIR}/bld/configure.log" \
            | head -20 | sed 's|^|  |'
        die "the server build produced no libfido2. The packaging lists it unconditionally, so dh_install and the rpm %files would fail later with a missing file instead of pointing here"
    fi
    cd "${WORKDIR}"
}

skip_rpath_for_bundled_binaries(){
    local src_tree="$1" f n
    for f in "${src_tree}/modules/CMakeLists.txt" \
             "${src_tree}/mysql-secret-store/login-path/CMakeLists.txt"; do
        [ -f "${f}" ] || die "no ${f}"
        grep -q 'DESTINATION "${INSTALL_LIBEXECDIR}"' "${f}" \
            || die "libexec bundling not found in ${f}; upstream changed, re-check this workaround"
        perl -0pi -e 's{(\n(\s*)DESTINATION "\$\{INSTALL_LIBEXECDIR\}")}{$1\n$2WRITE_RPATH FALSE}g' "${f}"
        n=$(grep -c 'WRITE_RPATH FALSE' "${f}")
        [ "${n}" -ge 1 ] || die "failed to set WRITE_RPATH FALSE in ${f}"
        echo "WRITE_RPATH FALSE applied in $(basename "$(dirname "${f}")")/$(basename "${f}") (${n} site(s))"
    done
}

apply_upstream_backports(){
    local src_tree="$1" p name applied=0
    local dir="${SCRIPT_DIR}/patches/backports"
    [ -d "${dir}" ] || return 0

    for p in "${dir}"/*.patch; do
        [ -f "${p}" ] || continue
        name=$(basename "${p}")
        if ( cd "${src_tree}" && patch -p1 -N --dry-run < "${p}" ) >/dev/null 2>&1; then
            ( cd "${src_tree}" && patch -p1 -N < "${p}" ) >/dev/null \
                || die "upstream backport ${name} failed to apply"
            echo "Applied upstream backport ${name}"
            applied=$((applied + 1))
        else
            echo "NOTE: upstream backport ${name} does not apply to ${SHELL_BRANCH}; assuming it is already included"
        fi
    done
    echo "Applied ${applied} upstream backport(s)"
}

apply_percona_patches(){
    local src_tree="$1"
    local series dir
    series=$(shell_series)
    dir="${SCRIPT_DIR}/patches/${series}"

    if [ "${APPLY_PATCHES}" = "0" ]; then
        echo "Percona patches disabled (--apply_patches=0); building vanilla upstream"
        PATCH_COUNT=0
        PATCH_SOURCE="disabled"
        PATCH_SHA="disabled"
        return
    fi

    if [ "${REFRESH_PATCHES}" != "0" ] && [ -x "${SCRIPT_DIR}/patches/refresh.sh" ]; then
        "${SCRIPT_DIR}/patches/refresh.sh" "${series}" \
            || echo "NOTE: patch refresh failed; falling back to the checked-in series"
    fi

    if [ ! -f "${dir}/series" ]; then
        echo "NOTE: no Percona patch series for shell ${series} (${dir}/series absent); building vanilla upstream"
        return
    fi

    local applied=0 p
    while read -r p _; do
        case "${p}" in ''|\#*) continue ;; esac
        [ -f "${dir}/${p}" ] || die "series lists ${p} but ${dir}/${p} is missing"
        echo "Applying ${series}/${p}"
        ( cd "${src_tree}" && patch -p1 -N --fuzz=3 < "${dir}/${p}" ) \
            || die "Percona patch ${p} failed to apply to ${SHELL_BRANCH}"
        applied=$((applied + 1))
    done < "${dir}/series"
    echo "Applied ${applied} Percona patch(es) for series ${series}"

    PATCH_COUNT="${applied}"
    if [ -f "${dir}/PROVENANCE" ]; then
        PATCH_SOURCE=$(awk -F': ' '/^source_url:/{print $2}' "${dir}/PROVENANCE")
        PATCH_SHA=$(awk -F': ' '/^combined_sha256:/{print $2}' "${dir}/PROVENANCE")
    fi
}

get_sources(){
    cd "${WORKDIR}" || die "no workdir"
    if [ "${SOURCE}" = 0 ]; then
        echo "Sources will not be downloaded"
        return 0
    fi
    rm -rf mysql-shell
    git clone "$SHELL_REPO" mysql-shell || die "mysql-shell clone failed"
    cd mysql-shell || die "no mysql-shell"
    git checkout "tags/${SHELL_BRANCH}" || die "cannot checkout tag ${SHELL_BRANCH}"
    REVISION=$(git rev-parse --short HEAD)
    cd "${WORKDIR}"

    apply_upstream_backports "${WORKDIR}/mysql-shell"
    apply_percona_patches "${WORKDIR}/mysql-shell"
    skip_rpath_for_bundled_binaries "${WORKDIR}/mysql-shell"

    build_jitexecutor "${WORKDIR}/mysql-shell"

    cd "${WORKDIR}/mysql-shell" || die "no mysql-shell"
    cmake . -DBUILD_SOURCE_PACKAGE=1 -G 'Unix Makefiles' \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo -DPACKAGE_YEAR="$(date +%Y)" \
        || die "source package cmake failed"
    cpack -G TGZ --config CPackSourceConfig.cmake || die "cpack failed"

    local upstream_tar version
    upstream_tar=$(ls mysql-shell-*-src.tar.gz | tail -n1)
    version=$(echo "${upstream_tar}" | sed -e 's/^mysql-shell-//' -e 's/-src\.tar\.gz$//')

    rm -rf "${WORKDIR}/repack" && mkdir -p "${WORKDIR}/repack"
    tar xzf "${upstream_tar}" -C "${WORKDIR}/repack"
    mv "${WORKDIR}/repack/mysql-shell-${version}-src" \
       "${WORKDIR}/repack/${PRODUCT}-${version}-src"
    ( cd "${WORKDIR}/repack" && tar czf "${WORKDIR}/${PRODUCT}-${version}-src.tar.gz" "${PRODUCT}-${version}-src" ) \
        || die "repack failed"
    rm -rf "${WORKDIR}/repack"

    mkdir -p "${WORKDIR}/source_tarball" "${CURDIR}/source_tarball"
    cp "${WORKDIR}/${PRODUCT}-${version}-src.tar.gz" "${WORKDIR}/source_tarball/"
    cp "${WORKDIR}/${PRODUCT}-${version}-src.tar.gz" "${CURDIR}/source_tarball/"

    SHELL_VERSION="${version}"
    {
        echo "REVISION=${REVISION}"
        echo "BRANCH_NAME=${BRANCH}"
        echo "PRODUCT=${PRODUCT}"
        echo "SHELL_BRANCH=${SHELL_BRANCH}"
        echo "VERSION=${SHELL_VERSION}"
        echo "RPM_RELEASE=${RPM_RELEASE}"
        echo "DEB_RELEASE=${DEB_RELEASE}"
        echo "PERCONA_PATCHES=${PATCH_COUNT:-0}"
        echo "PERCONA_PATCH_SOURCE=${PATCH_SOURCE:-none}"
        echo "PERCONA_PATCH_SHA256=${PATCH_SHA:-none}"
        echo "DESTINATION=${DESTINATION}"
        echo "UPLOAD=UPLOAD/${DESTINATION}/BUILDS/mysql-shell/mysql-shell-80/${SHELL_BRANCH}/$(date "+%Y%m%d-%H%M%S")"
    } >> "${VERSION_FILE}"

    cd "${WORKDIR}"
}

get_tar(){
    local dir="$1"
    local tarball
    tarball=$(find "${WORKDIR}/${dir}" "${CURDIR}/${dir}" -name "${PRODUCT}-*.tar.gz" 2>/dev/null | sort | tail -n1)
    [ -n "${tarball}" ] || die "no source tarball found in ${dir}"
    cp -f "${tarball}" "${WORKDIR}/" 2>/dev/null || true
    basename "${tarball}"
}

apply_branding_rpm(){
    local spec="$1"
    sed -i -e "s/^Name:\( *\)mysql-shell/Name:\1${PRODUCT}/" \
           -e "s/^Provides:\( *\)mysql-shell/Provides:\1${PRODUCT}/" \
           -e "s/^Obsoletes:\( *\)mysql-shell/Obsoletes:\1${PRODUCT}/" \
           "${spec}"
}

apply_branding_deb(){
    local debian_dir="$1"
    sed -i -e "s/^Source: mysql-shell/Source: ${PRODUCT}/" \
           -e "s/^Package: mysql-shell/Package: ${PRODUCT}/" \
           -e "s/^Conflicts: mysql-shell/Conflicts: ${PRODUCT}/" \
           -e "s/^Replaces: mysql-shell/Replaces: ${PRODUCT}/" \
           "${debian_dir}/control"
    sed -i "1s/^mysql-shell/${PRODUCT}/" "${debian_dir}/changelog"
    if [ -f "${debian_dir}/mysql-shell.install" ]; then
        mv "${debian_dir}/mysql-shell.install" "${debian_dir}/${PRODUCT}.install"
    fi
}

common_cmake_opts(){
    local opts="-DMYSQL_SOURCE_DIR=${DB_SOURCE_DIR} -DHAVE_PYTHON=1 -DBUNDLED_ANTLR_DIR=${ANTLR_PREFIX}"
    opts="${opts} -DBUNDLED_MYSQL_CONFIG_EDITOR=${DB_SOURCE_DIR}/bld/runtime_output_directory/mysql_config_editor"
    if [ "$WITH_JS" != "0" ]; then
        opts="${opts} -DJIT_EXECUTOR_LIB=${JITEXECUTOR_DIR}"
    fi
    if [ -d "${PYDEPS_DIR}" ]; then
        opts="${opts} -DPYTHON_DEPS=${PYDEPS_DIR}"
    fi
    echo "${opts}"
}

stage_python_deps(){
    if [ -d "${PYDEPS_DIR}" ]; then return; fi
    mkdir -p "${PYDEPS_DIR}"
    python3 -m pip install --no-compile --target "${PYDEPS_DIR}" certifi PyYAML \
        || python3 -m pip install --no-compile --break-system-packages --target "${PYDEPS_DIR}" certifi PyYAML \
        || echo "WARNING: could not stage python deps; bundled plugins will fail to load"
}

build_srpm(){
    if [ $SRPM = 0 ]; then
        echo "SRC RPM will not be created"
        return
    fi
    [ "x$OS" = "xrpm" ] || die "It is not possible to build src rpm here"

    cd "${WORKDIR}" || die "no workdir"
    local tarfile version srcdir
    tarfile=$(get_tar "source_tarball")
    version=$(echo "${tarfile}" | sed -e "s/^${PRODUCT}-//" -e 's/-src\.tar\.gz$//')

    rm -rf rpmbuild
    mkdir -p rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    rm -rf "${WORKDIR}/specsrc" && mkdir -p "${WORKDIR}/specsrc"
    tar xzf "${WORKDIR}/${tarfile}" -C "${WORKDIR}/specsrc"
    srcdir="${WORKDIR}/specsrc/${PRODUCT}-${version}-src"
    ( cd "${srcdir}" && cmake -S packaging/rpm -B "${WORKDIR}/rpm-init" \
        -DRPM_RELEASE="${RPM_RELEASE}" ) || die "rpm generator failed"
    [ -f "${srcdir}/mysql-shell.spec" ] || die "generator did not produce mysql-shell.spec"

    cp "${srcdir}/mysql-shell.spec" "rpmbuild/SPECS/${PRODUCT}.spec"
    apply_branding_rpm "rpmbuild/SPECS/${PRODUCT}.spec"
    rm -rf "${WORKDIR}/specsrc"

    cp -f "${WORKDIR}/${tarfile}" "${WORKDIR}/rpmbuild/SOURCES/"
    rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" \
        "rpmbuild/SPECS/${PRODUCT}.spec" || die "srpm build failed"

    mkdir -p "${WORKDIR}/srpm" "${CURDIR}/srpm"
    cp rpmbuild/SRPMS/*.src.rpm "${WORKDIR}/srpm/"
    cp rpmbuild/SRPMS/*.src.rpm "${CURDIR}/srpm/"
}

build_rpm(){
    if [ $RPM = 0 ]; then
        echo "RPM will not be created"
        return
    fi
    [ "x$OS" = "xrpm" ] || die "It is not possible to build rpm here"

    cd "${WORKDIR}" || die "no workdir"
    local srcrpm
    srcrpm=$(find "${WORKDIR}/srpm" "${CURDIR}/srpm" -name '*.src.rpm' 2>/dev/null | sort | tail -n1)
    [ -n "${srcrpm}" ] || die "no src.rpm found"

    local defines=(
        --define "_topdir ${WORKDIR}/rpmbuild"
        --define "dist ${DIST_TAG}"
        --define "static 1"
        --define "with_mysql_source ${DB_SOURCE_DIR}"
        --define "bundled_antlr ${ANTLR_PREFIX}"
        --define "bundled_mysql_config_editor ${DB_SOURCE_DIR}/bld/runtime_output_directory/mysql_config_editor"
        --define "_smp_mflags -j$(nproc)"
        --define "_lto_cflags %{nil}"
    )
    [ "$WITH_JS" != "0" ] && defines+=( --define "jit_executor_lib ${JITEXECUTOR_DIR}" )
    [ -d "${PYDEPS_DIR}" ] && defines+=( --define "python_deps ${PYDEPS_DIR}" )

    QA_RPATHS=$((0x0010)) rpmbuild "${defines[@]}" --rebuild "${srcrpm}" \
        || die "rpm build failed"

    mkdir -p "${WORKDIR}/rpm" "${CURDIR}/rpm"
    find "${WORKDIR}/rpmbuild/RPMS" -name '*.rpm' -exec cp {} "${WORKDIR}/rpm/" \;
    find "${WORKDIR}/rpmbuild/RPMS" -name '*.rpm' -exec cp {} "${CURDIR}/rpm/" \;
}

build_source_deb(){
    if [ $SDEB = 0 ]; then
        echo "source deb package will not be created"
        return
    fi
    [ "x$OS" = "xdeb" ] || die "It is not possible to build source deb here"

    cd "${WORKDIR}" || die "no workdir"
    local tarfile version srcdir
    tarfile=$(get_tar "source_tarball")
    version=$(echo "${tarfile}" | sed -e "s/^${PRODUCT}-//" -e 's/-src\.tar\.gz$//')

    rm -rf "${PRODUCT}-${version}-src"
    tar xzf "${tarfile}" || die "cannot unpack ${tarfile}"
    srcdir="${WORKDIR}/${PRODUCT}-${version}-src"
    cd "${srcdir}" || die "no ${srcdir}"

    # shellcheck disable=SC2046
    cmake -S packaging/debian -B "${WORKDIR}/deb-init" \
        -DDEBIAN_REVISION="${DEB_RELEASE}" \
        $(common_cmake_opts) || die "debian generator failed"

    cp -f "${WORKDIR}/${tarfile}" "${WORKDIR}/${PRODUCT}_${version}.orig.tar.gz" \
        || die "cannot stage the orig tarball"

    apply_branding_deb "${srcdir}/debian"

    dch -b -m -D "${OS_NAME}" --force-distribution \
        -v "${version}-${RPM_RELEASE}.${DEB_RELEASE}.${OS_NAME}" \
        "Update to upstream ${SHELL_BRANCH}" || true

    dpkg-buildpackage -S -us -uc -d || die "source deb build failed"

    cd "${WORKDIR}"
    mkdir -p "${WORKDIR}/source_deb" "${CURDIR}/source_deb"
    cp ./*.dsc ./*.tar.* "${WORKDIR}/source_deb/" 2>/dev/null || true
    cp ./*.dsc ./*.tar.* "${CURDIR}/source_deb/" 2>/dev/null || true
}

build_deb(){
    if [ $DEB = 0 ]; then
        echo "DEB will not be created"
        return
    fi
    [ "x$OS" = "xdeb" ] || die "It is not possible to build deb here"

    cd "${WORKDIR}" || die "no workdir"
    local dsc srcdir
    dsc=$(find "${WORKDIR}/source_deb" "${CURDIR}/source_deb" -name '*.dsc' 2>/dev/null | sort | tail -n1)
    [ -n "${dsc}" ] || die "no .dsc found"

    rm -rf "${WORKDIR}/debbuild" && mkdir -p "${WORKDIR}/debbuild"
    cp "${dsc}" "$(dirname "${dsc}")"/*.tar.* "${WORKDIR}/debbuild/"
    cd "${WORKDIR}/debbuild" || die "no debbuild"
    dpkg-source -x ./*.dsc || die "dpkg-source failed"
    srcdir=$(find . -maxdepth 1 -type d -name "${PRODUCT}-*" | head -n1)
    cd "${srcdir}" || die "no unpacked source"

    local upstream
    upstream=$(dpkg-parsechangelog -S Version | sed 's/-[^-]*$//')
    dch -b -m -D "${OS_NAME}" --force-distribution \
        -v "${upstream}-${RPM_RELEASE}.${DEB_RELEASE}.${OS_NAME}" \
        "Build for ${OS_NAME}" || die "cannot set the ${OS_NAME} package version"

    export DEB_BUILD_MAINT_OPTIONS="optimize=-lto"
    export DEB_CFLAGS_MAINT_STRIP="-flto=auto -ffat-lto-objects"
    export DEB_CXXFLAGS_MAINT_STRIP="-flto=auto -ffat-lto-objects"
    export DEB_LDFLAGS_MAINT_STRIP="-flto=auto -ffat-lto-objects"

    dpkg-buildpackage -us -uc -b || die "deb build failed"

    cd "${WORKDIR}/debbuild"
    mkdir -p "${WORKDIR}/deb" "${CURDIR}/deb"
    cp ./*.deb "${WORKDIR}/deb/" 2>/dev/null || true
    cp ./*.deb "${CURDIR}/deb/" 2>/dev/null || true
}

verify_checks(){
    local rc=0 out libexec

    out=$(mysqlsh --version 2>&1) || rc=1
    echo "  version: ${out}"
    case "${out}" in *"Ver "*) ;; *) echo "  FAIL: no version string"; rc=1 ;; esac

    out=$(mysqlsh --py -e 'print("PY", __import__("sys").version.split()[0])' 2>&1 | tail -1)
    echo "  python: ${out}"
    case "${out}" in PY\ *) ;; *) echo "  FAIL: python mode"; rc=1 ;; esac

    if [ "${WITH_JS}" != "0" ]; then
        out=$(mysqlsh --js -e 'println("JS " + [1,2,3].map(function(x){return x*7;}).join(","))' 2>&1 | tail -1)
        echo "  javascript: ${out}"
        case "${out}" in "JS 7,14,21") ;; *) echo "  FAIL: javascript mode"; rc=1 ;; esac
    fi

    out=$(mysqlsh --py -e 'import certifi, yaml; print("DEPS", yaml.__version__)' 2>&1 | tail -1)
    echo "  python deps: ${out}"
    case "${out}" in DEPS\ *) ;; *) echo "  FAIL: bundled python deps (plugins will not load)"; rc=1 ;; esac

    out=$(mysqlsh --py -e 'print("PLUGIN", type(util.debug).__name__)' 2>&1 | tail -1)
    echo "  plugins: ${out}"
    case "${out}" in PLUGIN\ *) ;; *) echo "  FAIL: bundled plugins did not load"; rc=1 ;; esac

    libexec=/usr/libexec/mysqlsh
    [ -d "${libexec}" ] || libexec=/usr/lib/mysqlsh
    if [ -x "${libexec}/mysqlbinlog" ]; then
        out=$("${libexec}/mysqlbinlog" --version 2>&1 | tail -1)
        echo "  mysqlbinlog: ${out}"
        case "${out}" in *"Ver "*) ;; *) echo "  FAIL: bundled mysqlbinlog"; rc=1 ;; esac
    fi
    if [ -x "${libexec}/mysql_config_editor" ]; then
        if "${libexec}/mysql_config_editor" print --all >/dev/null 2>&1; then
            echo "  mysql_config_editor: ok"
        else
            echo "  mysql_config_editor: FAIL (exit $?)"; rc=1
        fi
    fi

    out=$(ldd /usr/bin/mysqlsh 2>&1 | grep -c "not found")
    echo "  unresolved libraries: ${out}"
    [ "${out}" = "0" ] || { echo "  FAIL: mysqlsh has unresolved shared libraries"; rc=1; }

    return $rc
}

verify_package(){
    if [ "${VERIFY}" = "0" ]; then
        echo "Verification skipped"
        return
    fi
    if [ "${VERIFY_INPLACE}" = "1" ]; then
        echo "Verifying in place (NOT a clean environment)"
        verify_checks
        return $?
    fi

    command -v docker >/dev/null \
        || die "verification needs docker for a clean environment; use --verify_inplace=1 to override"

    local pkg image
    if [ "x$OS" = "xrpm" ]; then
        pkg=$(find "${CURDIR}/rpm" "${WORKDIR}/rpm" -name "${PRODUCT}-[0-9]*.rpm" 2>/dev/null | sort | tail -n1)
        image="oraclelinux:${RHEL}"
        [ "${OS_NAME}" = "amzn2023" ] && image="amazonlinux:2023"
    else
        pkg=$(find "${CURDIR}/deb" "${WORKDIR}/deb" -name "${PRODUCT}_*.deb" 2>/dev/null | sort | tail -n1)
        case "${OS_NAME}" in
            bookworm|trixie) image="debian:${OS_NAME}" ;;
            jammy) image="ubuntu:22.04" ;;
            noble) image="ubuntu:24.04" ;;
            *) image="ubuntu:latest" ;;
        esac
    fi
    [ -n "${pkg}" ] || die "no package found to verify"

    echo "Verifying ${pkg##*/} in a clean ${image} container"
    local script="${WORKDIR}/verify_in_container.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "WITH_JS=${WITH_JS}"
        declare -f verify_checks
        if [ "x$OS" = "xrpm" ]; then
            echo 'dnf -y install "$1" >/dev/null 2>&1 || { echo "  FAIL: package does not install"; exit 1; }'
        else
            echo 'export DEBIAN_FRONTEND=noninteractive'
            echo 'apt-get update -qq >/dev/null 2>&1'
            echo 'apt-get -y install "$1" >/dev/null 2>&1 || { echo "  FAIL: package does not install"; exit 1; }'
        fi
        echo 'verify_checks'
    } > "${script}"
    chmod +x "${script}"

    local cid rc
    cid=$(docker create "${image}" sleep infinity) || die "cannot create verification container"
    docker start "${cid}" >/dev/null || die "cannot start verification container"
    docker cp "${pkg}" "${cid}:/tmp/$(basename "${pkg}")" || die "cannot copy package into container"
    docker cp "${script}" "${cid}:/verify.sh" || die "cannot copy verify script into container"
    docker exec "${cid}" chmod +x /verify.sh
    docker exec "${cid}" /verify.sh "/tmp/$(basename "${pkg}")"
    rc=$?
    docker rm -f "${cid}" >/dev/null 2>&1
    if [ $rc -eq 0 ]; then
        echo "VERIFY: all checks passed (clean ${image})"
    else
        echo "VERIFY: FAILURES ABOVE (clean ${image})"
    fi
    return $rc
}

build_tarball(){
    if [ $TARBALL = 0 ]; then
        echo "Binary tarball will not be created"
        return
    fi
    cd "${WORKDIR}" || die "no workdir"
    local tarfile version srcdir
    tarfile=$(get_tar "source_tarball")
    version=$(echo "${tarfile}" | sed -e "s/^${PRODUCT}-//" -e 's/-src\.tar\.gz$//')

    rm -rf "${PRODUCT}-${version}-src"
    tar xzf "${tarfile}" || die "cannot unpack ${tarfile}"
    srcdir="${WORKDIR}/${PRODUCT}-${version}-src"
    cd "${srcdir}" || die "no ${srcdir}"

    mkdir -p bld && cd bld
    # shellcheck disable=SC2046
    cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX="${srcdir}/install" \
        $(common_cmake_opts) || die "tarball cmake failed"
    cmake --build . --parallel "$(nproc)" || die "tarball build failed"
    cmake --install . || die "tarball install failed"

    cd "${srcdir}"
    local name="${PRODUCT}-${version}-${OS_NAME}-${ARCH}"
    mv install "${name}"
    tar czf "${WORKDIR}/${name}.tar.gz" "${name}" || die "tarball packing failed"

    mkdir -p "${WORKDIR}/tarball" "${CURDIR}/tarball"
    cp "${WORKDIR}/${name}.tar.gz" "${WORKDIR}/tarball/"
    cp "${WORKDIR}/${name}.tar.gz" "${CURDIR}/tarball/"
}

CURDIR=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="${CURDIR}/mysql-shell.properties"
DESTINATION="${DESTINATION:-experimental}"
args=
WORKDIR=
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
TARBALL=0
INSTALL=0
VERIFY=0
VERIFY_INPLACE=0
OS_NAME=
ARCH=
OS=
REVISION=0

PRODUCT="percona-mysql-shell"
SHELL_REPO="https://github.com/mysql/mysql-shell.git"
SHELL_BRANCH="9.7.1"
REPO="https://github.com/percona/percona-server.git"
BRANCH="release-9.6.0-1"
RPM_RELEASE=1
DEB_RELEASE=1
WITH_JS=1
REFRESH_PATCHES=1
APPLY_PATCHES=1

ANTLR_VERSION_DEFAULT="4.13.1"
GRAALVM_VERSION_DEFAULT="23.0.1"
ANTLR_VERSION="${ANTLR_VERSION_DEFAULT}"
GRAALVM_VERSION="${GRAALVM_VERSION_DEFAULT}"
GRAAL_TAG="vm-24.1.1"
MAVEN_VERSION="3.9.9"

parse_arguments PICK-ARGS-FROM-ARGV "$@"

check_workdir
get_system

ANTLR_PREFIX="${WORKDIR}/antlr"
JITEXECUTOR_DIR="${WORKDIR}/jitexecutor"
PYDEPS_DIR="${WORKDIR}/pydeps"
case "$OS_NAME" in
    el8|el9) OS_TOOLSET="/opt/rh/gcc-toolset-14/enable" ;;
    *)       OS_TOOLSET="" ;;
esac

install_deps

NEED_BUILD=0
if [ "${RPM}" != 0 ] || [ "${DEB}" != 0 ] || [ "${TARBALL}" != 0 ]; then
    NEED_BUILD=1
fi

if [ "${NEED_BUILD}" = 1 ]; then
    enable_toolset
    stage_python_deps
    build_antlr
    get_database
    build_database
fi

get_sources
build_tarball
build_srpm
build_source_deb
build_rpm
build_deb
verify_package
