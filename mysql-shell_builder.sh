#!/bin/sh

shell_quote_string() {
    echo "$1" | sed -e 's,\([^a-zA-Z0-9/_.=-]\),\\\1,g'
}

usage () {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given :
        --builddir=DIR      Absolute path to the dir where all actions will be performed
        --get_sources       Source will be downloaded from github
        --build_src_rpm     If it is 1 src rpm will be built
        --build_source_deb  If it is 1 source deb package will be built
        --build_rpm         If it is 1 rpm will be built
        --build_deb         If it is 1 deb will be built
        --build_tarball     If it is 1 tarball will be built
        --install_deps      Install build dependencies(root previlages are required)
        --branch_db         Branch for build (Percona-Server or mysql-server)
        --repo              Repo for build (Percona-Server or mysql-server)
        --repo_protobuf     Protobuf repo for build and linkage
        --repo_mysqlshell   mysql-shell repo
        --mysqlshell_branch Branch for mysql-shell
        --protobuf_branch   Branch for protobuf
        --rpm_release       RPM version( default = 1)
        --deb_release       DEB version( default = 1)
        --help) usage ;;
Example $0 --builddir=/tmp/PS80 --get_sources=1 --build_src_rpm=1 --build_rpm=1
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
            # these get passed explicitly to mysqld
            --builddir=*) WORKDIR="$val" ;;
            --build_src_rpm=*) SRPM="$val" ;;
            --build_source_deb=*) SDEB="$val" ;;
            --build_rpm=*) RPM="$val" ;;
            --build_deb=*) DEB="$val" ;;
            --get_sources=*) SOURCE="$val" ;;
            --build_tarball=*) TARBALL="$val" ;;
            --branch_db=*) BRANCH="$val" ;;
            --repo=*) REPO="$val" ;;
            --install_deps=*) INSTALL="$val" ;;
            --repo_protobuf=*) PROTOBUF_REPO="$val" ;;
            --repo_mysqlshell=*) SHELL_REPO="$val" ;;
            --mysqlshell_branch=*) SHELL_BRANCH="$val" ;;
            --protobuf_branch=*) PROTOBUF_BRANCH="$val" ;;
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

check_workdir(){
    if [ "x$WORKDIR" = "x$CURDIR" ]
    then
        echo >&2 "Current directory cannot be used for building!"
        exit 1
    else
        if ! test -d "$WORKDIR"
        then
            echo >&2 "$WORKDIR is not a directory."
            exit 1
        fi
    fi
    return
}

add_percona_yum_repo(){
    if [ ! -f /etc/yum.repos.d/percona-dev.repo ]
    then
        curl -o /etc/yum.repos.d/percona-dev.repo https://jenkins.percona.com/yum-repo/percona-dev.repo
        sed -i 's:$basearch:x86_64:g' /etc/yum.repos.d/percona-dev.repo
    fi
    return
}

add_percona_apt_repo(){
    if [ ! -f /etc/apt/sources.list.d/percona-dev.list ]; then
        cat >/etc/apt/sources.list.d/percona-dev.list <<EOL
deb http://jenkins.percona.com/apt-repo/ @@DIST@@ main
deb-src http://jenkins.percona.com/apt-repo/ @@DIST@@ main
EOL
        sed -i "s:@@DIST@@:${DIST}:g" /etc/apt/sources.list.d/percona-dev.list
    fi
    wget -qO - http://jenkins.percona.com/apt-repo/8507EFA5.pub | apt-key add -
    return
}

get_cmake(){
    cd ${WORKDIR}
    local CMAKE_VERSION="$1"
    if [ "x$OS" = "xrpm" ]; then
        yum -y group install "Development Tools"
        yum -y remove cmake
        PATH=$PATH:/usr/local/bin
    else
        apt -y purge cmake*
        apt-get -y install build-essential
    fi
    wget -nv --no-check-certificate http://www.cmake.org/files/v${CMAKE_VERSION::(${#CMAKE_VERSION}-2)}/cmake-${CMAKE_VERSION}.tar.gz
    tar xf cmake-${CMAKE_VERSION}.tar.gz
    cd cmake-${CMAKE_VERSION}
    ./configure
    make
    make install
    hash -r
    cmake --version
    cd ${WORKDIR}
}

get_antlr4-runtime(){
    cd "${WORKDIR}"
    git clone https://github.com/antlr/antlr4.git
    cd antlr4/runtime/Cpp
    git checkout v4.10.1
    mkdir -p build && mkdir -p run && cd build
    cmake .. -DANTLR4_INSTALL=1 -DCMAKE_BUILD_TYPE=Release
    make -j8
    mkdir -p /opt/antlr4
    chmod a+w /opt/antlr4
    export DESTDIR=/opt/antlr4
    make install
}

