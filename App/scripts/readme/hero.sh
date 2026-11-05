# The hero video, sourced by `App/scripts/readme.sh hero` after its setup (temp HOME, fixture
# `claude`, isolated pane shell, headless app). The app renders every 30 fps frame
# (lmux-apptest --hero, Hero.swift); ffmpeg only encodes them. Light and dark are two runs.
# The pane's `claude` streams in steps the harness drives (fake_claude.py's stepped mode).
#
#   docs/site/video/hero-{dark,light}.mp4    H.264, yuv420p, faststart (the site's hero)
#   docs/site/video/hero-{dark,light}.webm   VP9
#   docs/site/img/hero-{dark,light}{-1000,,-2400}.webp   posters (the first frame), 1000/1600/2400 px
#   assets/hero/hero-{dark,light}.webp       animated, for the README (the first beat, no camera moves)
#   assets/screenshots/hero-{dark,light}.png   the same first frame as the README still
#   assets/gifs/forget-x-{dark,light}.webp    the README's × clip (its own run, HERO_PASS=clip)
#
# HERO_CLIP_ONLY=1: only the × clip (the video, posters, stills and README hero are left alone).
#
# ffmpeg: the one on PATH, or FFMPEG=/path/to/ffmpeg.
FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"
[ -n "$FFMPEG" ] && [ -x "$FFMPEG" ] || { echo "hero: needs ffmpeg on PATH (or FFMPEG=/path/to/ffmpeg)" >&2; exit 1; }

# The fixture repos: lmux and its worktrees, one branch each.
for repo in lmux:fix/sidebar-redraw lmux-ime:fix/ime-jamo lmux-cmux:cmux-import \
            lmux-release:release/v0.1 lmux-site:main; do
  d="$T/home/code/${repo%%:*}"
  mkdir -p "$d/.git"
  echo "ref: refs/heads/${repo#*:}" > "$d/.git/HEAD"
done

# A steady cursor (a blinking one would come and go at random between frames), and type a
# size up from the default so the text reads at the README's width.
export LMUX_CONFIG_FILE="$T/hero-config"
printf "cursor-style-blink = false\nfont-size = 15\n" > "$LMUX_CONFIG_FILE"

