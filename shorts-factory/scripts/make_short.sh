#!/usr/bin/env bash
# make_short.sh — turns a set of character stills into a captioned, narrated
# 9:16 YouTube Shorts video using only free/open-source tools:
#   ffmpeg (Ken Burns pan/zoom, captions, mixing, encoding)
#   espeak-ng (offline text-to-speech narration)
# No paid APIs, no generative video credits.
#
# Usage: ./make_short.sh <episode_dir>
# <episode_dir> must contain a scenes.tsv file: one line per scene, tab-separated:
#   image_filename<TAB>caption/narration text
set -euo pipefail

EP_DIR="${1:?usage: make_short.sh <episode_dir>}"
SCENES_TSV="$EP_DIR/scenes.tsv"
WORK="$EP_DIR/_work"
OUT="$EP_DIR/output.mp4"

[ -f "$SCENES_TSV" ] || { echo "missing $SCENES_TSV" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/clips" "$WORK/audio"

W=1080
H=1920
FPS=30
VOICE="en-us+f3"
PITCH=55
SPEED=158
PAD_HEAD=0.35   # seconds of silence before each line starts
PAD_TAIL=0.45   # seconds of silence after each line ends (breathing room)
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf

i=0
CLIP_LIST="$WORK/clips.txt"
: > "$CLIP_LIST"
AUDIO_LIST="$WORK/audio.txt"
: > "$AUDIO_LIST"

while IFS=$'\t' read -r IMG TEXT <&3; do
  [ -z "$IMG" ] && continue
  i=$((i+1))
  n=$(printf "%02d" "$i")
  IMG_PATH="$EP_DIR/$IMG"
  [ -f "$IMG_PATH" ] || { echo "missing image $IMG_PATH" >&2; exit 1; }

  # 1. narration line -> wav
  LINE_WAV="$WORK/audio/${n}_line.wav"
  espeak-ng -v "$VOICE" -p "$PITCH" -s "$SPEED" -w "$LINE_WAV" "$TEXT"
  LINE_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$LINE_WAV")

  # 2. pad narration with head/tail silence -> scene audio, scene duration
  SCENE_DUR=$(python3 -c "print(f'{$PAD_HEAD+$LINE_DUR+$PAD_TAIL:.3f}')")
  SCENE_WAV="$WORK/audio/${n}_scene.wav"
  ffmpeg -y -v error -nostdin \
    -f lavfi -t "$PAD_HEAD" -i anullsrc=r=22050:cl=mono \
    -i "$LINE_WAV" \
    -f lavfi -t "$PAD_TAIL" -i anullsrc=r=22050:cl=mono \
    -filter_complex "[0:a][1:a][2:a]concat=n=3:v=0:a=1[a]" \
    -map "[a]" "$SCENE_WAV"
  echo "file '$(realpath "$SCENE_WAV")'" >> "$AUDIO_LIST"

  # 3. still image -> Ken Burns zoom/pan clip, cropped to 9:16, held for SCENE_DUR
  # alternate zoom direction per scene for visual variety
  if [ $((i % 2)) -eq 0 ]; then
    ZEXPR="zoom+0.0016"
  else
    ZEXPR="if(lte(zoom\,1.0)\,1.05\,zoom+0.0016)"
  fi
  FRAMES=$(python3 -c "print(int(round($SCENE_DUR*$FPS)))")
  FADE_OUT_ST=$(python3 -c "print(f'{max($SCENE_DUR-0.25,0):.3f}')")
  CLIP_MP4="$WORK/clips/${n}.mp4"
  ffmpeg -y -v error -nostdin -loop 1 -i "$IMG_PATH" \
    -vf "scale=${W}*1.15:${H}*1.15:force_original_aspect_ratio=increase,crop=${W}*1.15:${H}*1.15,zoompan=z='${ZEXPR}':d=${FRAMES}:s=${W}x${H}:fps=${FPS},format=yuv420p,fade=t=in:st=0:d=0.25,fade=t=out:st=${FADE_OUT_ST}:d=0.25" \
    -t "$SCENE_DUR" -an "$CLIP_MP4"
  echo "file '$(realpath "$CLIP_MP4")'" >> "$CLIP_LIST"

  # stash caption text + timing for the drawtext pass
  echo -e "${n}\t${TEXT}" >> "$WORK/captions.tsv"
done 3< "$SCENES_TSV"

# 4. concat video-only clips
SILENT_MP4="$WORK/silent.mp4"
ffmpeg -y -v error -nostdin -f concat -safe 0 -i "$CLIP_LIST" -c copy "$SILENT_MP4"

# 5. concat narration/silence track
NARRATION_WAV="$WORK/narration.wav"
ffmpeg -y -v error -nostdin -f concat -safe 0 -i "$AUDIO_LIST" -c copy "$NARRATION_WAV"
TOTAL_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$NARRATION_WAV")

# 6. simple royalty-free chiptune background bed (self-synthesized sine arpeggio, no licensing needed)
MUSIC_WAV="$WORK/music.wav"
ffmpeg -y -v error -nostdin -filter_complex \
  "sine=frequency=523.25:duration=${TOTAL_DUR}[a];sine=frequency=659.25:duration=${TOTAL_DUR}[b];sine=frequency=783.99:duration=${TOTAL_DUR}[c];[a][b][c]amix=inputs=3:duration=longest,volume=0.05[out]" \
  -map "[out]" "$MUSIC_WAV"

# 7. mix narration (full volume) with music bed (background)
MIXED_WAV="$WORK/mixed.wav"
ffmpeg -y -v error -nostdin -i "$NARRATION_WAV" -i "$MUSIC_WAV" \
  -filter_complex "[0:a]volume=1.0[n];[1:a]volume=1.0[m];[n][m]amix=inputs=2:duration=first:dropout_transition=0[a]" \
  -map "[a]" -ac 2 "$MIXED_WAV"

# 8. burned-in captions, one drawtext per scene, timed to scene boundaries
DRAWTEXT_FILTER=""
t0=0
while IFS=$'\t' read -r n TEXT; do
  CLIP_MP4="$WORK/clips/${n}.mp4"
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$CLIP_MP4")
  t1=$(python3 -c "print(f'{$t0+$DUR:.3f}')")
  ESCAPED=$(printf '%s' "$TEXT" | sed "s/'/\\\\'/g" | sed "s/:/\\\\:/g")
  SEG="drawtext=fontfile=${FONT}:text='${ESCAPED}':fontsize=44:fontcolor=white:borderw=5:bordercolor=black:box=1:boxcolor=black@0.35:boxborderw=18:x=(w-text_w)/2:y=h-320:enable='between(t,${t0},${t1})'"
  if [ -z "$DRAWTEXT_FILTER" ]; then
    DRAWTEXT_FILTER="$SEG"
  else
    DRAWTEXT_FILTER="${DRAWTEXT_FILTER},${SEG}"
  fi
  t0="$t1"
done < "$WORK/captions.tsv"

CAPTIONED_MP4="$WORK/captioned.mp4"
ffmpeg -y -v error -nostdin -i "$SILENT_MP4" -vf "$DRAWTEXT_FILTER" -c:v libx264 -pix_fmt yuv420p -an "$CAPTIONED_MP4"

# 9. final mux
ffmpeg -y -v error -nostdin -i "$CAPTIONED_MP4" -i "$MIXED_WAV" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 160k -shortest "$OUT"

echo "Done: $OUT"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT"
