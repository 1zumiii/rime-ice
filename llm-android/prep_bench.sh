cd /data/local/tmp/rimellm
export LD_LIBRARY_PATH=/data/local/tmp/rimellm QUIET=1 BENCH=prep
for T in 3 4; do for W in 40 80 150; do WAIT_MS=$W timeout 120 ./lua bench_android.lua . model.gguf . $T 80 2>/dev/null | tail -1; done; done
