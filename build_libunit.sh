#!/bin/bash

prefix="./"
if [[ $# -eq 1 ]]; then
    prefix="$1"
fi

cd $prefix/c/unit/
./configure
make libunit-install
cd -
