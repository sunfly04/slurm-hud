#!/bin/zsh
# Parser regression tests: feeds captured probe outputs to `SlurmHUD --parse` and diffs against *.expected.
# Run after ./build.sh. To accept a new intended output: SlurmHUD --parse X.txt > X.expected
cd "${0:A:h}"
B="${SLURMHUD_BIN:-$HOME/Applications/SlurmHUD.app/Contents/MacOS/SlurmHUD}"
fail=0
for f in *.txt; do
  if diff -u "${f%.txt}.expected" <("$B" --parse "$f") >/dev/null; then
    echo "ok   $f"
  else
    echo "FAIL $f"; diff -u "${f%.txt}.expected" <("$B" --parse "$f"); fail=1
  fi
done
exit $fail