get_protobuf(){
    MY_PATH=$(echo $PATH)
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL -le 7 ]; then
            source /opt/rh/devtoolset-7/enable
            source /opt/rh/rh-python38/enable
        fi
    fi
    cd "${WORKDIR}"
    rm -rf "${PROTOBUF_REPO}"
    git clone "${PROTOBUF_REPO}"
    retval=$?
    if [ $retval != 0 ]
    then
        echo "There were some issues during repo cloning from github. Please retry one more time"
    fi
    cd protobuf
    git clean -fd
    git reset --hard
    git checkout "$PROTOBUF_BRANCH"
    git submodule update --init --recursive
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL -le 7 ]; then
            source /opt/rh/devtoolset-7/enable
            source /opt/rh/rh-python38/enable
        fi
    fi
    cmake . -DCMAKE_CXX_STANDARD=14 -Dprotobuf_BUILD_SHARED_LIBS=ON -DABSL_PROPAGATE_CXX_STD=ON
    cmake --build .
    cmake --install .
    export PATH=$MY_PATH
    protoc --version
    cd ..
    ARCH=$(uname -m)
    if [ "x$ARCH" = "xaarch64" ]; then
        wget -nv https://github.com/protocolbuffers/protobuf/releases/download/v24.4/protoc-24.4-linux-aarch_64.zip
        unzip protoc-24.4-linux-aarch_64.zip
    else
        wget -nv https://github.com/protocolbuffers/protobuf/releases/download/v24.4/protoc-24.4-linux-x86_64.zip
        unzip protoc-24.4-linux-x86_64.zip
    fi
    cp bin/protoc /usr/local/bin
    cp -r include/* /usr/local/include
    return
}

get_database(){
    MY_PATH=$(echo $PATH)
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL -le 7 ]; then
            source /opt/rh/devtoolset-7/enable
            source /opt/rh/rh-python38/enable
        fi
    fi
    cd "${WORKDIR}"
    if [ -d percona-server ]; then
        rm -rf percona-server
    fi
    git clone "${REPO}"
    retval=$?
    if [ $retval != 0 ]
    then
        echo "There were some issues during repo cloning from github. Please retry one more time"
        exit 1
    fi
    repo_name=$(echo $REPO | awk -F'/' '{print $NF}' | awk -F'.' '{print $1}')
    cd $repo_name
    git clean -fd
    git reset --hard
    git checkout "$BRANCH"
    if [ $repo_name = "percona-server" ]; then
        git submodule init
        git submodule update
        patch -p0 < build-ps/rpm/mysql-5.7-sharedlib-rename.patch
        if [[ $RHEL = 8 && ${SHELL_BRANCH:2:1} = 1 ]]; then
            sed -i 's:gcc-toolset-12:gcc-toolset-11:g' CMakeLists.txt
        fi
        if [ "x$OS_NAME" = "xnoble" ]; then
            sed -i 's:D_FORTIFY_SOURCE=2:D_FORTIFY_SOURCE=3:g' CMakeLists.txt
        fi
    fi
    mkdir bld
    BOOST_VER="1.77.0"
    #wget https://boostorg.jfrog.io/artifactory/main/release/${BOOST_VER}/source/boost_${BOOST_VER//[.]/_}.tar.gz
    wget -nv --no-check-certificate https://downloads.percona.com/downloads/packaging/boost/boost_${BOOST_VER//[.]/_}.tar.gz
    tar -xzf boost_${BOOST_VER//[.]/_}.tar.gz
    mkdir -p $WORKDIR/boost
    mv boost_${BOOST_VER//[.]/_}/* $WORKDIR/boost/
    rm -rf boost_${BOOST_VER//[.]/_} boost_${BOOST_VER//[.]/_}.tar.gz
    cd bld
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL = 7 ]; then
            source /opt/rh/devtoolset-11/enable
        fi
        #if [ $RHEL = 8 ]; then
        #    if [ ${SHELL_BRANCH:2:1} = 1 ]; then
        #        source /opt/rh/gcc-toolset-11/enable
        #    else
        #        source /opt/rh/gcc-toolset-12/enable
        #    fi
        #fi
        if [ $RHEL = 6 ]; then
            cmake .. -DENABLE_DOWNLOADS=1 -DWITH_SSL=/usr/local/openssl11 -Dantlr4-runtime_DIR=/opt/antlr4/usr/local/lib64/cmake/antlr4-runtime -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=system -DWITH_ZLIB=bundled -DWITH_COREDUMPER=OFF -DWITH_CURL=system
        else
            if [ $RHEL = 10 ]; then
                cmake .. -DCMAKE_CXX_COMPILER=/usr/bin/gcc -DENABLE_DOWNLOADS=1 -DWITH_SSL=system -Dantlr4-runtime_DIR=/opt/antlr4/usr/local/lib64/cmake/antlr4-runtime -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=system -DWITH_ZLIB=bundled -DWITH_COREDUMPER=OFF -DWITH_CURL=system -DALLOW_NO_SSE42=1
            else
                cmake .. -DENABLE_DOWNLOADS=1 -DWITH_SSL=system -Dantlr4-runtime_DIR=/opt/antlr4/usr/local/lib64/cmake/antlr4-runtime -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=system -DWITH_ZLIB=bundled -DWITH_COREDUMPER=OFF -DWITH_CURL=system -DALLOW_NO_SSE42=1
            fi
        fi
    else
        cmake .. -DENABLE_DOWNLOADS=1 -DWITH_SSL=system -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=system -DWITH_ZLIB=bundled -DWITH_COREDUMPER=OFF -DWITH_CURL=system -DALLOW_NO_SSE42=1
    fi

    cmake --build . --target authentication_oci_client
    cmake --build . --target mysqlclient
    cmake --build . --target mysqlxclient
    if [ ${SHELL_BRANCH:2:1} = 0 ]; then
        cmake --build . --target authentication_fido_client
    fi
    cmake --build . --target authentication_ldap_sasl_client
    cmake --build . --target authentication_kerberos_client
    if [ ${SHELL_BRANCH:2:1} != 0 ]; then
        cmake --build . --target authentication_webauthn_client
    fi
    cd $WORKDIR
    export PATH=$MY_PATH
    return
}

get_GraalVM(){
    if [ -f /etc/redhat-release ]; then
        RHEL=$(rpm --eval %rhel)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
        OS_NAME="el$RHEL"
        OS="rpm"
    else
        export ARCH=$(uname -m)
        export OS_NAME="$(lsb_release -sc)"
        export OS="deb"
    fi
    if [ "x$OS" = "xrpm" ]; then
        yum install -y zlib-devel
    else
        apt install -y zlib1g-dev
    fi

    cd ${WORKDIR}
    if [ x"$ARCH" = "xx86_64" ]; then
        wget -nv -q --no-check-certificate https://downloads.percona.com/downloads/packaging/polyglot-nativeapi-native-library-lje_23.0.1_x86_64_el8.tar.gz
        tar -xzf polyglot-nativeapi-native-library-lje_23.0.1_x86_64_el8.tar.gz
        rm -rf polyglot-nativeapi-native-library-lje_23.0.1_x86_64_el8.tar.gz
    else
#        if [ $RHEL = "8" ]; then
            wget -nv -q --no-check-certificate https://downloads.percona.com/downloads/packaging/polyglot-nativeapi-native-library-lje_23.0.1_aarch64_el8.tar.gz
            tar -xzf polyglot-nativeapi-native-library-lje_23.0.1_aarch64_el8.tar.gz
            rm -rf polyglot-nativeapi-native-library-lje_23.0.1_aarch64_el8.tar.gz
#        else
#            wget -q --no-check-certificate https://downloads.percona.com/downloads/packaging/polyglot-nativeapi-native-library-lje_23.0.1_aarch64_noble.tar.gz
#            tar -xzf polyglot-nativeapi-native-library-lje_23.0.1_aarch64_noble.tar.gz
#            rm -rf polyglot-nativeapi-native-library-lje_23.0.1_aarch64_noble.tar.gz
#        fi
    fi

    mkdir /tmp/polyglot-nativeapi-native-library
    cp -r polyglot-nativeapi-native-library/* /tmp/polyglot-nativeapi-native-library
}

get_v8(){
    RHEL="$(rpm --eval %rhel)"
    DIST="$(lsb_release -sc)"
    cd ${WORKDIR}
    if [ x"$ARCH" = "xx86_64" ]; then
        wget -nv -q --no-check-certificate https://downloads.percona.com/downloads/packaging/v8_12.0.267.8.tar.gz
        tar -xzf v8_12.0.267.8.tar.gz
        rm -rf v8_12.0.267.8.tar.gz
    else
        if [ $RHEL = "8" ]; then
            wget -q --no-check-certificate https://downloads.percona.com/downloads/packaging/v8_10.9.194.10-arm64.tar.gz
            tar -xzf v8_10.9.194.10-arm64.tar.gz
            rm -rf v8_10.9.194.10-arm64.tar.gz
        elif [ "x${DIST}" = "xfocal" -o "x${DIST}" = "xbullseye" ]; then
            wget -q --no-check-certificate https://downloads.percona.com/downloads/packaging/v8_10.9.194.10-arm64.tar.gz
            tar -xzf v8_10.9.194.10-arm64.tar.gz
            rm -rf v8_10.9.194.10-arm64.tar.gz
        else
            wget -q --no-check-certificate https://downloads.percona.com/downloads/packaging/v8_12.0.267.8-arm64.tar.gz
            tar -xzf v8_12.0.267.8-arm64.tar.gz
            rm -rf v8_12.0.267.8-arm64.tar.gz
        fi
    fi
}

get_sources(){
    #(better to execute on ubuntu)
    cd "${WORKDIR}"
    if [ "${SOURCE}" = 0 ]
    then
        echo "Sources will not be downloaded"
        return 0
    fi
    build_ssh
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL != 8 ]; then
            source /opt/rh/devtoolset-7/enable
            source /opt/rh/rh-python38/enable
        fi
    fi
    git clone "$SHELL_REPO"
    retval=$?
    if [ $retval != 0 ]
    then
        echo "There were some issues during repo cloning from github. Please retry one more time"
        exit 1
    fi
    REVISION=$(git rev-parse --short HEAD)
    cd mysql-shell
    if [ ! -z "$SHELL_BRANCH" ]
    then
        git reset --hard
        git clean -xdf
        git checkout tags/"$SHELL_BRANCH"
    fi
    if [ -z "${DESTINATION:-}" ]; then
        export DESTINATION=experimental
    fi
    echo "REVISION=${REVISION}" >> ../mysql-shell.properties
    BRANCH_NAME="${BRANCH}"
    echo "BRANCH_NAME=${BRANCH_NAME}" >> ../mysql-shell.properties
    export PRODUCT='mysql-shell'
    echo "PRODUCT=mysql-shell" >> ../mysql-shell.properties
    echo "SHELL_BRANCH=${SHELL_BRANCH}" >> ../mysql-shell.properties
    echo "RPM_RELEASE=${RPM_RELEASE}" >> ../mysql-shell.properties
    echo "DEB_RELEASE=${DEB_RELEASE}" >> ../mysql-shell.properties

    echo "DESTINATION=${DESTINATION}" >> ../mysql-shell.properties
    TIMESTAMP=$(date "+%Y%m%d-%H%M%S")
    echo "UPLOAD=UPLOAD/${DESTINATION}/BUILDS/mysql-shell/mysql-shell-80/${SHELL_BRANCH}/${TIMESTAMP}" >> ../mysql-shell.properties
    #sed -i 's:STRING_PREPEND:#STRING_PREPEND:g' CMakeLists.txt
    #sed -i 's:3.8:3.6:g' packaging/debian/CMakeLists.txt
    #sed -i 's:3.8:3.6:g' packaging/rpm/mysql-shell.spec.in
    #if [ ${SHELL_BRANCH:2:1} = 0 ]; then
    #    curl -L -o exeutils.patch https://github.com/percona/mysql-shell-packaging/raw/refs/heads/main/exeutils.cmake-8.0.42.patch
    #else
    #    curl -L -o exeutils.patch https://github.com/percona/mysql-shell-packaging/raw/refs/heads/main/exeutils.cmake-8.4.4.patch
    #fi
    #patch -d cmake < exeutils.patch
    #if [ ${SHELL_BRANCH:2:1} = 0 && ${SHELL_BRANCH:4:2} < 40 ]; then
    #    sed -i 's:execute_patchelf:# execute_patchelf:g' cmake/exeutils.cmake
    #else
        sed -i 's:set(\"\${ARG_OUT_COMMAND}\" ${PATCHELF_EXECUTABLE}:#set(\"\${ARG_OUT_COMMAND}\" ${PATCHELF_EXECUTABLE}:g' cmake/exeutils.cmake
        sed -i '/create a dependency, so that files/i \if(NOT TARGET \"${COPY_TARGET}\")' cmake/exeutils.cmake
        #sed -i '0,/add_custom_target/{s/add_custom_target/if(NOT TARGET \"${COPY_TARGET}\")\nadd_custom_target/}' cmake/exeutils.cmake
        sed -i '/APPEND COPIED_BINARIES/a endif()' cmake/exeutils.cmake
    #fi
    sed -i 's:quilt:native:g' packaging/debian/source/format
    
    if [ "x$OS" = "xdeb" ]; then
        cd packaging/debian/
        cmake . -DBUNDLED_ANTLR_DIR="/opt/antlr4/usr/local" -DBUNDLED_PYTHON_DIR="/usr/local/python312"
        cd ../../
        cmake . -DBUILD_SOURCE_PACKAGE=1 -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_SSL=system -DPACKAGE_YEAR=$(date +%Y) -DHAVE_PYTHON=1 -DBUNDLED_PYTHON_DIR="/usr/local/python312" -DPYTHON_INCLUDE_DIRS="/usr/local/python312/include/python3.12" -DPYTHON_LIBRARIES="/usr/local/python312/lib/libpython3.12.so" -DBUNDLED_ANTLR_DIR="/opt/antlr4/usr/local"
    else
        cmake . -DBUILD_SOURCE_PACKAGE=1 -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_SSL=system -DPACKAGE_YEAR=$(date +%Y) -DBUNDLED_ANTLR_DIR="/opt/antlr4/usr/local"
    fi
    sed -i 's/-src//g' CPack*
    cpack -G TGZ --config CPackSourceConfig.cmake
    mkdir $WORKDIR/source_tarball
    mkdir $CURDIR/source_tarball
    TAR_NAME=$(ls mysql-shell*.tar.gz)
    cp mysql-shell*.tar.gz $WORKDIR/source_tarball/percona-${TAR_NAME}
    cp mysql-shell*.tar.gz $CURDIR/source_tarball/percona-${TAR_NAME}
    cd $CURDIR
    rm -rf mysql-shell
    return
}

build_oci_sdk(){
    git clone https://github.com/oracle/oci-python-sdk.git
    cd oci-python-sdk/
    git checkout v2.6.2
    if [ "x$OS_NAME" = "buster" ]; then
        $PWD/.local/bin/virtualenv oci_sdk
    else
        virtualenv oci_sdk
    fi
    . oci_sdk/bin/activate
    if [ "x$OS" = "xdeb" ]; then
        if [ "x${DIST}" = "xbuster" -o "x${DIST}" = "xfocal" -o "x${DIST}" = "xbookworm" -o "x${DIST}" = "xnoble" ]; then
            pip3 install -r requirements.txt
            pip3 install -e .
        else
            pip install --upgrade pip
            pip install -r requirements.txt
            pip install -e .
        fi
    else
        if [ $RHEL = 7 ]; then
            pip install --upgrade pip
            pip install -r requirements.txt
            pip install certifi || true
            pip install -e .
        else
                pip3 install -r requirements.txt
                pip3 install -e .
                pip3 install certifi || true
                pip3 uninstall -y cffi
        fi
    fi
    rm -f /oci_sdk/.gitignore
    mv oci_sdk ${WORKDIR}/
    cd ../
}

get_system(){
    if [ -f /etc/redhat-release ]; then
        RHEL=$(rpm --eval %rhel)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
        OS_NAME="el$RHEL"
        OS="rpm"
    else
        export ARCH=$(uname -m)
        export OS_NAME="$(lsb_release -sc)"
        export OS="deb"
    fi
    GLIBC_VERSION=$(ldd --version | head -1 | awk {'print substr($4, 0, 4)'})
    return
}

build_openssl(){
    if [ -n "$1" ]; then
        version="$1"
    else
        version="1_1_1q"
    fi
    cd ${WORKDIR}
    if [ ${version:0:1} -eq "1" ]; then
        fullversion="OpenSSL_${version}"
    else
        fullversion="openssl-${version}"
    fi
    if [ ${version:0:1} -eq "3" ]; then
        wget -nv --no-check-certificate https://github.com/openssl/openssl/releases/download/${fullversion}/${fullversion}.tar.gz
        tar -xvzf ${fullversion}.tar.gz
        cd ${fullversion}/
    else
        wget -nv --no-check-certificate https://github.com/openssl/openssl/archive/${fullversion}.tar.gz
        tar -xvzf ${fullversion}.tar.gz
        cd openssl-${fullversion}/
    fi
    ./config --prefix=/usr/local --openssldir=/usr/local/openssl shared zlib
    make -j4
    make install
    cd ../
    rm -rf ${fullversion}.tar.gz openssl-${fullversion}
    echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl-${version}.conf
    echo "/usr/local/openssl/lib64" >> /etc/ld.so.conf.d/openssl-${version}.conf
    #echo "include ld.so.conf.d/*.conf" >> /etc/ld.so.conf
    ldconfig -v
    mv -f /bin/openssl /bin/openssl.backup
    ln -s /usr/local/openssl/bin/openssl /bin/openssl
    openssl version
}

build_python(){
    get_system
    cd ${WORKDIR}
    if [ "x$OS" = "xrpm" ]; then
        pversion="3.9.22"
    else # OS=deb
        pversion="3.12.10"
    fi
    arraypversion=(${pversion//\./ })
    wget -nv --no-check-certificate https://www.python.org/ftp/python/${pversion}/Python-${pversion}.tgz
    tar xzf Python-${pversion}.tgz
    cd Python-${pversion}
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL -le 7 ]; then
            sed -i 's/SSL=\/usr\/local\/ssl/SSL=\/usr\/local\/openssl/g' Modules/Setup
        fi
        if [ $RHEL -le 8 -o $RHEL = 9 -o $RHEL = 10 ]; then
            sed -i '210 s/^##*//' Modules/Setup
            sed -i '214,217 s/^##*//' Modules/Setup
        #else
        #    sed -i '206 s/^##*//' Modules/Setup
        #    sed -i '210,213 s/^##*//' Modules/Setup
        fi
    fi
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL -le 7 ]; then
            ./configure --prefix=/usr/local/python39 --with-openssl=/usr/local/openssl --with-system-ffi --enable-shared LDFLAGS=-Wl,-rpath=/usr/local/python39/lib
        elif [ $RHEL = 9 -o $RHEL = 10 ]; then
            ./configure --prefix=/usr/local/python39 --with-openssl=/usr/lib64 --with-system-ffi --enable-shared LDFLAGS=-Wl,-rpath=/usr/local/python39/lib
        else # el8
            ./configure --prefix=/usr/local/python39 --with-system-ffi --enable-shared LDFLAGS=-Wl,-rpath=/usr/local/python39/lib
        fi
    else
        ./configure --prefix=/usr/local/python312 --with-system-ffi --enable-shared LDFLAGS=-Wl,-rpath=/usr/local/python312/lib
    fi
    make
    make altinstall
    bash -c "echo /usr/local/python3${arraypversion[1]}/lib > /etc/ld.so.conf.d/python-3.${arraypversion[1]}.conf"
    bash -c "echo /usr/local/python3${arraypversion[1]}/lib64 >> /etc/ld.so.conf.d/python-3.${arraypversion[1]}.conf"
    ldconfig -v
    if [[ "x$OS_NAME" = "xbookworm" || "x$OS_NAME" = "xnoble" ]]; then
        update-alternatives --remove-all python3
        update-alternatives --install /usr/bin/python3 python3 /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} 100
        update-alternatives --remove-all pip3
        update-alternatives --install /usr/bin/pip3 pip3 /usr/local/python3${arraypversion[1]}/bin/pip3 100
        cp /usr/local/python312/lib/libpython3.12.so.1.0 /usr/lib/x86_64-linux-gnu/
        sed -i 's:/usr/bin/python3 -Es:/usr/bin/python3.12 -Es:' /usr/bin/lsb_release
        if [ "x$OS_NAME" = "xbionic" ]; then
            sed -i 's:/usr/bin/python3 -Es:/usr/bin/python3.6 -Es:' /usr/bin/lsb_release
        fi
        if [ "x$OS_NAME" = "xbuster" ]; then
            sed -i 's:/usr/bin/python3 -Es:/usr/bin/python3.7 -Es:' /usr/bin/lsb_release
        fi
    fi
    cd ../
    python3 -m site
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m site
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install --upgrade pip
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install pyyaml
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install certifi
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install virtualenv
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install --upgrade virtualenv
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install cryptography
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install oci
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install setuptools
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip install --upgrade setuptools
    /usr/local/python3${arraypversion[1]}/bin/python3.${arraypversion[1]} -m pip uninstall -y cffi
    find / -type f -name "*.whl" -exec rm -vf {} \;
}

