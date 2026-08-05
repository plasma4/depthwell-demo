#!/bin/bash

# start by building Zig code for release...
zig build -Dwasm-opt -Dgen-enums
if [ $? -ne 0 ]; then
    echo "Error: Zig build failed; commit stopped."
    exit 1
fi

# now build NPM public/ files...
npm run build
if [ $? -ne 0 ]; then
    echo "Error: NPM build failed; commit stopped."
    exit 1
fi

# done!
exit 0
