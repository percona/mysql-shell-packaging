#!/bin/sh
#
# https://github.com/jeroen/build-v8-static
#

tag="10.9.194.10"
if [ "$1" ]
  then
    tag=$1;
fi
echo "Build v8. Version $tag"

git clone https://chromium.googlesource.com/chromium/tools/depot_tools
export PATH=$(pwd)/depot_tools:$PATH
fetch v8
cd v8
gclient sync -D --force --reset
gclient sync --revision tags/$tag
gn gen "out.gn/static" -vv --fail-on-unused-args --args='v8_monolithic=true
            v8_static_library=true
            v8_enable_sandbox=false
            v8_enable_pointer_compression=false
            is_clang=false
            is_asan=false
            use_gold=false
            is_debug=false
            is_official_build=false
            treat_warnings_as_errors=false
            v8_enable_i18n_support=false
            v8_use_external_startup_data=false
            use_custom_libcxx=false
            use_sysroot=false'
ninja -C out.gn/static
cd ..
tar -zcvf v8_$tag.tar.gz v8 && echo "Done."