install_deps() {
    if [ $INSTALL = 0 ]
    then
        echo "Dependencies will not be installed"
        return;
    fi
    if [ ! $( id -u ) -eq 0 ]
    then
        echo "It is not possible to instal dependencies. Please run as root"
        exit 1
    fi
    CURPLACE=$(pwd)
    if [ "x$OS" = "xrpm" ]; then
        RHEL=$(rpm --eval %rhel)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
        if [ $RHEL = 8 -o $RHEL = 7 ]; then
            if [ x"$ARCH" = "xx86_64" ]; then
                sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
                sed -i 's|#\s*baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
            else
                dnf -y install yum
                yum -y install yum-utils
                yum-config-manager --enable ol8_codeready_builder
            fi
        fi
        if [ $RHEL = 9 -o $RHEL = 10 ]; then
            dnf -y install yum
            yum -y install yum-utils
            yum-config-manager --enable ol${RHEL}_codeready_builder
        else
            if [ x"$ARCH" = "xx86_64" -a x"$RHEL" = "x8" ]; then
                # add_percona_yum_repo
                curl -O https://downloads.percona.com/downloads/packaging/rpcgen-1.4-1.fc29.x86_64.rpm
                curl -O https://downloads.percona.com/downloads/packaging/gperf-3.1-6.el8.x86_64.rpm
                curl -O https://downloads.percona.com/downloads/packaging/MySQL-python-1.3.6-3.el8.x86_64.rpm
                yum -y install ./rpcgen-1.4-1.fc29.x86_64.rpm
                yum -y install ./gperf-3.1-6.el8.x86_64.rpm
                yum -y install ./MySQL-python-1.3.6-3.el8.x86_64.rpm
            fi
        fi
        if [ $RHEL = 8 -o $RHEL = 9 -o $RHEL = 10 ]; then
            yum -y install dnf-plugins-core
            if [ "x$RHEL" = "x8" ]; then
                yum config-manager --set-enabled PowerTools || yum config-manager --set-enabled powertools
                subscription-manager repos --enable codeready-builder-for-rhel-${RHEL}-x86_64-rpms
            fi
            if [ $RHEL != 10 ]; then
                yum -y install epel-release
            fi
            yum -y install git wget
            yum -y install binutils tar rpm-build rsync bison glibc glibc-devel libstdc++-devel libtirpc-devel make openssl-devel pam-devel perl perl-JSON perl-Memoize
            yum -y install automake autoconf jemalloc jemalloc-devel
            yum -y install libaio-devel ncurses-devel numactl-devel readline-devel time
            yum -y install rpcgen
            yum -y install automake m4 libtool zip rpmlint
            yum -y install gperf ncurses-devel perl
            yum -y install libcurl-devel
            yum -y install perl-Env perl-Data-Dumper perl-JSON perl-Digest perl-Digest-MD5 perl-Digest-Perl-MD5 || true
            yum -y install libicu-devel git
            yum -y install python3-virtualenv || true
            yum -y install openldap-devel
            yum -y install cyrus-sasl-devel cyrus-sasl-scram
            yum -y install cmake
            yum -y install libcmocka-devel
            yum -y install libffi-devel
            yum -y install libuuid-devel pkgconf-pkg-config
            yum -y install patchelf
            yum -y install libudev-devel
            if [ "x$RHEL" = "x8" ]; then
                yum -y install MySQL-python
                if [ x"$ARCH" = "xx86_64" ]; then
                    yum -y install centos-release-stream
                    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
                    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
                fi
#                if [ ${SHELL_BRANCH:2:1} = 0 ]; then
#                    yum -y install gcc-toolset-11-gcc gcc-toolset-11-gcc-c++ gcc-toolset-11-binutils # gcc-toolset-10-annobin
#                    yum -y install gcc-toolset-11-annobin-annocheck gcc-toolset-11-annobin-plugin-gcc
#                    update-alternatives --install /usr/bin/gcc gcc /opt/rh/gcc-toolset-11/root/bin/gcc 80
#                    update-alternatives --install /usr/bin/g++ g++ /opt/rh/gcc-toolset-11/root/bin/g++ 80
#                else
                    yum -y install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils # gcc-toolset-10-annobin
                    yum -y install gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc
                    update-alternatives --install /usr/bin/gcc gcc /opt/rh/gcc-toolset-12/root/bin/gcc 80
                    update-alternatives --install /usr/bin/g++ g++ /opt/rh/gcc-toolset-12/root/bin/g++ 80
#                fi
                if [ x"$ARCH" = "xx86_64" ]; then
                    yum -y remove centos-release-stream
                fi
                dnf install -y libarchive #required for build_ssh if cmake =< 8.20.2-4
                # bug https://github.com/openzfs/zfs/issues/14386
                if [ ${SHELL_BRANCH:2:1} = 0 ]; then
                    pushd /opt/rh/gcc-toolset-11/root/usr/lib/gcc/${ARCH}-redhat-linux/11/plugin/
                else
                    pushd /opt/rh/gcc-toolset-12/root/usr/lib/gcc/${ARCH}-redhat-linux/12/plugin/
                fi
                ln -s annobin.so gcc-annobin.so
                popd
            fi
            if [ $RHEL = 9 -o $RHEL = 10 ]; then
                yum -y install krb5-devel
                yum -y install zlib zlib-devel
                if [ $RHEL = 9 ]; then
                    yum -y install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc
                    pushd /opt/rh/gcc-toolset-12/root/usr/lib/gcc/${ARCH}-redhat-linux/12/plugin/
                        ln -s annobin.so gcc-annobin.so
                    popd
                else
                    yum -y install gcc gcc-c++
                fi
            fi
            build_python
            #build_oci_sdk
        else
            yum -y install git
            yum -y install gcc openssl-devel bzip2-devel libffi libffi-devel
            yum -y install https://repo.percona.com/prel/yum/release/latest/RPMS/x86_64/percona-release-1.0-27.noarch.rpm
            yum -y install epel-release
            yum -y install git numactl-devel rpm-build gcc-c++ gperf ncurses-devel perl readline-devel openssl-devel jemalloc 
            yum -y install time zlib-devel libaio-devel bison cmake pam-devel libeatmydata jemalloc-devel
            yum -y install perl-Time-HiRes libcurl-devel openldap-devel unzip wget libcurl-devel
            yum -y install perl-Env perl-Data-Dumper perl-JSON MySQL-python perl-Digest perl-Digest-MD5 perl-Digest-Perl-MD5 || true
            yum -y install libicu-devel automake m4 libtool python-devel zip rpmlint
            yum -y install libcmocka-devel
            yum -y install libuuid-devel pkgconf-pkg-config
            yum -y install patchelf
            until yum -y install centos-release-scl; do
                echo "waiting"
                sleep 1
            done
            if [ "x$RHEL" = "x7" ]; then
                sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-SCLo-*
                sed -i 's|#\s*baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-SCLo-*
                yum -y --enablerepo=centos-sclo-rh-testing install devtoolset-11 devtoolset-11-gcc-c++ devtoolset-11-binutils devtoolset-11-valgrind devtoolset-11-valgrind-devel devtoolset-11-libatomic-devel
                yum -y --enablerepo=centos-sclo-rh-testing install devtoolset-11-libasan-devel devtoolset-11-libubsan-devel
                scl enable devtoolset-11 bash
                rm -f /usr/bin/cmake
                cp -p /usr/bin/cmake3 /usr/bin/cmake
            fi
            yum -y install gcc-c++ devtoolset-7-gcc* devtoolset-7-binutils cmake3
            yum -y install rh-python38 rh-python38-devel rh-python38-pip
            yum -y install cyrus-sasl-devel cyrus-sasl-scram
            yum -y install krb5-devel

            alternatives --install /usr/local/bin/cmake cmake /usr/bin/cmake 10 \
--slave /usr/local/bin/ctest ctest /usr/bin/ctest \
--slave /usr/local/bin/cpack cpack /usr/bin/cpack \
--slave /usr/local/bin/ccmake ccmake /usr/bin/ccmake 
            alternatives --install /usr/local/bin/cmake cmake /usr/bin/cmake3 20 \
--slave /usr/local/bin/ctest ctest /usr/bin/ctest3 \
--slave /usr/local/bin/cpack cpack /usr/bin/cpack3 \
--slave /usr/local/bin/ccmake ccmake /usr/bin/ccmake3 
            alternatives --display cmake

            source /opt/rh/rh-python38/enable
            python3 -m pip install --upgrade pip
            python3 -m pip install pyyaml
            python3 -m pip install certifi
            python3 -m pip install virtualenv
            python3 -m pip install setuptools
            python3 -m pip install --upgrade setuptools
        fi
        if [ "x$RHEL" = "x6" ]; then
            percona-release enable tools testing
            yum -y install Percona-Server-shared-56
            yum install -y percona-devtoolset-gcc percona-devtoolset-binutils python-devel percona-devtoolset-gcc-c++ percona-devtoolset-libstdc++-devel percona-devtoolset-valgrind-devel
            sed -i "668s:(void:(const void:" /usr/include/openssl/bio.h
            build_openssl
            build_python
        fi
        if [ "x$RHEL" = "x7" ]; then
            sed -i '/#!\/bin\/bash/a exit 0' /usr/lib/rpm/brp-python-bytecompile
            #build_openssl
            build_python
	    sed -i 's:python :python2 :' /usr/bin/yum
	    sed -i 's:python:python2 :' /usr/libexec/urlgrabber-ext-down
        fi
        if [ "x$RHEL" = "x6" ]; then
            pip3 install --upgrade pip
            pip3 install virtualenv
            build_oci_sdk
        elif [ "x$RHEL" = "x7" ]; then
            python3 -m pip install --upgrade pip
            python3 -m pip install pyyaml
            python3 -m pip install certifi
            python3 -m pip install virtualenv
            python3 -m pip install setuptools
            python3 -m pip install --upgrade setuptools
            build_oci_sdk
            #get_cmake 3.14.7
            source /opt/rh/devtoolset-7/enable
            g++ --version
        fi
    else #========================================> OS: deb
        apt-get update
        sleep 20
        apt-get -y install dirmngr || true
        apt-get -y install lsb-release wget curl gnupg2
        wget --no-check-certificate https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb && dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
        percona-release enable tools testing
        export DEBIAN_FRONTEND="noninteractive"
        export DIST="$(lsb_release -sc)"
        until apt-get update; do
            sleep 10
            echo "waiting"
        done
        apt-get -y purge eatmydata || true
        apt-get -y install psmisc
        apt-get -y install libsasl2-modules:amd64 || apt-get -y install libsasl2-modules
        apt-get -y install dh-systemd || true
        apt-get -y install curl bison cmake perl libaio-dev libldap2-dev libwrap0-dev gdb unzip gawk
        apt-get -y install lsb-release libmecab-dev libncurses5-dev libreadline-dev libpam-dev zlib1g-dev libcurl4-openssl-dev
        apt-get -y install libldap2-dev libnuma-dev libjemalloc-dev libc6-dbg valgrind libjson-perl libsasl2-dev
        apt-get -y install libeatmydata
        apt-get -y install libmecab2 mecab mecab-ipadic libicu-dev
        apt-get -y install build-essential devscripts doxygen doxygen-gui graphviz rsync libprotobuf-dev protobuf-compiler
        apt-get -y install cmake autotools-dev autoconf automake build-essential devscripts debconf debhelper fakeroot libtool
        apt-get -y install libicu-dev pkg-config zip
        apt-get -y install libtirpc
        apt-get -y install patchelf
        apt-get -y install libsasl2-dev libsasl2-modules-gssapi-mit
        apt-get -y install libkrb5-dev
        apt-get -y install libz-dev libgcrypt-dev libssl-dev libcmocka-dev g++
        apt-get -y install libantlr4-runtime-dev
        apt-get -y install uuid-dev
        apt-get -y install pkg-config
        apt-get -y install libudev-dev
        apt-get -y install libbsd-dev
        if [ x"${DIST}" = "xfocal" -o "x${DIST}" = "xbookworm" ]; then
            apt-get -y install gcc-10 g++-10
            update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100 --slave /usr/bin/g++ g++ /usr/bin/g++-10 --slave /usr/bin/gcov gcov /usr/bin/gcov-10
        else
            apt-get -y install gcc g++
        fi
        if [ "x${DIST}" = "xbullseye" ]; then
            apt-get -y install libssh2-1-dev
        fi
        if [ "x${DIST}" = "xbookworm" -o "x${DIST}" = "xnoble" ]; then
            apt-get -y install python3-virtualenv libtirpc-dev
        fi
        if [ "x${DIST}" = "xstretch" ]; then
            echo "deb http://ftp.us.debian.org/debian/ jessie main contrib non-free" >> /etc/apt/sources.list
            apt-get update
            apt-get -y install gcc-4.9 g++-4.9
            sed -i 's;deb http://ftp.us.debian.org/debian/ jessie main contrib non-free;;' /etc/apt/sources.list
            apt-get update
        elif [ "x${DIST}" = "xfocal" -o "x${DIST}" = "xjammy" -o "x${DIST}" = "xnoble" -o "x${DIST}" = "xbookworm" ]; then
            apt-get -y install python3-mysqldb
        else
            apt-get -y install python-mysqldb
            apt-get -y install gcc-4.8 g++-4.8
        fi
        apt-get -y install python python-dev
        apt-get -y install python27-dev
        apt-get -y install python3 python3-pip
        apt-get -y install python3-dev || true
        apt-get -y install libffi-dev || true
        PIP_UTIL="pip3"
        if [ "x${DIST}" = "xnoble" -o "x${DIST}" = "xbookworm" ]; then
            apt-get -y install pipx
            PIP_UTIL="pipx"
        fi
        if [ "x${DIST}" = "xxenial" ]; then
            update-alternatives --install /usr/bin/python python /usr/bin/python3 1
            update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1
            curl  https://bootstrap.pypa.io/pip/2.7/get-pip.py -o get-pip.py
            python get-pip.py
        fi
        if [ "x${DIST}" = "xstretch" ]; then
            PIP_UTIL="pip"
            if [ ! -f /usr/bin/pip ]; then
                ln -s /usr/bin/pip3 /usr/bin/pip
            fi
            apt-get -y install libz-dev libgcrypt-dev libssl-dev libcmocka-dev g++
            build_ssh
        fi
        if [ "x${DIST}" = "xfocal" -o "x${DIST}" = "xjammy" -o "x${DIST}" = "xbullseye"]; then
            ${PIP_UTIL} install --upgrade pip
        fi
        ${PIP_UTIL} install virtualenv || pip install virtualenv || pip3 install virtualenv || true
        build_oci_sdk
        if [ "x${DIST}" = "xxenial" ]; then
            get_cmake 3.6.3
        fi
        if [ "x${DIST}" = "xbionic" -o "x${DIST}" = "xbuster" ]; then
            build_ssh
            get_cmake 3.16.3
        fi
        build_python
        ln -s /usr/local/python3.11/lib /usr/lib/python3.11
    fi
    if [ ! -d /usr/local/percona-subunit2junitxml ]; then
        cd /usr/local
        git clone https://github.com/percona/percona-subunit2junitxml.git
        rm -rf /usr/bin/subunit2junitxml
        ln -s /usr/local/percona-subunit2junitxml/subunit2junitxml /usr/bin/subunit2junitxml
        cd ${CURPLACE}
    fi
    get_protobuf
    get_antlr4-runtime
    return;
}

