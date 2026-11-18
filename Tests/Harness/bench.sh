#!/bin/zsh
# Japanese + Korean comparison on a Mac: speed (first text, sentence lag) and the English lines,
# for each engine setup the app offers. Synthesised speech is clean, so this compares setups;
# it does not predict accuracy on real videos, and Mac timings are not iPhone timings.
#   ./bench.sh            all arms
#   ./bench.sh apple      only arms whose name contains "apple"
set -e
cd "$(dirname "$0")"
WORK=${TMPDIR:-/tmp}/livesubs-harness
mkdir -p "$WORK/models"
P='[[slnc 900]]'
# Sentence-final verbs, a negation and a past tense: the hard case for live Japanese/Korean.
say -v Kyoko -o "$WORK/ja.aiff" "今日は東京の古い商店街を紹介します。$P このラーメン屋は五十年前から営業しています。$P 昨日は雨が降ったので、誰も来ませんでした。$P 正直に言うと、私はまだ一度も食べたことがありません。"
say -v Yuna -o "$WORK/ko.aiff" "오늘은 서울의 오래된 시장을 소개하겠습니다.$P 이 식당은 오십 년 동안 같은 자리에 있었습니다.$P 어제는 비가 와서 손님이 한 명도 오지 않았습니다.$P 솔직히 말하면, 저는 아직 한 번도 먹어 본 적이 없습니다."
for l in ja ko; do afconvert -f WAVE -d LEF32@16000 -c 1 "$WORK/$l.aiff" "$WORK/$l.wav"; done
swift build -c release --product Bench 2>&1 | grep -E "error|Compiling Bench|Build complete" || true
export LIVESUBS_MODELS_DIR="$WORK/models"

ARMS=(
  "whisper:openai_whisper-small_216MB"
  "whisper:openai_whisper-small_216MB:apple"
  "whisper:openai_whisper-small_216MB:apple:forced"
  "whisper:openai_whisper-large-v3-v20240930_626MB:apple"
  "whisper:openai_whisper-large-v3-v20240930_626MB:apple:forced"
  "apple"
)
echo "Reference (ja): Today I'll introduce an old shopping street in Tokyo. / This ramen shop has been open for fifty years. / It rained yesterday, so nobody came. / To be honest, I have never eaten it even once."
echo "Reference (ko): Today I'll introduce an old market in Seoul. / This restaurant has been in the same place for fifty years. / Yesterday it rained, so not a single customer came. / Honestly, I have never tried it even once."
for arm in $ARMS; do
  [[ -n "$1" && "$arm" != *"$1"* ]] && continue
  for l in ja ko; do .build/release/Bench "$arm" "$WORK/$l.wav" $l 2>&1 | grep -vE "^\s*$|Warning|warning" ; done
done
