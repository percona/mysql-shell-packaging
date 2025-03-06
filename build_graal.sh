#!/bin/sh

tag="23.0.1"
SHELL_BRANCH=""
if [ "$1" ]
  then
    tag=$1;
fi
if [ "$2" ]
  then
    SHELL_BRANCH=$2;
fi
echo "Build the GraalVM Polyglot Native API Library. Version $tag"

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
    yum install -y maven zlib-devel gcc wget git
else
    apt install -y maven zlib1g-dev gcc wget
fi

if [ x"$ARCH" = "xx86_64" ]; then
    wget https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${tag}/graalvm-community-jdk-${tag}_linux-x64_bin.tar.gz
    tar -zxvf graalvm-community-jdk-${tag}_linux-x64_bin.tar.gz
else
    wget https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${tag}/graalvm-community-jdk-${tag}_linux-aarch64_bin.tar.gz
    tar -zxvf graalvm-community-jdk-${tag}_linux-aarch64_bin.tar.gz
fi

mv graalvm-community-openjdk-${tag}+11.1 /opt/graalvm
git clone --recursive https://github.com/oracle/graal.git
cd graal
git checkout tags/jdk-${tag}
cd ..

export GRAALVM_HOME=/opt/graalvm
export PATH="/opt/graalvm/bin:$PATH"
export JAVA_HOME=/opt/graalvm
export GRAALJDK_ROOT="${PWD}/graal"

echo "---------------------------------------------"
java -version
mvn --version
echo "---------------------------------------------"

git clone https://github.com/mysql/mysql-shell
cd mysql-shell/ext/polyglot/
if [ ! -z "$SHELL_BRANCH" ]
then
    git reset --hard
    git clean -xdf
    git checkout tags/"$SHELL_BRANCH"
fi
mvn package
mkdir /tmp/polyglot-nativeapi-native-library
cp -r polyglot-nativeapi-native-library/target/* /tmp/polyglot-nativeapi-native-library

tar -zcvf polyglot-nativeapi-native-library_${tag}_${ARCH}_${OS_NAME}.tar.gz -C /tmp polyglot-nativeapi-native-library && echo "Done."