get_tar(){
    TARBALL=$1
    TARFILE=$(basename $(find $WORKDIR/$TARBALL -name 'percona-mysql-shell*.tar.gz' | sort | tail -n1))
    if [ -z $TARFILE ]
    then
        TARFILE=$(basename $(find $CURDIR/$TARBALL -name 'percona-mysql-shell*.tar.gz' | sort | tail -n1))
        if [ -z $TARFILE ]
        then
            echo "There is no $TARBALL for build"
            exit 1
        else
            cp $CURDIR/$TARBALL/$TARFILE $WORKDIR/$TARFILE
        fi
    else
        cp $WORKDIR/$TARBALL/$TARFILE $WORKDIR/$TARFILE
    fi
    return
}

get_deb_sources(){
    param=$1
    echo $param
    FILE=$(basename $(find $WORKDIR/source_deb -name "percona-mysql-shell*.$param" | sort | tail -n1))
    if [ -z $FILE ]
    then
        FILE=$(basename $(find $CURDIR/source_deb -name "percona-mysql-shell*.$param" | sort | tail -n1))
        if [ -z $FILE ]
        then
            echo "There is no sources for build"
            exit 1
        else
            cp $CURDIR/source_deb/$FILE $WORKDIR/
        fi
    else
        cp $WORKDIR/source_deb/$FILE $WORKDIR/
    fi
    return
}

