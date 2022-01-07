#!/bin/sh

for p in libcurl libssh2 zlib mbedtls; do
  git submodule add https://github.com/mattnite/zig-$p lib/zig-$p
  ( cd lib/zig-$p && git submodule update --init )
done
