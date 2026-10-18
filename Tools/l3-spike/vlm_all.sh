#!/bin/zsh
# vlm_all.sh NAME: one VLM conversion's text, table, and formula runs, each inside `energy`, then their scores.
# NAME is a folder under $L3/mlx (paddle-16, glm-8, ...); results go to $L3/out/vlm/NAME/report.txt.
# $L3 holds venv/, mlx/, the compiled energy tool, and corpus/ (bench/, tables/, and the formula renders).
set -u
T=${0:A:h}; n=$1; PY=$L3/venv/bin/python
case $n in paddle*) text="OCR:";; glm*) text="Text Recognition:";; esac
o=$L3/out/vlm/$n; mkdir -p $o
run() { $L3/energy -- $PY -I $T/vlm_mlx.py $L3/mlx/$n "$1" $o/$2.json "${@:3}" 2> >(grep "^\[energy\]" > $o/$2.energy) | grep "^\[" > $o/$2.summary; }
run "$text" text $(ls $L3/corpus/bench/*.png | grep -v /table-)
run "Table Recognition:" table $L3/corpus/tables/*.png
run "Formula Recognition:" formula $L3/corpus/f*_*.png
{ cat $o/text.summary $o/text.energy; $PY -I $T/vlm_score.py text $L3/corpus/bench $o/text.json | tail -1
  cat $o/table.summary $o/table.energy; $PY -I $T/vlm_score.py table $L3/corpus/tables $o/table.json | tail -1
  cat $o/formula.summary $o/formula.energy; $PY -I $T/vlm_score.py formula $L3/corpus $o/formula.json; } > $o/report.txt 2>&1
cat $o/report.txt