build_ssh(){
    cd "${WORKDIR}"
    wget -nv --no-check-certificate https://www.gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.8.9.tar.bz2
    wget -nv --no-check-certificate https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.45.tar.bz2
    tar -xvf libgcrypt-1.8.9.tar.bz2
    tar -xvf libgpg-error-1.45.tar.bz2
    rm -f libgpg-error-1.45.tar.bz2 libgcrypt-1.8.9.tar.bz2
    cd libgpg-error-1.45
    ./configure
    make
    make install
    cd -
    cd libgcrypt-1.8.9
    ./configure --with-libgpg-error-prefix="/usr/local"
    make
    make install
    cd -
    cd "${WORKDIR}"
    wget -nv --no-check-certificate http://archive.ubuntu.com/ubuntu/pool/main/libs/libssh/libssh_0.9.3.orig.tar.xz
    tar -xvf libssh_0.9.3.orig.tar.xz
    cd libssh-0.9.3/
    mkdir build
    cd build
    cmake --version
    cmake  -Wno-error-implicit-function-declaration -DWITH_GCRYPT=OFF -DWITH_ZLIB=OFF -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Debug ..
    make
    make install
    cd ${WORKDIR}
}

build_srpm(){
    MY_PATH=$(echo $PATH)
    if [ $SRPM = 0 ]
    then
        echo "SRC RPM will not be created"
        return;
    fi
    if [ "x$OS" = "xdeb" ]
    then
        echo "It is not possible to build src rpm here"
        exit 1
    fi
    build_ssh
    if [ $RHEL != 8 ]; then
        source /opt/rh/devtoolset-7/enable
        source /opt/rh/rh-python38/enable
    fi
    cd $WORKDIR
    get_tar "source_tarball"
    rm -fr rpmbuild
    ls | grep -v percona-mysql-shell-*.tar.* | grep -v protobuf | xargs rm -rf
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    TARFILE=$(basename $(find . -name 'percona-mysql-shell-*.tar.gz' | sort | tail -n1))
    NAME=$(echo ${TARFILE}| awk -F '-' '{print $1"-"$2}')
    VERSION=$(echo ${TARFILE}| awk -F '-' '{print $3}')
    #
    SHORTVER=$(echo ${VERSION} | awk -F '.' '{print $1"."$2}')
    TMPREL=$(echo ${TARFILE}| awk -F '-' '{print $4}')
    RELEASE=${TMPREL%.tar.gz}
    CURRENT_YEAR="$(date +%Y)"
    #
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    #
    cd ${WORKDIR}/rpmbuild/SPECS
    tar vxzf ${WORKDIR}/${TARFILE} --wildcards '*/packaging/rpm/*.spec.in' --strip=3
    mv mysql-shell.spec.in mysql-shell.spec
    #
    sed -i 's|mysql-shell@PRODUCT_SUFFIX@|percona-mysql-shell@PRODUCT_SUFFIX@|' mysql-shell.spec
    sed -i 's|  mysql-shell|  percona-mysql-shell|' mysql-shell.spec
    sed -i 's|https://cdn.mysql.com/Downloads/%{name}-@MYSH_VERSION@-src.tar.gz|%{name}-@MYSH_VERSION@.tar.gz|' mysql-shell.spec
    sed -i 's|%{name}-@MYSH_VERSION@-src|%{name}-@MYSH_VERSION@|' mysql-shell.spec
    sed -i 's|%setup -q -n %{name}-|%setup -q -n mysql-shell-|' mysql-shell.spec
    sed -i '/with_protobuf/,/endif/d' mysql-shell.spec
    sed -i 's/@COMMERCIAL_VER@/0/g' mysql-shell.spec
    sed -i 's/@CLOUD_VER@/0/g' mysql-shell.spec
    sed -i 's/@PRODUCT_SUFFIX@//g' mysql-shell.spec
    sed -i "s/@MYSH_NO_DASH_VERSION@/${SHELL_BRANCH}/g" mysql-shell.spec
    sed -i "s:@RPM_RELEASE@:${RPM_RELEASE}:g" mysql-shell.spec
    sed -i 's/@LICENSE_TYPE@/GPLv2/g' mysql-shell.spec
    sed -i 's/@PRODUCT@/MySQL Shell/' mysql-shell.spec
    sed -i "s/@MYSH_VERSION@/${SHELL_BRANCH}/g" mysql-shell.spec
    sed -i 's:1%{?dist}:1%{?dist}:g'  mysql-shell.spec
    sed -i "s:-DHAVE_PYTHON=1: -DHAVE_PYTHON=2 -DPACKAGE_YEAR=${CURRENT_YEAR} -DWITH_PROTOBUF=system -DPROTOBUF_INCLUDE_DIRS=/usr/local/include -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a -DWITH_STATIC_LINKING=ON -DBUNDLED_SSH_DIR=${WORKDIR}/libssh-0.9.3/build/ -DMYSQL_EXTRA_LIBRARIES='-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata' -DUSE_LD_GOLD=0 :" mysql-shell.spec
    sed -i "s|BuildRequires:  python-devel|%if 0%{?rhel} > 7\nBuildRequires:  python2-devel\n%else\nBuildRequires:  python-devel\n%endif|" mysql-shell.spec
    sed -i 's:>= 0.9.2::' mysql-shell.spec
    sed -i 's:libssh-devel:gcc:' mysql-shell.spec
    #sed -i '59,60d' mysql-shell.spec
    sed -i "s:prompt/::" mysql-shell.spec
    sed -i 's:%files:for file in $(ls -Ap %{buildroot}/usr/lib/mysqlsh/ | grep -v / | grep -v libssh | grep -v libpython | grep -v libantlr4-runtime | grep -v libfido | grep -v protobuf); do rm %{buildroot}/usr/lib/mysqlsh/$file; done\nif [[ -f "/opt/antlr4/usr/local/lib64/libantlr4-runtime.so" ]]; then cp /opt/antlr4/usr/local/lib64/libantlr4-runtime.s* %{buildroot}/usr/lib/mysqlsh/; fi\nif [[ -f "/tmp/polyglot-nativeapi-native-library/libjitexecutor.so" ]]; then cp /tmp/polyglot-nativeapi-native-library/libjitexecutor.so %{buildroot}/usr/lib/mysqlsh/; fi\n%files:' mysql-shell.spec
    sed -i 's:%files:if [[ -f "/usr/local/lib64/libprotobuf.so" ]]; then cp /usr/local/lib64/libprotobuf* %{buildroot}/usr/lib/mysqlsh/; cp /usr/local/lib64/libabsl_* %{buildroot}/usr/lib/mysqlsh/; cp /usr/local/lib64/libgmock* %{buildroot}/usr/lib/mysqlsh/; fi\n%files\n%{_prefix}/lib/mysqlsh/libprotobuf*\n%{_prefix}/lib/mysqlsh/libabsl_*\n%{_prefix}/lib/mysqlsh/libgmock*:' mysql-shell.spec
    sed -i 's:%global __requires_exclude ^(:%global _protobuflibs libprotobuf.*|libabsl_.*|libgmock.*\n%global __requires_exclude ^(%{_protobuflibs}|:' mysql-shell.spec
    sed -i "s|%files|%if %{?rhel} > 7\n sed -i 's:/usr/bin/env python$:/usr/bin/env python3:' %{buildroot}/usr/lib/mysqlsh/lib/python3.*/lib2to3/tests/data/*.py\n sed -i 's:/usr/bin/env python$:/usr/bin/env python3:' %{buildroot}/usr/lib/mysqlsh/lib/python3.*/encodings/rot_13.py\n%endif\n\n%files|" mysql-shell.spec
    sed -i "s:%undefine _missing_build_ids_terminate_build:%define _build_id_links none\n%undefine _missing_build_ids_terminate_build:" mysql-shell.spec
    #sed -i 's:%{?_smp_mflags}:VERBOSE=1:g' mysql-shell.spec # if a one thread is required 

    mv mysql-shell.spec percona-mysql-shell.spec
    cat percona-mysql-shell.spec
    cd ${WORKDIR}
    #
    mv -fv ${TARFILE} ${WORKDIR}/rpmbuild/SOURCES
    #
        rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" rpmbuild/SPECS/percona-mysql-shell.spec
    #
    mkdir -p ${WORKDIR}/srpm
    mkdir -p ${CURDIR}/srpm
    cp rpmbuild/SRPMS/*.src.rpm ${CURDIR}/srpm
    cp rpmbuild/SRPMS/*.src.rpm ${WORKDIR}/srpm
    export PATH=$MY_PATH
    return
}

build_rpm(){
    MY_PATH=$(echo $PATH)
    if [ $RPM = 0 ]
    then
        echo "RPM will not be created"
        return;
    fi
    if [ "x$OS" = "xdeb" ]
    then
        echo "It is not possible to build rpm here"
    fi
    build_ssh
    SRC_RPM=$(basename $(find $WORKDIR/srpm -name 'percona-mysql-shell-*.src.rpm' | sort | tail -n1))
    if [ -z $SRC_RPM ]
    then
        SRC_RPM=$(basename $(find $CURDIR/srpm -name 'percona-mysql-shell-*.src.rpm' | sort | tail -n1))
        if [ -z $SRC_RPM ]
        then
            echo "There is no src rpm for build"
            echo "You can create it using key --build_src_rpm=1"
        else
            cp $CURDIR/srpm/$SRC_RPM $WORKDIR
        fi
    else
        cp $WORKDIR/srpm/$SRC_RPM $WORKDIR
    fi
    cd $WORKDIR
    rm -fr rpmbuild
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    cp $SRC_RPM rpmbuild/SRPMS/
    RHEL=$(rpm --eval %rhel)
    ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
    #
    echo "RHEL=${RHEL}" >> mysql-shell.properties
    echo "ARCH=${ARCH}" >> mysql-shell.properties
    #
    SRCRPM=$(basename $(find . -name '*.src.rpm' | sort | tail -n1))
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    #
    mv *.src.rpm rpmbuild/SRPMS
    if [ $RHEL != 8 ]; then
        source /opt/rh/devtoolset-7/enable
        source /opt/rh/rh-python38/enable
    fi
    #get_v8
    get_GraalVM
    get_protobuf
    if [ $RHEL = 9 -o $RHEL = 10 ]; then
        yum -y remove gcc gcc-c++
        update-alternatives --install /usr/bin/gcc gcc /opt/rh/gcc-toolset-12/root/usr/bin/gcc 200 --slave /usr/bin/g++ g++ /opt/rh/gcc-toolset-12/root/usr/bin/g++ --slave /usr/bin/gcov gcov /opt/rh/gcc-toolset-12/root/usr/bin/gcov
    fi
    get_database
    build_oci_sdk
    if [ $RHEL = 7 ]; then
        source /opt/rh/devtoolset-7/enable
        source /opt/rh/rh-python38/enable
    elif [ $RHEL = 6 ]; then
        source /opt/rh/devtoolset-7/enable
    fi
    get_antlr4-runtime
    cd ${WORKDIR}
    #
    if [ ${RHEL} = 6 ]; then
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_mysql_source $WORKDIR/percona-server" --define "static 1" --define "with_protobuf $WORKDIR/protobuf/src/" --define "with_oci $WORKDIR/oci_sdk" --define "bundled_openssl /usr/local/openssl" --define "bundled_python /usr/local/python37/" --define "bundled_shared_python yes" --define "jit_executor_lib $WORKDIR/polyglot-nativeapi-native-library/" --rebuild rpmbuild/SRPMS/${SRCRPM}
    elif [ ${RHEL} = 7 ]; then
        source /opt/rh/devtoolset-11/enable
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_mysql_source $WORKDIR/percona-server" --define "static 1" --define "with_protobuf $WORKDIR/protobuf/src/" --define "with_oci $WORKDIR/oci_sdk" --define "bundled_python /usr/local/python39/" --define "bundled_shared_python yes" --define "bundled_antlr /opt/antlr4/usr/local/" --define "bundled_ssh 1" --define "jit_executor_lib $WORKDIR/polyglot-nativeapi-native-library/" --rebuild rpmbuild/SRPMS/${SRCRPM}
    elif [ ${RHEL} = 8 ]; then
        if [ ${SHELL_BRANCH:2:1} = 1 ]; then
            source /opt/rh/gcc-toolset-11/enable
        else
            source /opt/rh/gcc-toolset-12/enable
        fi
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_mysql_source $WORKDIR/percona-server" --define "static 1" --define "with_protobuf $WORKDIR/protobuf/src/" --define "with_oci $WORKDIR/oci_sdk" --define "bundled_python /usr/local/python39/" --define "bundled_shared_python yes" --define "bundled_antlr /opt/antlr4/usr/local/" --define "bundled_ssh 1" --define "jit_executor_lib $WORKDIR/polyglot-nativeapi-native-library/" --rebuild rpmbuild/SRPMS/${SRCRPM}
    else
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_mysql_source $WORKDIR/percona-server" --define "static 1" --define "with_protobuf $WORKDIR/protobuf/src/" --define "with_oci $WORKDIR/oci_sdk" --define "bundled_python /usr/local/python39/" --define "bundled_shared_python yes" --define "bundled_antlr /opt/antlr4/usr/local/" --define "bundled_ssh 1" --define "jit_executor_lib $WORKDIR/polyglot-nativeapi-native-library/" --rebuild rpmbuild/SRPMS/${SRCRPM}
    fi
    return_code=$?
    if [ $return_code != 0 ]; then
        exit $return_code
    fi
    mkdir -p ${WORKDIR}/rpm
    mkdir -p ${CURDIR}/rpm
    cp rpmbuild/RPMS/*/*.rpm ${WORKDIR}/rpm
    cp rpmbuild/RPMS/*/*.rpm ${CURDIR}/rpm
    export PATH=$MY_PATH
}

build_source_deb(){
    if [ $SDEB = 0 ]
    then
        echo "source deb package will not be created"
        return;
    fi
    if [ "x$OS" = "xrpm" ]
    then
        echo "It is not possible to build source deb here"
        exit 1
    fi
    build_ssh
    rm -rf mysql-shell*
    get_tar "source_tarball"
    rm -f *.dsc *.orig.tar.gz *.debian.tar.* *.changes
    #
    TARFILE=$(basename $(find . -name 'percona-mysql-shell-*.tar.gz' | grep -v tokudb | sort | tail -n1))
    NAME=$(echo ${TARFILE}| awk -F '-' '{print $1"-"$2"-"$3}')
    VERSION=$(echo ${TARFILE}| awk -F '-' '{print $4}' | awk -F '.tar' '{print $1}')
    SHORTVER=$(echo ${VERSION} | awk -F '.' '{print $1"."$2}')
    TMPREL="1.tar.gz"
    RELEASE=1
    NEWTAR=${NAME}_${VERSION}-${RELEASE}.orig.tar.gz
    mv ${TARFILE} ${NEWTAR}
    tar xzf ${NEWTAR}
    cd mysql-shell-${VERSION}
    sed -i 's|Source: mysql-shell|Source: percona-mysql-shell|' debian/control
    sed -i 's|Package: mysql-shell|Package: percona-mysql-shell|' debian/control
    sed -i 's|cmake (>= 2.8.5), ||' debian/control
    sed -i 's|mysql-shell|percona-mysql-shell|' debian/changelog
    sed -i 's|${misc:Depends},|${misc:Depends}, python3|' debian/control
    sed -i 's|(>=0.9.2)||' debian/control
    sed -i 's|libssh-dev ,||' debian/control
    sed -i '17d' debian/control
    echo 'usr/lib/mysqlsh/libjitexecutor.so' >> debian/mysql-shell.install
    dch -D unstable --force-distribution -v "${VERSION}-${RELEASE}-${DEB_RELEASE}" "Update to new upstream release ${VERSION}-${RELEASE}-1"
    dpkg-buildpackage -S
    cd ${WORKDIR}
    mkdir -p $WORKDIR/source_deb
    mkdir -p $CURDIR/source_deb
    cp percona*.tar.* $WORKDIR/source_deb
    cp percona*_source.changes $WORKDIR/source_deb
    cp percona*.dsc $WORKDIR/source_deb
    cp percona*.orig.tar.gz $WORKDIR/source_deb
    cp percona*.tar.* $CURDIR/source_deb
    cp percona*_source.changes $CURDIR/source_deb
    cp percona*.dsc $CURDIR/source_deb
    cp percona*.orig.tar.gz $CURDIR/source_deb
}

build_deb(){
    if [ $DEB = 0 ]
    then
        echo "Deb package will not be created"
        return;
    fi
    if [ "x$OS" = "xrpm" ]
    then
        echo "It is not possible to build source deb here"
        exit 1
    fi
    build_ssh
    for file in 'dsc' 'orig.tar.gz' 'changes' 'tar.xz'
    do
        get_deb_sources $file
    done
    cd $WORKDIR
    rm -fv *.deb
    export DEBIAN_VERSION="$(lsb_release -sc)"
    export CURRENT_YEAR="$(date +%Y)"
    DSC=$(basename $(find . -name '*.dsc' | sort | tail -n 1))
    DIRNAME=$(echo ${DSC%-${DEB_RELEASE}.dsc} | sed -e 's:_:-:g')
    VERSION=$(echo ${DSC} | sed -e 's:_:-:g' | awk -F'-' '{print $4}')
    RELEASE=$(echo ${DSC} | sed -e 's:_:-:g' | awk -F'-' '{print $5}')
    ARCH=$(uname -m)
    export EXTRAVER=${MYSQL_VERSION_EXTRA#-}
    #
    echo "ARCH=${ARCH}" >> mysql-shell.properties
    echo "DEBIAN_VERSION=${DEBIAN_VERSION}" >> mysql-shell.properties
    echo "VERSION=${VERSION}" >> mysql-shell.properties
    #
    dpkg-source -x ${DSC}
    get_protobuf
    get_database
    #get_v8
    get_GraalVM
    build_oci_sdk
    cd ${WORKDIR}/percona-mysql-shell-$SHELL_BRANCH-1
    sed -i 's:3.8:3.6:' CMakeLists.txt
    sed -i 's/make -j8/make -j8\n\t/' debian/rules
    sed -i '/-DCMAKE/,/j8/d' debian/rules
    sed -i 's/--fail-missing//' debian/rules
    cp debian/mysql-shell.install debian/install
    echo "usr/lib/mysqlsh/libssh*.so*" >> debian/install
    echo "usr/lib/mysqlsh/libprotobuf*.so*" >> debian/install
    echo "usr/lib/mysqlsh/libabsl_*.so*" >> debian/install
    echo "usr/lib/mysqlsh/libgmock.so*" >> debian/install
    sed -i 's:-rm -fr debian/tmp/usr/lib*/*.{so*,a} 2>/dev/null:-rm -fr debian/tmp/usr/lib*/*.{so*,a} 2>/dev/null\n\tmv debian/tmp/usr/local/* debian/tmp/usr/\n\trm -rf debian/tmp/usr/local:' debian/rules
    if [ "x${DEBIAN_VERSION}" = "xjammy" -o "x${DEBIAN_VERSION}" = "xnoble" ]; then
        sed -i "s:VERBOSE=1:-DCMAKE_SHARED_LINKER_FLAGS="" -DCMAKE_MODULE_LINKER_FLAGS="" -DCMAKE_CXX_FLAGS="" -DCMAKE_C_FLAGS="" -DCMAKE_EXE_LINKER_FLAGS="" -DBUNDLED_PYTHON_DIR=\"/usr/local/python312\" -DPYTHON_INCLUDE_DIRS=\"/usr/local/python312/include/python3.12\" -DPYTHON_LIBRARIES=\"/usr/local/python312/lib/libpython3.12.so\" -DBUNDLED_ANTLR_DIR=\"/opt/antlr4/usr/local\" -DPACKAGE_YEAR=${CURRENT_YEAR} -DCMAKE_BUILD_TYPE=Release -DEXTRA_INSTALL=\"\" -DEXTRA_NAME_SUFFIX=\"\" -DWITH_OCI=$WORKDIR/oci_sdk -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld -DMYSQL_EXTRA_LIBRARIES=\"-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata \" -DWITH_PROTOBUF=system -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library -DHAVE_PYTHON=1 -DWITH_STATIC_LINKING=ON -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib -DWITH_OCI=$WORKDIR/oci_sdk -DBUNDLED_SSH_DIR=${WORKDIR}/libssh-0.9.3/build/ . \n\t DEB_BUILD_HARDENING=1 make -j1 VERBOSE=1:" debian/rules
        sed -i "s/override_dh_auto_clean:/override_dh_auto_clean:\n\noverride_dh_auto_build:\n\tmake -j1/" debian/rules
    else
        sed -i "s:VERBOSE=1:-DBUNDLED_PYTHON_DIR=\"/usr/local/python312\" -DPYTHON_INCLUDE_DIRS=\"/usr/local/python312/include/python3.12\" -DPYTHON_LIBRARIES=\"/usr/local/python312/lib/libpython3.12.so\" -DBUNDLED_ANTLR_DIR=\"/opt/antlr4/usr/local\" -DPACKAGE_YEAR=${CURRENT_YEAR} -DCMAKE_BUILD_TYPE=RelWithDebInfo -DEXTRA_INSTALL=\"\" -DEXTRA_NAME_SUFFIX=\"\" -DWITH_OCI=$WORKDIR/oci_sdk -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld -DMYSQL_EXTRA_LIBRARIES=\"-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata \" -DWITH_PROTOBUF=system -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library -DHAVE_PYTHON=1 -DWITH_STATIC_LINKING=ON -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib -DWITH_OCI=$WORKDIR/oci_sdk -DBUNDLED_SSH_DIR=${WORKDIR}/libssh-0.9.3/build/ . \n\t DEB_BUILD_HARDENING=1 make -j8 VERBOSE=1:" debian/rules
    fi
    if [ "x$OS_NAME" != "xbuster" ]; then
        sed -i 's:} 2>/dev/null:} 2>/dev/null\n\tmv debian/tmp/usr/local/* debian/tmp/usr/\n\tcp debian/../bin/* debian/tmp/usr/bin/\n\trm -fr debian/tmp/usr/local:' debian/rules
    else
        sed -i 's:} 2>/dev/null:} 2>/dev/null\n\tmv debian/tmp/usr/local/* debian/tmp/usr/\n\trm -fr debian/tmp/usr/local\n\trm -fr debian/tmp/usr/bin/mysqlshrec:' debian/rules
    fi
    sed -i 's|override_dh_auto_clean:|override_dh_builddeb:\n\tdh_builddeb -- -Zgzip\n\noverride_dh_auto_clean:|' debian/rules
    sed -i 's|override_dh_install:|\tcp -v /usr/local/lib/libprotobuf* debian/tmp/usr/lib/mysqlsh\n\tcp -v /usr/local/lib/libabsl_* debian/tmp/usr/lib/mysqlsh\n\tcp -v /usr/local/lib/libgmock* debian/tmp/usr/lib/mysqlsh\n\noverride_dh_install:|' debian/rules
    sed -i 's:, libprotobuf-dev, protobuf-compiler::' debian/control
    grep -r "Werror" * | awk -F ':' '{print $1}' | sort | uniq | xargs sed -i 's/-Werror/-Wno-error/g'
    dch -b -m -D "$DEBIAN_VERSION" --force-distribution -v "${VERSION}-${RELEASE}-${DEB_RELEASE}.${DEBIAN_VERSION}" 'Update distribution'
    dpkg-buildpackage -rfakeroot -uc -us -b
    cd ${WORKDIR}
    mkdir -p $CURDIR/deb
    mkdir -p $WORKDIR/deb
    cp $WORKDIR/*.deb $WORKDIR/deb
    cp $WORKDIR/*.deb $CURDIR/deb
}

build_tarball(){
    if [ $TARBALL = 0 ]
    then
        echo "Binary tarball will not be created"
        return;
    fi
    get_tar "source_tarball"
    cd $WORKDIR
    TARFILE=$(basename $(find . -name 'percona-mysql-shell*.tar.gz' | sort | tail -n1))
    if [ -f /etc/debian_version ]; then
        export OS_RELEASE="$(lsb_release -sc)"
    fi
    #
    if [ -f /etc/redhat-release ]; then
        export OS_RELEASE="centos$(lsb_release -sr | awk -F'.' '{print $1}')"
        RHEL=$(rpm --eval %rhel)
        if [ $RHEL != 8 ]; then
            source /opt/rh/devtoolset-7/enable
            source /opt/rh/rh-python36/enable
        fi
    fi
    #
    ARCH=$(uname -m 2>/dev/null||true)
    TARFILE=$(basename $(find . -name 'percona-mysql-shell*.tar.gz' | sort | grep -v "tools" | tail -n1))
    NAME=$(echo ${TARFILE}| awk -F '-' '{print $1"-"$2"-"$3}')
    VERSION=$(echo ${TARFILE}| awk -F '-' '{print $4}' | awk -F '.tar' '{print $1}')
    VER=$(echo ${TARFILE}| awk -F '-' '{print $4}' | awk -F'.' '{print $1}')
    #
    SHORTVER=$(echo ${VERSION} | awk -F '.' '{print $1"."$2}')
    TMPREL=$(echo ${TARFILE}| awk -F '-' '{print $5}')
    RELEASE=${TMPREL%.tar.gz}
    #
    get_database
    #get_v8
    get_GraalVM
    build_ssh
    build_oci_sdk
    cd ${WORKDIR}
    rm -fr ${TARFILE%.tar.gz}
    tar xzf ${TARFILE}
    cd mysql-shell-${VERSION}
    DIRNAME="tarball"
    mkdir bld
    cd bld
    if [ -f /etc/redhat-release ]; then
        if [ $RHEL = 7 ]; then
            source /opt/rh/devtoolset-11/enable
        fi
        if [ $RHEL = 8 ]; then
            if [ ${SHELL_BRANCH:2:1} = 1 ]; then
                source /opt/rh/gcc-toolset-11/enable
            else
                source /opt/rh/gcc-toolset-12/enable
            fi
        fi
        if [ $RHEL = 9 -o $RHEL = 10 ]; then
            source /opt/rh/gcc-toolset-12/enable
            cmake .. -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server \
                -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld \
                -DMYSQL_EXTRA_LIBRARIES="-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata " \
                -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library \
                -DHAVE_PYTHON=1 \
                -DWITH_OCI=$WORKDIR/oci_sdk \
                -DWITH_STATIC_LINKING=ON \
                -DWITH_PROTOBUF=system \
                -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib \
                -DPROTOBUF_INCLUDE_DIRS=/usr/local/include \
                -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a \
                -DBUNDLED_OPENSSL_DIR=system \
                -DBUNDLED_ANTLR_DIR=/opt/antlr4/usr/local \
                -DBUNDLED_PYTHON_DIR=/usr/local/python39 \
                -DPYTHON_INCLUDE_DIRS=/usr/local/python39/include/python3.9 \
                -DPYTHON_LIBRARIES=/usr/local/python39/lib/libpython3.9.so \
                -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library
        elif [ $RHEL = 7 -o $RHEL = 8 ]; then
            cmake .. -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server \
                -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld \
                -DMYSQL_EXTRA_LIBRARIES="-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata " \
                -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library \
                -DHAVE_PYTHON=1 \
                -DWITH_OCI=$WORKDIR/oci_sdk \
                -DWITH_STATIC_LINKING=ON \
                -DWITH_PROTOBUF=system \
                -DPROTOBUF_INCLUDE_DIRS=/usr/local/include \
                -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a\
                -DPYTHON_INCLUDE_DIRS=/usr/local/python39/include/python3.9 \
                -DPYTHON_LIBRARIES=/usr/local/python39/lib/libpython3.9.so \
                -DBUNDLED_SHARED_PYTHON=yes \
                -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib \
                -DBUNDLED_PYTHON_DIR=/usr/local/python39 \
                -DBUNDLED_ANTLR_DIR=/opt/antlr4/usr/local \
                -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library
        else
            cmake .. -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server \
                -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld \
                -DMYSQL_EXTRA_LIBRARIES="-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata " \
                -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library \
                -DHAVE_PYTHON=2 \
                -DWITH_OCI=$WORKDIR/oci_sdk \
                -DWITH_STATIC_LINKING=ON \
                -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib \
                -DWITH_PROTOBUF=system \
                -DPROTOBUF_INCLUDE_DIRS=/usr/local/include \
                -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a\
                -DBUNDLED_OPENSSL_DIR=/usr/local/openssl11 \
                -DPYTHON_INCLUDE_DIRS=/usr/local/python39/include/python3.9 \
                -DPYTHON_LIBRARIES=/usr/local/python39/lib/libpython3.9.so \
                -DBUNDLED_SHARED_PYTHON=yes \
                -DBUNDLED_PYTHON_DIR=/usr/local/python39 \
                -DBUNDLED_ANTLR_DIR=/opt/antlr4/usr/local \
                -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library
        fi
    else
        cmake .. -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server \
            -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld \
            -DMYSQL_EXTRA_LIBRARIES="-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata " \
            -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library \
            -DHAVE_PYTHON=1 \
            -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib \
            -DWITH_PROTOBUF=system \
            -DPROTOBUF_INCLUDE_DIRS=/usr/local/include \
            -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a\
            -DWITH_OCI=$WORKDIR/oci_sdk \
            -DWITH_STATIC_LINKING=ON \
            -DBUNDLED_ANTLR_DIR=/opt/antlr4/usr/local \
            -DBUNDLED_PYTHON_DIR=/usr/local/python312 \
            -DJIT_EXECUTOR_LIB=${WORKDIR}/polyglot-nativeapi-native-library \
            -DPYTHON_INCLUDE_DIRS=/usr/local/python312/include/python3.12 \
            -DPYTHON_LIBRARIES=/usr/local/python312/lib/libpython3.12.so
    fi
    make -j4
    mkdir ${NAME}-${VERSION}-linux-glibc${GLIBC_VERSION}
    cp -r bin ${NAME}-${VERSION}-linux-glibc${GLIBC_VERSION}/
    cp -r share ${NAME}-${VERSION}-linux-glibc${GLIBC_VERSION}/
    if [ -d lib ]; then
        cp -r lib ${NAME}-${VERSION}-linux-glibc${GLIBC_VERSION}/
    fi
    tar -zcvf ${NAME}-${VERSION}-linux-glibc${GLIBC_VERSION}.tar.gz ${NAME}-${VERSION}-linux-glibc${GLIBC_VERSION}
    mkdir -p ${WORKDIR}/${DIRNAME}
    mkdir -p ${CURDIR}/${DIRNAME}
    cp *.tar.gz ${WORKDIR}/${DIRNAME}
    cp *.tar.gz ${CURDIR}/${DIRNAME}
}
#main
CURDIR=$(pwd)
VERSION_FILE=$CURDIR/mysql-shell.properties
args=
WORKDIR=
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
TARBALL=0
OS_NAME=
ARCH=
OS=
PROTOBUF_REPO="https://github.com/protocolbuffers/protobuf.git"
SHELL_REPO="https://github.com/mysql/mysql-shell.git"
SHELL_BRANCH="8.0.31"
PROTOBUF_BRANCH=v4.24.4
INSTALL=0
REVISION=0
BRANCH="release-8.0.31-23"
RPM_RELEASE=1
DEB_RELEASE=1
YASSL=0
REPO="https://github.com/percona/percona-server.git"
MYSQL_VERSION_EXTRA=-1
parse_arguments PICK-ARGS-FROM-ARGV "$@"
if [ ${YASSL} = 1 ]; then
    TARBALL=1
fi
check_workdir
get_system
install_deps
get_sources
build_tarball
build_srpm
build_source_deb
build_rpm
build_deb