# Where the README's cut ends (film seconds; Hero.swift writes its frames up to there).
export HERO_README_END="${HERO_README_END:-9.3}"
VID="$ROOT/docs/site/video" IMG="$ROOT/docs/site/img"
[ -n "$DRAFT" ] && VID="$DRAFT" IMG="$DRAFT"
mkdir -p "$VID" "$IMG"
# Color tags (BT.709 matrix): untagged video renders a shade off in some browsers.
COLOR=(-colorspace bt709 -color_primaries bt709 -color_trc bt709)
for m in ${HERO_THEMES:-dark light}; do
  H="$T/hero-$m"
  # The README's × clip: its own run of the film (Hero.swift, HERO_PASS=clip) that records only
  # from Claude's answer in "site" to the prompt gone, held on the pane, one caption. ~5.5 s; it
  # loops through a short dip to the terminal's background (a cross-fade would ghost: the WebP
  # encoder drops a fade's small steps). 1400 px (2x at the README's 700 pt), 24 fps of film
  # played 1.15x slower (setpts, 480/23 fps): watched at a glance, not followed.
  C="$T/clip-$m"; mkdir -p "$C/state" "$C/projects"
  cflag=(); [ "$m" = light ] && cflag=(--light)
  HERO_PASS=clip LMUX_STATE_DIR="$C/state" LMUX_CLAUDE_PROJECTS="$C/projects" FAKE_CLAUDE_DIR="$C/projects" \
    "$BIN/lmux-apptest" --hero "$C/out" ${cflag[@]+"${cflag[@]}"} 2>/dev/null | filter
  [ -f "$C/out/clip/f00000.png" ] || { echo "clip-$m: no frames" >&2; exit 1; }
  GIFS="$ROOT/assets/gifs"; [ -n "$DRAFT" ] && GIFS="$DRAFT"; mkdir -p "$GIFS"
  BG=0x2E3440; [ "$m" = light ] && BG=0xE5E9F0   # LmuxTokens.Colors.windowBackground
  CD=$(echo "scale=3; $(ls "$C/out/clip" | wc -l) / 30" | bc)
  "$FFMPEG" -y -loglevel error -framerate 30 -i "$C/out/clip/f%05d.png" -loop 1 -framerate 30 -t 0.2 -i "$C/out/clip/f00000.png" -filter_complex \
    "[0:v]fade=t=out:st=$(echo "$CD - 0.2" | bc):d=0.2:color=$BG[a];[1:v]fade=t=in:st=0:d=0.2:color=$BG[b];[a][b]concat=n=2:v=1:a=0,setpts=1.15*PTS,fps=480/23,scale=${HERO_CLIP_W:-1400}:-1:flags=lanczos" \
    -c:v libwebp_anim -lossless 0 -quality "${HERO_CLIP_Q:-95}" -compression_level 6 -loop 0 -an "$GIFS/forget-x-$m.webp"
  [ -n "${HERO_CLIP_ONLY:-}" ] && continue
  mkdir -p "$H/state" "$H/projects"
  flag=(); [ "$m" = light ] && flag=(--light)
  LMUX_STATE_DIR="$H/state" LMUX_CLAUDE_PROJECTS="$H/projects" FAKE_CLAUDE_DIR="$H/projects" \
    "$BIN/lmux-apptest" --hero "$H/out" ${flag[@]+"${flag[@]}"} 2>/dev/null | filter
  [ -f "$H/out/frames/f00000.png" ] || { echo "hero-$m: no frames" >&2; exit 1; }
  # HERO_FRAMES_ONLY=1 (with --draft): keep the frames for review, skip the encodes.
  if [ -n "${HERO_FRAMES_ONLY:-}" ]; then
    rm -rf "$DRAFT/frames-$m" "$DRAFT/readme-$m"; cp -R "$H/out/frames" "$DRAFT/frames-$m"; cp -R "$H/out/readme" "$DRAFT/readme-$m"; continue
  fi
  IN=(-framerate 30 -i "$H/out/frames/f%05d.png")
  VF=(-vf "scale=${HERO_VIDEO_W:-2000}:-2:out_color_matrix=bt709:out_range=tv:flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p")
  # Frames are 2400x1500; the video is 2000 wide (the stage is at most 1192 pt, so still ~2x on Retina), 30 fps.
  # Text is most of the picture: CRF 21 / VP9 33 keep glyph edges clean (checked at 100% against the
  # frames, no smearing while lines stream in or the camera eases); ~3.9 MB (H.264) / ~3 MB (VP9) for
  # the loop. The site loads it after the page.
  "$FFMPEG" -y -loglevel error "${IN[@]}" "${VF[@]}" -c:v libx264 -profile:v high -preset veryslow \
    -tune stillimage -crf "${HERO_CRF:-21}" -g 150 "${COLOR[@]}" -movflags +faststart -an "$VID/hero-$m.mp4"
  "$FFMPEG" -y -loglevel error "${IN[@]}" "${VF[@]}" -c:v libvpx-vp9 -crf "${HERO_VP9_CRF:-33}" -b:v 0 \
    -row-mt 1 -tile-columns 2 -deadline good -cpu-used 1 -g 150 "${COLOR[@]}" -an "$VID/hero-$m.webm"
  # Posters (the first frame) in the three widths the site's <picture> offers.
  "$FFMPEG" -y -loglevel error -i "$H/out/poster.png" -c:v libwebp -quality 90 "$IMG/hero-$m-2400.webp"
  for w in 1600 1000; do
    sfx="-$w"; [ "$w" = 1600 ] && sfx=""
    "$FFMPEG" -y -loglevel error -i "$H/out/poster.png" -vf "scale=$w:-1:flags=lanczos" -c:v libwebp -quality 90 "$IMG/hero-$m$sfx.webp"
  done
  # The README's hero: an animated WebP (GitHub won't autoplay video in a README; a GIF this
  # size is several MB and bands the colors). The window alone, no camera moves (readme/), the
  # video's first beat only (the prompt typed and answered beside Codex, ⇧⌘↩), its last half
  # second cross-fading into the first frame so it loops; 1800 px (2x on Retina at the README's 900 pt), 24 fps of film
  # played 1.15x slower (setpts, 480/23 fps) like the × clip, straight from the lossless
  # frames, quality 90: about 2 MB.
  README_ANIM="$ROOT/assets/hero"; [ -n "$DRAFT" ] && README_ANIM="$DRAFT"; mkdir -p "$README_ANIM"
  END="$HERO_README_END"
  "$FFMPEG" -y -loglevel error -framerate 30 -i "$H/out/readme/f%05d.png" -loop 1 -framerate 30 -t 1 -i "$H/out/readme/f00000.png" -filter_complex \
    "[0:v]trim=0:$END,setpts=PTS-STARTPTS,fps=30[a];[1:v]setpts=PTS-STARTPTS,fps=30[b];[a][b]xfade=transition=fade:duration=0.5:offset=$(echo "$END - 0.5" | bc),setpts=1.15*PTS,fps=480/23,scale=${HERO_README_W:-1800}:-1:flags=lanczos" \
    -c:v libwebp_anim -lossless 0 -quality "${HERO_README_Q:-90}" -compression_level 6 -loop 0 -an "$README_ANIM/hero-$m.webp"
  if [ -n "$DRAFT" ]; then
    cp "$H/out/hero.png" "$IMG/hero-$m.png"
    [ -n "${HERO_KEEP_FRAMES:-}" ] && rm -rf "$DRAFT/frames-$m" && cp -R "$H/out/frames" "$DRAFT/frames-$m"
  else
    cp "$H/out/hero.png" "$ROOT/assets/screenshots/hero-$m.png"
  fi
done
[ -n "${HERO_CLIP_ONLY:-}" ] && ls -l "$GIFS" || ls -l "$VID" "$IMG"
