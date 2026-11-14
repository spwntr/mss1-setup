#!/usr/bin/env bash
#
# merge_gguf_model.sh — merge split GGUF shards into ONE big GGUF file
# using llama.cpp's gguf-split tool (--merge).
#
# Source shards are KEPT. The merged file is written next to them in
# ~/models.
#
# Usage:
#   ./merge_gguf_model.sh <file-or-shard.gguf> [merged-name.gguf]
#
#   <file-or-shard.gguf>
#       A single .gguf file, OR any one shard of a split model
#       (e.g. "model-Q4_K_M-00001-of-00004.gguf"). When a shard is given,
#       ALL sibling shards matching the same *-NNNNN-of-NNNNM pattern are
#       merged into one file.
#   [merged-name.gguf]
#       Output file name (default: <prefix>-merged.gguf, or <name>-merged.gguf).
#
# Examples:
#   ./merge_gguf_model.sh Qwen3.8-27B-BF16.gguf
#       -> merges/reads that single file, writes Qwen3.8-27B-BF16-merged.gguf
#
#   ./merge_gguf_model.sh Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf
#       -> finds all 4 shards of that split model, merges -> Qwen3-Coder-Next-Q4_K_M-merged.gguf
#

set -euo pipefail

MODELS_DIR="$HOME/models"
LLAMA_SPLIT="$HOME/llama.cpp/build/bin/llama-gguf-split"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: $0 <file-or-shard.gguf> [merged-name.gguf]"

INPUT="$1"
case "$INPUT" in
    /*) FIRST_FILE="$INPUT" ;;
    *)  FIRST_FILE="$MODELS_DIR/$INPUT" ;;
esac

[[ -f "$FIRST_FILE" ]] || die "file not found: $FIRST_FILE"
[[ "$FIRST_FILE" == *.gguf ]] || die "not a .gguf file: $FIRST_FILE"
[[ "$FIRST_FILE" == "$MODELS_DIR"/* ]] || die "file must be in $MODELS_DIR (the folder mounted into the Ollama container)"

# ── Discover shards ──────────────────────────────────────────────────────────
# Shard pattern: <prefix>-NNNNN-of-NNNNM.gguf  (numbers zero-padded to 5)
SHARD_RE='^(.+)-([0-9]{5})-of-([0-9]{5})\.gguf$'

if [[ "$(basename "$FIRST_FILE")" =~ $SHARD_RE ]]; then
    PREFIX="${BASH_REMATCH[1]}"
    TOTAL="${BASH_REMATCH[3]}"
    DIR="$(dirname "$FIRST_FILE")"

    FILES=()
    for i in $(seq 1 "$TOTAL"); do
        n=$(printf "%05d" "$i")
        f="$DIR/${PREFIX}-${n}-of-${TOTAL}.gguf"
        [[ -f "$f" ]] || die "missing shard: $f (expected $TOTAL shards of '$PREFIX')"
        FILES+=("$f")
    done
    echo ">> Found ${#FILES[@]} shards of '$PREFIX' (of $TOTAL)"

    if [[ $# -ge 2 ]]; then
        MERGED_NAME="$2"
    else
        MERGED_NAME="${PREFIX}-merged.gguf"
    fi
else
    FILES=("$FIRST_FILE")
    if [[ $# -ge 2 ]]; then
        MERGED_NAME="$2"
    else
        MERGED_NAME="$(basename "$FIRST_FILE" .gguf)-merged.gguf"
    fi
fi

# ── Merge via llama.cpp gguf-split tool ─────────────────────────────────────
[[ -x "$LLAMA_SPLIT" ]] || die "llama-gguf-split not found at $LLAMA_SPLIT (build it: cmake --build ~/llama.cpp/build --target llama-gguf-split)"

MERGED_FILE="$MODELS_DIR/$MERGED_NAME"
rm -f "$MERGED_FILE"   # tool refuses to overwrite an existing output

echo ">> Merging ${#FILES[@]} shard(s) → $MERGED_FILE ..."
# "--merge <first-shard> <output>" — the tool derives sibling shard paths from
# the split.count metadata in the first shard.
"$LLAMA_SPLIT" --merge "${FILES[0]}" "$MERGED_FILE" || die "llama-gguf-split --merge failed (source shards kept)"

echo ">> DONE. Merged file: $MERGED_FILE"
echo ">> Source shards kept:"
for f in "${FILES[@]}"; do
    echo "   $f"
done
echo ">> Intermediate merged file kept: $MERGED_FILE"

echo
echo "Done. Merge complete."
