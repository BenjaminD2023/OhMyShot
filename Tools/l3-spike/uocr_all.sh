#!/bin/zsh
# uocr_all.sh NAME: Unlimited-OCR 2's text, table, formula, whole-screen, and tall-page runs, each inside `energy`, then
# their scores. NAME is a folder under $L3/models (uocr2-8, ...); results go to $L3/out/uocr/NAME/report.txt.
# $L3 holds venv-uocr/ (mlx-vlm 0.7.11), models/, the compiled energy tool, and corpus/ (bench/, tables/, screens/,
# and the formula renders). The tall page is read whole, and cut into bands as a document of several pages.
set -u
T=${0:A:h}; n=$1; PY=$L3/venv-uocr/bin/python
o=$L3/out/uocr/$n; mkdir -p $o
run() { $L3/energy -- $PY -I $T/uocr_mlx.py $L3/models/$n $o/$1.json "${@:2}" 2> >(grep "^\[energy\]" > $o/$1.energy) | tee $o/$1.log | grep "^\[" > $o/$1.summary; }
run text $(/bin/ls $L3/corpus/bench/*.png | grep -v /table-)
run table $L3/corpus/tables/*.png
run screen $L3/corpus/screens/*.png
run tall --bands 1128 $L3/corpus/bench/tall-page.png
run formula $L3/corpus/f*_*.png
{ cat $o/text.summary $o/text.energy; $PY -I $T/vlm_score.py text $L3/corpus/bench $o/text.json | tail -1
  cat $o/table.summary $o/table.energy; $PY -I $T/vlm_score.py table $L3/corpus/tables $o/table.json | tail -1
  cat $o/screen.summary $o/screen.energy; $PY -I $T/screen_score.py $L3/corpus/screens $o/screen.json | tail -1
  cat $o/tall.summary; $PY -I $T/vlm_score.py text $L3/corpus/bench $o/tall.json | tail -1
  cat $o/formula.summary $o/formula.energy; $PY -I $T/vlm_score.py formula $L3/corpus $o/formula.json; } > $o/report.txt 2>&1
cat $o/report.txt
