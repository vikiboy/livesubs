#!/bin/zsh
# End-to-end engine check on a Mac (no iPhone needed).
# Synthesises Spanish then German speech with macOS TTS, then streams it through the
# app's real segmenter + Whisper pipeline in real time and prints the English subtitles.
set -e
cd "$(dirname "$0")"
MODEL=${1:-openai_whisper-tiny}
WORK=${TMPDIR:-/tmp}/livesubs-harness
mkdir -p "$WORK/models"
say -v "Eddy (Spanish (Spain))" -o "$WORK/es.aiff" "Hola a todos. Hoy vamos a hablar de la historia de Madrid. La ciudad tiene muchos museos y parques muy bonitos."
say -v "Anna" -o "$WORK/de.aiff" "Guten Morgen. Das Wetter ist heute sehr schön, und wir gehen in den Park."
afconvert -f WAVE -d LEF32@16000 -c 1 "$WORK/es.aiff" "$WORK/es.wav"
afconvert -f WAVE -d LEF32@16000 -c 1 "$WORK/de.aiff" "$WORK/de.wav"
swift build -c release --product Harness
export LIVESUBS_MODELS_DIR="$WORK/models"
echo "=== Spanish (auto-detect) ==="
.build/release/Harness "$MODEL" "$WORK/es.wav"
echo "=== German (auto-detect) ==="
.build/release/Harness "$MODEL" "$WORK/de.wav"
