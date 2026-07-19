# media-prereqs

Tier-0 media toolchain facts (`ffmpeg`, `yt-dlp`, `ImageMagick`) for `/youtube` and `/course-digest`. `command -v` + version floors only — no cookie/browser probing.

Owner: joint-consumer media skills. Entry: `check-media-prereqs.sh` (`--consumer youtube|course-digest|all`). Playwright probe: pass `--playwright-extraction-dir` from the calling skill's extraction package root (`/course-digest`, `/youtube`).
