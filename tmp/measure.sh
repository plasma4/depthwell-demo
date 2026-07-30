#!/bin/sh
# emits Debug LLVM IR into tmp/engine.ll and prints total lines + top functions
set -e
rm -rf tmp/probe-ir tmp/engine.ll
zig build-exe --stack 524288 -fno-strip -ODebug -target wasm32-freestanding \
  -mcpu baseline+bulk_memory+exception_handling+extended_const+multivalue+mutable_globals+nontrapping_fptoint+reference_types+sign_ext+simd128+tail_call \
  -Mroot=zig/root.zig --cache-dir tmp/probe-ir --name engine -rdynamic --export-table -fno-lto \
  -fno-emit-bin -femit-llvm-ir=tmp/engine.ll >/dev/null
wc -l < tmp/engine.ll | awk '{print "total IR lines: "$1}'
awk '/^define /{name=$0; sub(/^.*@"?/,"",name); sub(/"?\(.*/,"",name); cnt=0; inf=1} inf{cnt++} /^}/{if(inf){print cnt"\t"name; inf=0}}' tmp/engine.ll | sort -rn | head -15
