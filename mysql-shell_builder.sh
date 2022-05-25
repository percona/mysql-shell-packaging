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
        sed -i "s:@@DIST@@:$OS_NAME:g" /etc/apt/sources.list.d/percona-dev.list
    fi
    wget -qO - http://jenkins.percona.com/apt-repo/8507EFA5.pub | apt-key add -
    return
}
get_cmake(){
    cd ${WORKDIR}
    apt -y purge cmake*
    apt-get -y install build-essential
    wget --no-check-certificate http://www.cmake.org/files/v3.6/cmake-3.6.3.tar.gz
    tar xf cmake-3.6.3.tar.gz
    cd cmake-3.6.3
    ./configure
    make
    make install
    cd ${WORKDIR}
}
get_protobuf(){
    MY_PATH=$(echo $PATH)
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL != 8 ]; then
            source /opt/rh/devtoolset-7/enable
            source /opt/rh/rh-python38/enable
        fi
    fi
    cd "${WORKDIR}"
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
    if [ "$PROTOBUF_BRANCH" = "v2.6.1" ]; then
        sed -i 's;curl http://googletest.googlecode.com/files/gtest-1.5.0.tar.bz2 | tar jx;curl -L https://github.com/google/googletest/archive/release-1.5.0.tar.gz | tar zx;' autogen.sh
        sed -i 's;mv gtest-1.5.0 gtest;mv googletest-release-1.5.0 gtest;' autogen.sh
    fi
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL != 8 ]; then
            source /opt/rh/devtoolset-7/enable
            source /opt/rh/rh-python38/enable
        fi
    fi
    bash -x autogen.sh
    bash -x configure --disable-shared
    make
    sudo make install
    mv src/.libs src/lib
    export PATH=$MY_PATH
    return
}
get_database(){
    MY_PATH=$(echo $PATH)
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL != 8 ]; then
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
    fi
    mkdir bld
    wget --no-check-certificate https://jenkins.percona.com/downloads/boost/boost_1_73_0.tar.gz
    #wget https://dl.bintray.com/boostorg/release/1.73.0/source/boost_1_73_0.tar.gz
    tar -xvzf boost_1_73_0.tar.gz
    mkdir -p $WORKDIR/boost
    mv boost_1_73_0/* $WORKDIR/boost/
    rm -rf boost_1_73_0 boost_1_73_0.tar.gz
    cd bld
    if [ "x$OS" = "xrpm" ]; then
        if [ $RHEL = 7 ]; then
            source /opt/rh/devtoolset-10/enable
        fi
        if [ $RHEL = 8 ]; then
            source /opt/rh/gcc-toolset-10/enable
        fi
        if [ $RHEL != 6 ]; then
            #uncomment once boost downloads are fixed
            #cmake .. -DDOWNLOAD_BOOST=1 -DENABLE_DOWNLOADS=1 -DWITH_SSL=system -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=bundled
            cmake .. -DENABLE_DOWNLOADS=1 -DWITH_SSL=system -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=bundled -DWITH_ZLIB=bundled -DWITH_COREDUMPER=OFF
        else
            #uncomment once boost downloads are fixed
            #cmake .. -DDOWNLOAD_BOOST=1 -DENABLE_DOWNLOADS=1 -DWITH_SSL=/usr/local/openssl11 -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=bundled
            cmake .. -DENABLE_DOWNLOADS=1 -DWITH_SSL=/usr/local/openssl11 -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=bundled -DWITH_ZLIB=bundled -DWITH_COREDUMPER=OFF
        fi
    else
        #uncomment once boost downloads are fixed
        #cmake .. -DDOWNLOAD_BOOST=1 -DENABLE_DOWNLOADS=1 -DWITH_SSL=system -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=bundled
        cmake .. -DENABLE_DOWNLOADS=1 -DWITH_SSL=system -DWITH_BOOST=$WORKDIR/boost -DWITH_PROTOBUF=bundled -DWITH_ZLIB=bundled -DWITH_COREDUMPER=OFF
    fi
    cmake --build . --target mysqlclient
    cmake --build . --target mysqlxclient
    cd $WORKDIR
    export PATH=$MY_PATH
    return
}

get_v8(){
    cd ${WORKDIR}
    wget --no-check-certificate https://jenkins.percona.com/downloads/v8_8.5.210.20.tar.gz
    tar -xzf v8_8.5.210.20.tar.gz
    rm -rf v8_8.5.210.20.tar.gz
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
        git checkout "$SHELL_BRANCH"
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
    sed -i 's:3.8:3.6:g' CMakeLists.txt
    #sed -i 's:STRING_PREPEND:#STRING_PREPEND:g' CMakeLists.txt
    sed -i 's:3.8:3.6:g' packaging/debian/CMakeLists.txt
    sed -i 's:3.8:3.6:g' packaging/rpm/mysql-shell.spec.in
    
    if [ "x$OS" = "xdeb" ]; then
        cd packaging/debian/
        cmake .
        cd ../../
        cmake . -DBUILD_SOURCE_PACKAGE=1 -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_SSL=system
    else
        cmake . -DBUILD_SOURCE_PACKAGE=1 -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_SSL=system
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
        if [ "x$OS_NAME" = "buster" -o "x$OS_NAME" = "focal" ]; then
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
                pip3.7 install -r requirements.txt
                pip3.7 install -e .
                pip3.7 install certifi || true
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
        ARCH=$(uname -m)
        OS_NAME="$(lsb_release -sc)"
        OS="deb"
    fi
    return
}

build_python(){
    cd ${WORKDIR}
    wget --no-check-certificate https://www.python.org/ftp/python/3.7.5/Python-3.7.5.tgz
    tar xzf Python-3.7.5.tgz
    cd Python-3.7.5
    sed -i 's/SSL=\/usr\/local\/ssl/SSL=\/usr\/local\/openssl11/g' Modules/Setup.dist
    sed -i '211,214 s/^##*//' Modules/Setup.dist
    ./configure --prefix=/usr/local/python37 --with-openssl=/usr/local/openssl11 --with-system-ffi --enable-shared LDFLAGS=-Wl,-rpath=/usr/local/python37/lib 
    make
    make install
    ln -sf /usr/local/python37/bin/*3.7* /usr/local/bin
    ln -sf /usr/local/python37/bin/*3.7* /usr/bin
    echo "/usr/local/python3.7/lib" > /etc/ld.so.conf.d/python-3.7.conf
    mv /usr/bin/python /usr/bin/python_back
    if [ -f /usr/bin/python2.7 ]; then
        update-alternatives --install /usr/bin/python python /usr/bin/python2.7 1
    else
        update-alternatives --install /usr/bin/python python /usr/bin/python2.6 1
    fi
    update-alternatives --install /usr/bin/python python /usr/bin/python3.7 100
    ldconfig /usr/local/lib
    cd ../
    
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
        add_percona_yum_repo
        if [ $RHEL = 8 ]; then
            yum -y install dnf-plugins-core
            yum config-manager --set-enabled PowerTools || yum config-manager --set-enabled powertools
	    subscription-manager repos --enable codeready-builder-for-rhel-8-x86_64-rpms
            yum -y install epel-release
            yum -y install git
            yum -y install binutils gcc gcc-c++ tar rpm-build rsync bison glibc glibc-devel libstdc++-devel libtirpc-devel make openssl-devel pam-devel perl perl-JSON perl-Memoize 
            yum -y install automake autoconf cmake jemalloc jemalloc-devel
            yum -y install libaio-devel ncurses-devel numactl-devel readline-devel time
            yum -y install rpcgen
            yum -y install automake m4 libtool python2-devel zip rpmlint
            yum -y install gperf ncurses-devel perl
            yum -y install libcurl-devel
            yum -y install perl-Env perl-Data-Dumper perl-JSON MySQL-python perl-Digest perl-Digest-MD5 perl-Digest-Perl-MD5 || true
            yum -y install libicu-devel automake m4 libtool python2-devel zip rpmlint python3 python3-devel python3-pip git
            yum -y install python3-virtualenv || true
            yum -y install openldap-devel
            yum -y install cyrus-sasl-devel cyrus-sasl-scram
            yum -y install centos-release-stream
            yum -y install gcc-toolset-10-gcc-c++ gcc-toolset-10-binutils
            yum -y install gcc-toolset-10-valgrind gcc-toolset-10-valgrind-devel gcc-toolset-10-libatomic-devel
            yum -y install gcc-toolset-10-libasan-devel gcc-toolset-10-libubsan-devel
	    yum -y install cmake
            yum -y remove centos-release-stream
            yum -y install libcmocka-devel
            #yum install -y python38 python38-devel python38-pip
            pip3 install --upgrade pip
            pip3 install virtualenv
            pip3 install certifi || true
            build_python
            #build_oci_sdk
        else
            yum -y install git
            yum -y install gcc openssl-devel bzip2-devel libffi libffi-devel
            yum -y install http://www.percona.com/downloads/percona-release/redhat/0.1-4/percona-release-0.1-4.noarch.rpm || true
            yum -y install epel-release
            yum -y install git numactl-devel rpm-build gcc-c++ gperf ncurses-devel perl readline-devel openssl-devel jemalloc 
            yum -y install time zlib-devel libaio-devel bison cmake pam-devel libeatmydata jemalloc-devel
            yum -y install perl-Time-HiRes libcurl-devel openldap-devel unzip wget libcurl-devel
            yum -y install perl-Env perl-Data-Dumper perl-JSON MySQL-python perl-Digest perl-Digest-MD5 perl-Digest-Perl-MD5 || true
            yum -y install libicu-devel automake m4 libtool python-devel zip rpmlint
            yum -y install libcmocka-devel
            until yum -y install centos-release-scl; do
                echo "waiting"
                sleep 1
            done
            until yum -y install centos-release-scl-rh; do
                echo "waiting"
                sleep 1
            done
            if [ "x$RHEL" = "x7" ]; then
                yum -y --enablerepo=centos-sclo-rh-testing install devtoolset-10-gcc-c++ devtoolset-10-binutils devtoolset-10-valgrind devtoolset-10-valgrind-devel devtoolset-10-libatomic-devel
                yum -y --enablerepo=centos-sclo-rh-testing install devtoolset-10-libasan-devel devtoolset-10-libubsan-devel
                rm -f /usr/bin/cmake
                cp -p /usr/bin/cmake3 /usr/bin/cmake
            fi
            if [ "x$RHEL" = "x8" ]; then
                yum -y install centos-release-stream
                yum -y install gcc-toolset-10-gcc-c++ gcc-toolset-10-binutils
                yum -y install gcc-toolset-10-valgrind gcc-toolset-10-valgrind-devel gcc-toolset-10-libatomic-devel
                yum -y install gcc-toolset-10-libasan-devel gcc-toolset-10-libubsan-devel
                yum -y remove centos-release-stream
            fi
            yum -y install  gcc-c++ devtoolset-7-gcc-c++ devtoolset-7-binutils cmake3
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
            source /opt/rh/rh-python38/enable
            pip install certifi || true
            pip install virtualenv || true
        fi
        if [ "x$RHEL" = "x6" ]; then
            yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
            percona-release enable tools testing
            yum -y install Percona-Server-shared-56
            yum install -y percona-devtoolset-gcc percona-devtoolset-binutils python-devel percona-devtoolset-gcc-c++ percona-devtoolset-libstdc++-devel percona-devtoolset-valgrind-devel
            yum install -y patchelf
            sed -i "668s:(void:(const void:" /usr/include/openssl/bio.h
            cd ${WORKDIR}
            wget --no-check-certificate https://github.com/openssl/openssl/archive/OpenSSL_1_1_1m.tar.gz
            tar -xvzf OpenSSL_1_1_1m.tar.gz
            cd openssl-OpenSSL_1_1_1m/
            ./config --prefix=/usr/local/openssl11 --openssldir=/usr/local/openssl11 shared zlib
            make -j4
            make install
            cd ../
            rm -rf OpenSSL_1_1_1d.tar.gz openssl-OpenSSL_1_1_1m
            echo "/usr/local/openssl11/lib" > /etc/ld.so.conf.d/openssl-1.1.1d.conf
            echo "include ld.so.conf.d/*.conf" > /etc/ld.so.conf
            ldconfig -v
            build_python
        fi
        if [ "x$RHEL" = "x7" ]; then
            sed -i '/#!\/bin\/bash/a exit 0' /usr/lib/rpm/brp-python-bytecompile
            build_python
            pip install certifi || true
	    sed -i 's:python :python2 :' /usr/bin/yum
	    sed -i 's:python:python2 :' /usr/libexec/urlgrabber-ext-down
        fi
        if [ "x$RHEL" = "x6" ]; then
            pip3 install --upgrade pip
            pip3 install virtualenv
            build_oci_sdk
        elif [ "x$RHEL" = "x7" ]; then
            pip install --upgrade pip
            pip install virtualenv
            pip install certifi || true
            build_oci_sdk
        else
            pip3.7 install --upgrade pip
            pip3.7 install virtualenv
            pip3.7 install certifi || true
            #build_oci_sdk
        fi
    else
        apt-get -y install dirmngr || true
        apt-get update
        apt-get -y install dirmngr || true
        apt-get -y install lsb-release wget
        wget --no-check-certificate https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb && dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
        percona-release enable tools testing
        export DEBIAN_FRONTEND="noninteractive"
        export DIST="$(lsb_release -sc)"
        until sudo apt-get update; do
            sleep 1
            echo "waiting"
        done
        apt-get -y purge eatmydata || true
        apt-get -y install psmisc
        apt-get -y install libsasl2-modules:amd64 || apt-get -y install libsasl2-modules
        apt-get -y install dh-systemd || true
        apt-get -y install curl bison cmake perl libssl-dev libaio-dev libldap2-dev libwrap0-dev gdb unzip gawk
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
        if [ x"${DIST}" = xbionic ]; then
            apt-get -y install gcc-8 g++-8
            update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-7 700 --slave /usr/bin/g++ g++ /usr/bin/g++-7
            update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-8 800 --slave /usr/bin/g++ g++ /usr/bin/g++-8
        else
            apt-get -y install gcc g++
        fi
        if [ -o "x$OS_NAME" = "xbullseye" ]; then
            apt-get -y install libssh2-1-dev
	fi
        
        if [ "x$OS_NAME" = "xstretch" ]; then
            echo "deb http://ftp.us.debian.org/debian/ jessie main contrib non-free" >> /etc/apt/sources.list
            apt-get update
            apt-get -y install gcc-4.9 g++-4.9
            sed -i 's;deb http://ftp.us.debian.org/debian/ jessie main contrib non-free;;' /etc/apt/sources.list
            apt-get update
        elif [ "x$OS_NAME" = "xfocal" -o "x$OS_NAME" = "xbullseye" ]; then
            apt-get -y install python3-mysqldb
            echo "deb http://archive.ubuntu.com/ubuntu bionic main restricted" >> /etc/apt/sources.list
            echo "deb http://archive.ubuntu.com/ubuntu bionic-updates main restricted" >> /etc/apt/sources.list
            echo "deb http://archive.ubuntu.com/ubuntu bionic universe" >> /etc/apt/sources.list
            apt-get update
            apt-get -y install gcc-4.8 g++-4.8
            sed -i 's;deb http://archive.ubuntu.com/ubuntu bionic main restricted;;' /etc/apt/sources.list
            sed -i 's;deb http://archive.ubuntu.com/ubuntu bionic-updates main restricted;;' /etc/apt/sources.list
            sed -i 's;deb http://archive.ubuntu.com/ubuntu bionic universe;;' /etc/apt/sources.list
            apt-get update
        else
            apt-get -y install python-mysqldb
            apt-get -y install gcc-4.8 g++-4.8
        fi
            apt-get -y install python python-dev
            apt-get -y install python27-dev
            apt-get -y install python3 python3-pip
            apt-get -y install python3-dev || true
        PIP_UTIL="pip3"
        if [ "x$OS_NAME" = "xxenial" ]; then
            update-alternatives --install /usr/bin/python python /usr/bin/python3 1
            update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1
            curl  https://bootstrap.pypa.io/pip/2.7/get-pip.py -o get-pip.py
            python get-pip.py
        fi
        if [ "x$OS_NAME" = "xstretch" ]; then
            PIP_UTIL="pip"
            if [ ! -f /usr/bin/pip ]; then
                ln -s /usr/bin/pip3 /usr/bin/pip
            fi
            apt-get -y install libz-dev libgcrypt-dev libssl-dev libcmocka-dev g++
            build_ssh

        fi
        if [ "x$OS_NAME" != "xbuster" ]; then
            if [ "x$OS_NAME" = "xxenial" ]; then
               export LC_ALL="en_US.UTF-8"
               export LC_CTYPE="en_US.UTF-8"
            fi
            ${PIP_UTIL} install --upgrade pip
        fi
        ${PIP_UTIL} install virtualenv || pip install virtualenv || pip3 install virtualenv || true
        build_oci_sdk
        if [ "x$OS_NAME" = "xxenial" ]; then
            get_cmake
        fi
        
    fi
    if [ "x$OS_NAME" = "xbionic" -o "x$OS_NAME" = "xbuster" ]; then
        apt-get -y install libz-dev libgcrypt-dev libssl-dev libcmocka-dev g++
        build_ssh
    fi
    if [ ! -d /usr/local/percona-subunit2junitxml ]; then
        cd /usr/local
        git clone https://github.com/percona/percona-subunit2junitxml.git
        rm -rf /usr/bin/subunit2junitxml
        ln -s /usr/local/percona-subunit2junitxml/subunit2junitxml /usr/bin/subunit2junitxml
        cd ${CURPLACE}
    fi
    get_protobuf
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
            wget --no-check-certificate https://www.gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.8.9.tar.bz2
            wget --no-check-certificate https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.45.tar.bz2

            tar -xvf libgcrypt-1.8.9.tar.bz2
            tar -xvf libgpg-error-1.45.tar.bz2
            rm -f libgpg-error-1.45.tar.bz2 libgcrypt-1.8.9.tar.bz2
            cd libgpg-error-1.45
                ./configure
                make
                sudo make install
            cd -
            cd libgcrypt-1.8.9
                ./configure
                make
                sudo make install
            cd -
    cd "${WORKDIR}"
    wget --no-check-certificate http://archive.ubuntu.com/ubuntu/pool/main/libs/libssh/libssh_0.9.3.orig.tar.xz
    tar -xvf libssh_0.9.3.orig.tar.xz
    cd libssh-0.9.3/
    mkdir build
    cd build
    cmake  -Wno-error-implicit-function-declaration -DWITH_GCRYPT=OFF -DWITH_ZLIB=OFF -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Debug ..
    make
    sudo make install
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
    #
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    #
    cd ${WORKDIR}/rpmbuild/SPECS
    tar vxzf ${WORKDIR}/${TARFILE} --wildcards '*/packaging/rpm/*.spec.in' --strip=3
    mv mysql-shell.spec.in mysql-shell.spec
    #
    sed -i 's|mysql-shell@PRODUCT_SUFFIX@|percona-mysql-shell@PRODUCT_SUFFIX@|' mysql-shell.spec
    sed -i 's|https://cdn.mysql.com/Downloads/%{name}-@MYSH_VERSION@-src.tar.gz|%{name}-@MYSH_VERSION@.tar.gz|' mysql-shell.spec
    sed -i 's|%{name}-@MYSH_VERSION@-src|%{name}-@MYSH_VERSION@|' mysql-shell.spec
    sed -i 's|%setup -q -n %{name}-|%setup -q -n mysql-shell-|' mysql-shell.spec
    sed -i '/with_protobuf/,/endif/d' mysql-shell.spec
    sed -i 's/@COMMERCIAL_VER@/0/g' mysql-shell.spec
    sed -i 's/@CLOUD_VER@/0/g' mysql-shell.spec
    sed -i 's/@PRODUCT_SUFFIX@//g' mysql-shell.spec
    sed -i 's/@MYSH_NO_DASH_VERSION@/8.0.28/g' mysql-shell.spec
    sed -i "s:@RPM_RELEASE@:${RPM_RELEASE}:g" mysql-shell.spec
    sed -i 's/@LICENSE_TYPE@/GPLv2/g' mysql-shell.spec
    sed -i 's/@PRODUCT@/MySQL Shell/' mysql-shell.spec
    sed -i 's/@MYSH_VERSION@/8.0.28/g' mysql-shell.spec
    sed -i 's:1%{?dist}:2%{?dist}:g'  mysql-shell.spec
    sed -i "s:-DHAVE_PYTHON=1: -DHAVE_PYTHON=2 -DWITH_PROTOBUF=bundled -DPROTOBUF_INCLUDE_DIRS=/usr/local/include -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a -DWITH_STATIC_LINKING=ON -DBUNDLED_SSH_DIR=${WORKDIR}/libssh-0.9.3/build/ -DMYSQL_EXTRA_LIBRARIES='-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata' :" mysql-shell.spec
    sed -i "s|BuildRequires:  python-devel|%if 0%{?rhel} > 7\nBuildRequires:  python2-devel\n%else\nBuildRequires:  python-devel\n%endif|" mysql-shell.spec
    sed -i 's:>= 0.9.2::' mysql-shell.spec
    sed -i 's:libssh-devel:gcc:' mysql-shell.spec
    #sed -i '59,60d' mysql-shell.spec
    sed -i "s:prompt/::" mysql-shell.spec
    sed -i 's:%files:for file in $(ls -Ap %{buildroot}/usr/lib/mysqlsh/ | grep -v / | grep -v libssh | grep -v libpython); do rm %{buildroot}/usr/lib/mysqlsh/$file; done\n%files\n%{_prefix}/lib/mysqlsh/.*\n%{_prefix}/lib/mysqlsh/*:' mysql-shell.spec

    mv mysql-shell.spec percona-mysql-shell.spec
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
    get_protobuf
    get_database
    get_v8
    build_oci_sdk
    if [ $RHEL = 7 ]; then
        source /opt/rh/devtoolset-7/enable
        source /opt/rh/rh-python38/enable
    elif [ $RHEL = 6 ]; then
        source /opt/rh/devtoolset-7/enable
    fi
    cd ${WORKDIR}
    #
    if [ ${RHEL} = 6 ]; then
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_mysql_source $WORKDIR/percona-server" --define "static 1" --define "with_protobuf $WORKDIR/protobuf/src/" --define "v8_includedir $WORKDIR/v8/include" --define "v8_libdir ${WORKDIR}/v8/out.gn/x64.release.sample/obj" --define "with_oci $WORKDIR/oci_sdk" --define "bundled_openssl /usr/local/openssl11" --define "bundled_python /usr/local/python37/" --define "bundled_shared_python yes" --rebuild rpmbuild/SRPMS/${SRCRPM}
    elif [ ${RHEL} = 7 ]; then
        source /opt/rh/devtoolset-10/enable
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_mysql_source $WORKDIR/percona-server" --define "static 1" --define "with_protobuf $WORKDIR/protobuf/src/" --define "v8_includedir $WORKDIR/v8/include" --define "v8_libdir ${WORKDIR}/v8/out.gn/x64.release.sample/obj" --define "with_oci $WORKDIR/oci_sdk" --define "bundled_python /usr/local/python37/" --define "bundled_shared_python yes" --rebuild rpmbuild/SRPMS/${SRCRPM}
    else
        source /opt/rh/gcc-toolset-10/enable
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_mysql_source $WORKDIR/percona-server" --define "static 1" --define "with_protobuf $WORKDIR/protobuf/src/" --define "v8_includedir $WORKDIR/v8/include" --define "v8_libdir ${WORKDIR}/v8/out.gn/x64.release.sample/obj" --define "with_oci $WORKDIR/oci_sdk"  --define "bundled_python /usr/local/python37/" --define "bundled_shared_python yes" --define "bundled_ssh 1" --rebuild rpmbuild/SRPMS/${SRCRPM}
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
    RELEASE=2
    NEWTAR=${NAME}_${VERSION}-${RELEASE}.orig.tar.gz
    mv ${TARFILE} ${NEWTAR}
    tar xzf ${NEWTAR}
    cd mysql-shell-${VERSION}
    cd percona-mysql-shell-8.0.28-2
    sed -i 's|3.8|3.6|' CMakeLists.txtx
    sed -i 's|Source: mysql-shell|Source: percona-mysql-shell|' debian/control
    sed -i 's|Package: mysql-shell|Package: percona-mysql-shell|' debian/control
    sed -i 's|cmake (>= 2.8.5), ||' debian/control
    sed -i 's|mysql-shell|percona-mysql-shell|' debian/changelog
    sed -i 's|${misc:Depends},|${misc:Depends}, python2.7|' debian/control
    sed -i 's|(>=0.9.2)||' debian/control
    sed -i 's|libssh-dev ,||' debian/control
    sed -i '17d' debian/control
    dch -D unstable --force-distribution -v "${VERSION}-2-${DEB_RELEASE}" "Update to new upstream release ${VERSION}-${RELEASE}-1"
    dpkg-buildpackage -S
    cd ${WORKDIR}
    mkdir -p $WORKDIR/source_deb
    mkdir -p $CURDIR/source_deb
    cp *.debian.tar.* $WORKDIR/source_deb
    cp *_source.changes $WORKDIR/source_deb
    cp *.dsc $WORKDIR/source_deb
    cp *.orig.tar.gz $WORKDIR/source_deb
    cp *.debian.tar.* $CURDIR/source_deb
    cp *_source.changes $CURDIR/source_deb
    cp *.dsc $CURDIR/source_deb
    cp *.orig.tar.gz $CURDIR/source_deb
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
    for file in 'dsc' 'orig.tar.gz' 'changes' 'debian.tar.xz'
    do
        ls $WORKDIR */*
        get_deb_sources $file
    done
    cd $WORKDIR
    rm -fv *.deb
    export DEBIAN_VERSION="$(lsb_release -sc)"
    DSC=$(basename $(find . -name '*.dsc' | sort | tail -n 1))
    DIRNAME=$(echo ${DSC%-${DEB_RELEASE}.dsc} | sed -e 's:_:-:g')
    VERSION=$(echo ${DSC} | sed -e 's:_:-:g' | awk -F'-' '{print $4}')
    RELEASE=$(echo ${DSC} | sed -e 's:_:-:g' | awk -F'-' '{print $5}')
    RELEASE=2
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
    get_v8
    build_oci_sdk
    cd ${WORKDIR}/percona-mysql-shell-$SHELL_BRANCH-2
    sed -i 's:3.8:3.6:' CMakeLists.txt
    sed -i 's/make -j8/make -j8\n\t/' debian/rules
    sed -i '/-DCMAKE/,/j8/d' debian/rules
    sed -i 's/--fail-missing//' debian/rules
    cp debian/mysql-shell.install debian/install
    echo "usr/lib/mysqlsh/libssh*.so*" >> debian/install
    sed -i 's:-rm -fr debian/tmp/usr/lib*/*.{so*,a} 2>/dev/null:-rm -fr debian/tmp/usr/lib*/*.{so*,a} 2>/dev/null\n\tmv debian/tmp/usr/local/* debian/tmp/usr/\n\trm -rf debian/tmp/usr/local:' debian/rules
    sed -i "s:VERBOSE=1:-DCMAKE_BUILD_TYPE=RelWithDebInfo -DEXTRA_INSTALL=\"\" -DEXTRA_NAME_SUFFIX=\"\" -DWITH_OCI=$WORKDIR/oci_sdk -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld -DMYSQL_EXTRA_LIBRARIES=\"-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata \" -DWITH_PROTOBUF=${WORKDIR}/protobuf/src -DV8_INCLUDE_DIR=${WORKDIR}/v8/include -DV8_LIB_DIR=${WORKDIR}/v8/out.gn/x64.release.sample/obj -DHAVE_PYTHON=1 -DWITH_STATIC_LINKING=ON -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib -DWITH_OCI=$WORKDIR/oci_sdk -DBUNDLED_SSH_DIR=${WORKDIR}/libssh-0.9.3/build/ . \n\t DEB_BUILD_HARDENING=1 make -j8 VERBOSE=1:" debian/rules
    if [ "x$OS_NAME" != "xbuster" ]; then
        sed -i 's:} 2>/dev/null:} 2>/dev/null\n\tmv debian/tmp/usr/local/* debian/tmp/usr/\n\tcp debian/../bin/* debian/tmp/usr/bin/\n\trm -fr debian/tmp/usr/local:' debian/rules
    else
        sed -i 's:} 2>/dev/null:} 2>/dev/null\n\tmv debian/tmp/usr/local/* debian/tmp/usr/\n\trm -fr debian/tmp/usr/local\n\trm -fr debian/tmp/usr/bin/mysqlshrec:' debian/rules
    fi
    sed -i 's:, libprotobuf-dev, protobuf-compiler::' debian/control
    if [ "x$OS_NAME" = "xfocal" ]; then
        grep -r "Werror" * | awk -F ':' '{print $1}' | sort | uniq | xargs sed -i 's/-Werror/-Wno-error/g'
    fi

    dch -b -m -D "$DEBIAN_VERSION" --force-distribution -v "${VERSION}-2-2.${DEBIAN_VERSION}" 'Update distribution'
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
    get_v8
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
            source /opt/rh/devtoolset-10/enable
        fi
        if [ $RHEL = 8 ]; then
            source /opt/rh/gcc-toolset-10/enable
        fi
        if [ $RHEL = 8 ]; then
            cmake .. -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server \
                -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld \
                -DMYSQL_EXTRA_LIBRARIES="-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata " \
                -DWITH_PROTOBUF=${WORKDIR}/protobuf/src \
                -DV8_INCLUDE_DIR=${WORKDIR}/v8/include \
                -DV8_LIB_DIR=${WORKDIR}/v8/out.gn/x64.release.sample/obj \
                -DHAVE_PYTHON=1 \
                -DWITH_OCI=$WORKDIR/oci_sdk \
                -DWITH_STATIC_LINKING=ON \
                -DWITH_PROTOBUF=bundled \
                -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib \
                -DPROTOBUF_INCLUDE_DIRS=/usr/local/include \
                -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a \
                -DBUNDLED_OPENSSL_DIR=system
        elif [ $RHEL = 7 ]; then
            cmake .. -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server \
                -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld \
                -DMYSQL_EXTRA_LIBRARIES="-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata " \
                -DWITH_PROTOBUF=${WORKDIR}/protobuf/src \
                -DV8_INCLUDE_DIR=${WORKDIR}/v8/include \
                -DV8_LIB_DIR=${WORKDIR}/v8/out.gn/x64.release.sample/obj \
                -DHAVE_PYTHON=1 \
                -DWITH_OCI=$WORKDIR/oci_sdk \
                -DWITH_STATIC_LINKING=ON \
                -DWITH_PROTOBUF=bundled \
                -DPROTOBUF_INCLUDE_DIRS=/usr/local/include \
                -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a\
                -DPYTHON_INCLUDE_DIRS=/usr/local/python37/include/python3.7m \
                -DPYTHON_LIBRARIES=/usr/local/python37/lib/libpython3.7m.so \
                -DBUNDLED_SHARED_PYTHON=yes \
                -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib \
                -DBUNDLED_PYTHON_DIR=/usr/local/python37/
        else
            cmake .. -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server \
                -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld \
                -DMYSQL_EXTRA_LIBRARIES="-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata " \
                -DWITH_PROTOBUF=${WORKDIR}/protobuf/src \
                -DV8_INCLUDE_DIR=${WORKDIR}/v8/include \
                -DV8_LIB_DIR=${WORKDIR}/v8/out.gn/x64.release.sample/obj \
                -DHAVE_PYTHON=2 \
                -DWITH_OCI=$WORKDIR/oci_sdk \
                -DWITH_STATIC_LINKING=ON \
                -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib \
                -DWITH_PROTOBUF=bundled \
                -DPROTOBUF_INCLUDE_DIRS=/usr/local/include \
                -DPROTOBUF_LIBRARIES=/usr/local/lib/libprotobuf.a\
                -DBUNDLED_OPENSSL_DIR=/usr/local/openssl11 \
                -DPYTHON_INCLUDE_DIRS=/usr/local/python37/include/python3.7m \
                -DPYTHON_LIBRARIES=/usr/local/python37/lib/libpython3.7m.so \
                -DBUNDLED_SHARED_PYTHON=yes \
                -DBUNDLED_PYTHON_DIR=/usr/local/python37/
        fi
    else
        cmake .. -DMYSQL_SOURCE_DIR=${WORKDIR}/percona-server \
            -DMYSQL_BUILD_DIR=${WORKDIR}/percona-server/bld \
            -DMYSQL_EXTRA_LIBRARIES="-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata " \
            -DWITH_PROTOBUF=${WORKDIR}/protobuf/src \
            -DV8_INCLUDE_DIR=${WORKDIR}/v8/include \
            -DV8_LIB_DIR=${WORKDIR}/v8/out.gn/x64.release.sample/obj \
            -DHAVE_PYTHON=1 \
            -DZLIB_LIBRARY=${WORKDIR}/percona-server/extra/zlib \
            -DWITH_OCI=$WORKDIR/oci_sdk \
            -DWITH_STATIC_LINKING=ON
    fi
    make -j4
    mkdir ${NAME}-${VERSION}-${OS_NAME}
    cp -r bin ${NAME}-${VERSION}-${OS_NAME}/
    cp -r share ${NAME}-${VERSION}-${OS_NAME}/
    if [ -d lib ]; then
        cp -r lib ${NAME}-${VERSION}-${OS_NAME}/
    fi
    tar -zcvf ${NAME}-${VERSION}-${OS_NAME}.tar.gz ${NAME}-${VERSION}-${OS_NAME}
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
SHELL_BRANCH="8.0.28"
PROTOBUF_BRANCH=v3.11.4
INSTALL=0
RPM_RELEASE=2
DEB_RELEASE=2
REVISION=0
BRANCH="release-8.0.28-20"
RPM_RELEASE=2
DEB_RELEASE=2
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
