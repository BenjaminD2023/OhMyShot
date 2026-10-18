#!/bin/sh
# fetch.sh REPO DEST: weights and configs at the repo's current revision from huggingface.co with curl,
# resumed until each file has its size, then checked against the Hub's SHA-256 for LFS files.
set -u
repo=$1; dest=$2; py=${PY:-python3}
mkdir -p "$dest"
"$py" -I -c "
import sys; from huggingface_hub import HfApi
i = HfApi().model_info(sys.argv[1], files_metadata=True)
print(i.sha)
for s in i.siblings:
    f = s.rfilename
    if f.endswith(('.json','.safetensors','.jinja','.model','.txt','.yml')) or f.startswith('LICENSE') or f == 'README.md':
        print(f, s.size or 0, (s.lfs.sha256 if s.lfs else '-'))" "$repo" > "$dest/.files" || exit 1
sha=$(head -1 "$dest/.files"); echo "$repo $sha" > "$dest/REVISION"
tail -n +2 "$dest/.files" | while read -r f size hash; do
  mkdir -p "$dest/$(dirname "$f")"
  while :; do
    have=$(stat -f %z "$dest/$f" 2>/dev/null || echo 0)
    [ "$have" -ge "$size" ] && break
    curl -sSfL -C - --speed-time 30 --speed-limit 10000 -o "$dest/$f" "https://huggingface.co/$repo/resolve/$sha/$f" 2>>"$dest/.curl.log" || sleep 2
  done
  if [ "$hash" != "-" ]; then
    got=$(shasum -a 256 "$dest/$f" | cut -d' ' -f1)
    [ "$got" = "$hash" ] && echo "ok $f" || echo "BAD SHA $f"
  fi
done
echo "done $repo"
