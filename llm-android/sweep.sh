cd /data/local/tmp/rimellm
export LD_LIBRARY_PATH=/data/local/tmp/rimellm QUIET=1
OUT=/data/local/tmp/rimellm/sweep2.out
: > $OUT
echo "legend: mask none=default scheduler(8 cores) | f8=cpu3-7 (4xA715+X3, 5 cores). threads never exceed the cores in the mask." >> $OUT
run() {  # repack mask threads
  R=$1; M=$2; T=$3
  if [ "$R" = 1 ]; then export REPACK=1; else export REPACK=0; fi
  if [ "$M" = none ]; then CMD="./lua"; else CMD="taskset $M ./lua"; fi
  LINE=$(timeout 90 $CMD bench_android.lua . model.gguf . $T 120 2>/dev/null | tail -1)
  [ -z "$LINE" ] && LINE="(timeout/no result)"
  echo "repack=$R mask=$M t=$T : $LINE" >> $OUT
}
for R in 0 1; do
  for T in 4 5 6 7 8; do run $R none $T; done
  for T in 3 4 5; do run $R f8 $T; done
done
echo DONE >> $OUT
