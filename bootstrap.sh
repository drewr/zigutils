#!/bin/sh

bootstrapped=

if git submodule status | fgrep -q libcurl; then
  bootstrapped=1
fi

boot_submodules () {
  for p in libcurl libssh2 zlib mbedtls; do
    git submodule add https://github.com/mattnite/zig-$p lib/zig-$p
    ( cd lib/zig-$p && git submodule update --init )
  done
}

update_submodules () {
  git submodule update --init --recursive
}

if [ -z $bootstrapped ]; then
  echo retrieving libraries
  boot_submodules
else
  echo updating libraries
  update_submodules
fi
