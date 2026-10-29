# Mimic demo video: prompt for a Code session on the Mac

**For Sergio, not part of the prompt.** Start a new Code session yourself in the Claude desktop app
on the Mac mini (computer use only works in a session you start), then paste everything below the
line. It works without you for a few hours. It controls the screen while it lays out windows and
records, and it says before each time it takes control. It will stop and ask if it needs a
permission or a sign-in.

Before you paste it, install Remotion's official plugin in that session, because skills added in the
middle of a session may not load. In the desktop app, open Plugins, then Discover, and add
"remotion". Or in a terminal: `claude plugin marketplace add remotion-dev/claude-code-plugin` and
then `claude plugin install remotion@remotion`.

Expect a first cut to review, not a finished film. People who make these videos with agents report
several rounds of feedback. When it's done, watch it and tell the session what to change.

---

You are making a short demo video of Mimic, my free, open-source macOS app for local mock API
servers (https://mimic-mock.app, https://github.com/srpadrono/mimic). You set it up, film it, edit
it and check it, using shell commands and computer use on this Mac. Tell me before each time you
take control of the screen.

## What the video is

A developer shows a real bug and the real way it gets caught. Somebody who builds apps should watch
it and think "I have that bug" and then "I could test for that tomorrow". It should look like a
careful engineer recorded it on a good day: their own screen, real apps, real output, cut tightly.
It should not look like an ad.

**The story.** Acme Store is a small Mac shop app that talks to three backends: Auth, Catalog and
Payments. Its API spec says that when Payments answers `503` with `Retry-After`, the app must try
`POST /orders` up to three times before giving up. The app gives up after two. On screen the
customer sees "Payments is busy. Retrying (2 of 3)…", then a red "Payments is unavailable", and no
third try ever happens. The order is lost because the payment service was busy for a second.

Nobody catches this by hand, because you can't make a real payment provider return a `503` when you
want one. Mimic sits between the app and its three backends, records one checkout, and then lets
anyone (here, a Claude Code agent driving Mimic's CLI) script every way those backends can answer.
The agent tests checkout against the spec, finds the one scenario that fails, makes a one-line fix,
and shows every scenario passing.

This is the same app and the same bug as the Mimic blog post "Close the loop: let your coding agent
test what it builds", so keep the facts consistent with it.

### What went wrong last time, so you don't repeat it

The last attempt (an airport lookup app on the iPhone simulator) failed in ways you can see:

- The whole ultrawide desktop was squeezed into 1080p, so no text could be read. Most of the Mimic
  window was empty ("No endpoint selected", "Mock your first endpoint"), and the dark theme turned
  everything into murky grey.
- About 50 of its 82 seconds were frozen frames, and the voiceover had gaps of four to seven
  seconds.
- The terminal mostly showed "This command requires approval" prompts for chained shell commands.
- The agent couldn't drive the simulator, so a person tapped Retry at the end, and the voiceover had
  to admit it.
- Captions sat on top of the UI they described. "Sped up" stayed on screen for most of the video.
- The end card was pale grey text on white that you could hardly see.
- The scenario itself, a stuck airport search, was a toy that nobody cares about.

Every rule below exists to fix one of these.

## Hard rules

- **Everything on camera is real.** Never type for the filmed agent, edit its output, or stage a
  result. If a take goes wrong, fix the setup and record again. Moving the camera is fine:
  arranging windows, switching a Mimic tab, selecting a journey so its steps are visible. List
  every camera move in the deliverables README.
- **Only claim what happened.** Every number in the voiceover, captions and post (attempts,
  scenarios, pass counts, lines changed) comes from the recording or the agent's report. If the
  agent finds something different from what this brief expects, tell that story, or stop and ask
  me.
- **Only show real Mimic features.** Before you write any narration, read the Mimic README,
  `docs/CLI.md`, `docs/JOURNEYS.md` and `docs/ROADMAP.md`. Don't mention anything that isn't in
  them, and remember Mimic matches on method, path and GraphQL operation only.
- **Stay in your lane on disk.** Work only in `~/MimicDemo/` and in the Mimic project called
  "Acme Store". Don't open, change or delete my other Mimic projects (for example "AirportLookup"
  and "Web Concept Live"). Don't create anything under `~/Documents`.
- **No secrets on screen or in files.** ElevenLabs reads its key from `ELEVENLABS_API_KEY`; never
  print it. Before you record, close or hide anything personal: mail, messages, browser tabs,
  notifications, other projects' names.
- **Don't publish anything.** The deliverables are files for me to review.

**If `~/MimicDemo/prep-done.md` exists**, an earlier session already did steps 0 to 2. Read it,
check its claims quickly (`mimic ping`, the build, the baseline commit, the Remotion plugin), and
go straight to step 3.

## 0. Check the Mac (no screen control)

Report each of these in one line. Stop and tell me if one fails; don't work around it.

```bash
sw_vers; xcodebuild -version | head -1
mimic --version; mimic ping; mimic state | head -c 400     # Mimic 0.15.0 or later
which claude && claude --version                            # the CLI that will be filmed
which ffmpeg node npm python3
system_profiler SPDisplaysDataType | grep -E "Resolution|Retina|Main Display"
echo "ELEVENLABS_API_KEY is ${ELEVENLABS_API_KEY:+set}"
claude plugin list 2>/dev/null | grep -i remotion             # Remotion's official plugin
```

If the Remotion plugin isn't installed, ask me to install it and start a new session. Don't
install other video skills or plugins.

The CLI finds the sandboxed app through `control.json` in `~/Library/Containers/devxa.Mimic`.
That needs Full Disk Access for the terminal running it. Ghostty already has it; check `mimic ping`
from Ghostty, not only from your own shell.

## 1. Get the app and build it (no screen control)

Acme Store lives in the Mimic repo on the branch `claude/project-thread-uyew1l` (PR #149, still a
draft) in `docs/examples/acme-store`. My Mimic checkout is `~/Developer/Mimic`.

```bash
cd ~/Developer/Mimic && git fetch origin claude/project-thread-uyew1l
# Reuse the blog's worktree if it exists, otherwise make one. Never inside ~/Documents.
[ -d ~/Developer/mimic-acme ] || git worktree add ~/Developer/mimic-acme origin/claude/project-thread-uyew1l
cd ~/Developer/mimic-acme && git pull --ff-only origin claude/project-thread-uyew1l || true
cd docs/examples/acme-store && swift build -c release 2>&1 | tail -30
```

The Swift app may never have been compiled on a Mac. If it doesn't build, fix it with the smallest
change, commit it in the worktree, and push with `git push origin HEAD:claude/project-thread-uyew1l`
so the blog and the video use the same code. Note every fix. **Never fix the retry condition in
`Store.checkout()` (`attempt < maxPaymentAttempts - 1`) in the repo.** That bug is the story.

Now make the filmed copy, so the agent works in a clean folder with its own history:

```bash
mkdir -p ~/MimicDemo && rm -rf ~/MimicDemo/acme-store
cp -R ~/Developer/mimic-acme/docs/examples/acme-store ~/MimicDemo/acme-store
cd ~/MimicDemo/acme-store
rm -rf qa/reference .build          # the answer key must not be on disk while the agent works
```

Keep a copy of `qa/reference/scenarios.sh` outside that folder (for example
`~/MimicDemo/reference/`) in case you need to rebuild the journeys without an agent. Check whether
anything in the copy still refers to `qa/reference`, and adjust only the wording in
`qa/QA_PROMPT.md` that tells the agent not to read it.

Give the filmed agent permission for this job, so the recording isn't a wall of approval prompts.
Create `~/MimicDemo/acme-store/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(mimic:*)", "Bash(mimic/run.sh:*)", "Bash(swift build:*)",
      "Bash(git diff:*)", "Bash(git status:*)", "Bash(ls:*)", "Bash(cat:*)",
      "Read", "Edit", "Write", "Glob", "Grep"
    ]
  }
}
```

Then add one sentence to the end of `qa/QA_PROMPT.md`: "Run one command per tool call, without
`;`, `&&`, pipes or shell variables, so each command is easy to read on screen. Write your final
report to qa-report.md." Commit the folder as the baseline:

```bash
git init -q && git add -A && git commit -qm "Baseline for the demo recording"
swift build -c release 2>&1 | tail -3
```

Every retake starts from `git reset --hard && git clean -fd -e .build` in this folder.

## 2. Dry run (off camera, no recording)

Do the whole thing once without recording, so you know it works and how long each part takes.

```bash
cd ~/MimicDemo/acme-store
python3 backend/acme_backend.py > ~/MimicDemo/backend.log 2>&1 &   # the stand-in "real" backend
mimic/setup.sh --fresh          # deletes and recreates only the "Acme Store" project
mimic/run.sh --none             # one checkout through Mimic, recording every response
kill %1                         # from here on Mimic answers everything
```

Then start the filmed agent the same way you will on camera (step 4) and let it run to the end with
no help. Expected: it reads the recorded log, `openapi.yaml` and `Store.swift`, plans about seven
scenarios, creates them as journeys in the group "Checkout QA", runs each with `mimic/run.sh`, finds
that "payments busy" fails (two `POST /orders`, not three), changes the condition, rebuilds, and
reruns everything green.

Write down what really happened and how long each phase took. If it stalls, asks questions, or hits
permission prompts, fix the setup (settings, prompt wording, build) and dry-run again. Don't fix it
by coaching the agent on camera. When it gets through on its own, reset to the baseline and run
`mimic/setup.sh --fresh` again.

## 3. Set up the screen

The frame is a 16:9 region of the screen, not the whole desktop. Find the main display's size and
scale factor from step 0.

- **Region.** Pick a 16:9 rectangle of about 1600 × 900 points on the main display. Everything
  filmed sits inside it, and nothing else on the desktop is ever in the shot. On a Retina display
  that region is 3200 × 1800 pixels, which gives you room for sharp zooms in a 1080p export. If the
  display isn't Retina, switch it to a HiDPI mode if one exists. If not, make the region smaller
  (about 1280 × 720) and keep zooms below 1.3×.
- **Layout inside the region.**
  - Left: Acme Store at its natural size (about 460 × 760). Its network strip at the bottom shows
    every call and its status, which is the best shot in the video, so keep it whole.
  - Right, top: Mimic, showing the navigator (Journeys tab during the agent's run), the selected
    journey's steps, and the request log. Size it so log rows are readable at 1080p.
  - Right, bottom: Ghostty for the filmed agent. Font at least 18 pt, a clean prompt, history
    cleared, a short window title.
- **Look.** Light appearance for macOS, Mimic and Acme Store. A plain mid-grey desktop picture.
  Ghostty with a high-contrast theme. Cursor size a little larger (Accessibility > Display >
  Pointer, about 1.5) so clicks are easy to follow.
- **Quiet.** Turn on Do Not Disturb, hide the Dock, quit anything that could show a banner or an
  update prompt. Put all of these back at the end.
- **Mimic window state.** Before each take, make sure no panel shows an empty placeholder. Select
  the Payments `POST /orders` endpoint or the journey being run, so the editor and steps have
  content.

Take one still of the layout, crop it to the region, and look at it scaled to 1920 × 1080. If you
can't read a request log row or a terminal line at that size, change the layout before recording.

## 4. Record

Record the region at native resolution, 60 fps, with the cursor. Prefer `screencapture -v -R
x,y,w,h -k <file>.mov` (stop it with `kill -INT`). If that doesn't work here, record the display
with ffmpeg avfoundation and crop later. Keep a `beats.md` log with the second of every important
moment as it happens: each journey created, each run, the failure, the edit, each rerun.

Record these as separate files. All are real runs.

1. **`a-record.mov`, the recording.** Stand-in backend running, `mimic/setup.sh --fresh` already
   done, Mimic showing the empty Endpoints tab and request log. Run `mimic/run.sh --none` in
   Ghostty. The app signs in, adds two products and pays. Mimic's log fills with forwarded calls
   and the endpoints list fills with captured responses. Stop 3 seconds after the receipt. Then
   stop the backend.
2. **`b-agent.mov`, the agent's whole run, one continuous take.** Switch Mimic to the Journeys tab.
   In Ghostty, in `~/MimicDemo/acme-store`, run `claude` and paste the contents of
   `qa/QA_PROMPT.md` as its first message. Don't touch the keyboard again until it finishes. You
   can select the journey being run in Mimic's navigator so its steps show; log those camera moves.
   Stop when it has written `qa-report.md`. Save `git diff > ~/MimicDemo/output/agent-diff.txt`.
3. **`c-bug.mov` and `d-fixed.mov`, the hero shots.** These are cleaner, closer replays of the two
   moments that matter. With the agent's fix stashed (`git stash`, `swift build -c release`),
   select the payments-busy journey in Mimic and run `ACME_LINGER=3 mimic/run.sh "<that journey's
   name>"`. This is the bug: 503, 503, red banner. Then `git stash pop`, rebuild, and record the
   same run again: 503, 503, 201, receipt. Record each twice and keep the cleaner take.

If the agent's run in `b-agent.mov` goes off course (stuck, asks for help, a permission prompt you
didn't plan for), stop, fix the setup, reset to the baseline, and record it again. A bad take is
not a story.

## 5. Edit

Build the edit in Remotion (React, frame-accurate) so every zoom, ramp and caption is animated in
code, from the full-resolution sources. Use the Remotion plugin's skills and read Remotion's docs
for agents (https://www.remotion.dev/docs/ai) before you start.

**Mechanics that break agent-made edits. Get these right first.**

- Pin every `remotion` and `@remotion/*` package to the same exact version. Mismatched versions
  are the most common render failure.
- Check each source's real frame rate and size with `ffprobe` and set the composition to match.
  Play footage with `<OffthreadVideo>`. Don't let 30 fps and 60 fps footage mix by accident.
- Use `interpolate` with clamping, `spring()` and Remotion's seeded `random()`. Never use
  `Math.random()` or wall-clock time.
- Render a low-scale or frame-range preview before every full render. A Studio preview that
  plays is not proof the render works.
- Never use ffmpeg's `-shortest` when muxing. It silently cuts the end of the narration. Pad each
  audio clip to its scene length with `apad=whole_dur` instead of chaining clips back to back, or
  the sync drifts.
- If an asset is missing, fail loudly. Never fall back to a placeholder.
- Commit the Remotion project in `~/MimicDemo/edit` after each scene works.

**Storyboard first.** Before you write any edit code, write `~/MimicDemo/edit/storyboard.md` with
one row per shot: time, source file and timestamp from `beats.md`, framing (which region, zoom
level), the exact on-screen text you'll highlight, and the narration line. Take the on-screen text
from the recordings, never from memory. Made-up UI text is the clearest sign of a fake demo. Then
build one scene at a time, render one still per scene, and look at it before you go on.

**Length and format.** 70 to 90 seconds. 1920 × 1080 at 60 fps (screen footage looks smoother at
60), H.264 High, yuv420p, bt709 tags, AAC 48 kHz, `+faststart`. If the sources are Retina, also
render a 3840 × 2160 master.

**Beats.** Times are targets. The picture decides the final timing.

| Time | Picture | What it says |
| --- | --- | --- |
| 0:00 to 0:07 | `c-bug`, framed on Acme Store. "Retrying (2 of 3)…", then the red banner, and the network strip showing `POST /orders 503` twice. | The checkout failed because Payments was busy, and the app gave up a try early. |
| 0:07 to 0:14 | Cut to `openapi.yaml` in an editor, already framed on the line "Clients make up to 3 attempts in total", with that line highlighted. | The spec says three. You can't make a real payment service return a 503 on cue, so this kind of bug ships. |
| 0:14 to 0:24 | `a-record`: the checkout passing through Mimic, the log filling with forwarded calls, the endpoints appearing. | Mimic sits between the app and its three backends. One checkout through it, and it holds a response for every call. |
| 0:24 to 0:50 | `b-agent`, sped up with eased ramps: the prompt going in, the agent's scenario table, `mimic journey create` and `step add` commands, and the journeys appearing in Mimic's navigator as it creates them. Then the runs, one after another, with the network strip changing each time. | I give checkout to Claude Code. It reads the spec, the recording and the code, and scripts each case as a Mimic journey from the command line. It runs the app through all of them. |
| 0:50 to 0:58 | Real speed. The failing run's output, the request log with two `POST /orders`, the agent saying why. | One fails: two attempts, not three. |
| 0:58 to 1:06 | The agent's diff, zoomed in the terminal so it's readable. Use a code card only if the terminal can't be read, and then only the verbatim lines. | The fix is one line. |
| 1:06 to 1:16 | `d-fixed`: 503, 503, 201, "Order placed". Mimic's journey shows every step served. Then the agent's final table. | Same journey again: busy, busy, paid. All of them pass. |
| 1:16 to 1:24 | End card. | Mimic. Free and open source, for the Mac. |

Open on the bug, not on a logo or a title. The first frame should already be the app, and with the
sound off it should read like a headline: a red banner in a checkout. Videos that open on a title
card do worst on X; ones that show the problem in the first three seconds do best.

**Camera.**

- Move only when it shows something. Zoom to between 1.6× and 2× (less is barely visible, more
  loses context; on non-Retina sources stay at 1.3× or less). Ease in over about 0.3 to 0.4
  seconds, ease out over about 0.35 to 0.5 seconds, and hold 1 to 2 seconds once it lands, longer if
  the viewer has to read. Pull back out to the full frame between zooms rather than panning from
  one zoom to the next for the whole video.
- No slow drifting zooms, no Ken Burns. They read as filler.
- Don't use the same ease on everything, Remotion's default springy bounce, or a fade-and-slide-up
  on every label. Those are what make motion look generated. Most things should simply cut.
- No shot shorter than 1 second.
- Never jump-cut inside the same shot. To skip time, use a speed ramp or a short cross-dissolve.
- Speed up the agent's waiting with eased ramps (up to about 20×). While a ramp runs, show a small,
  quiet label in one corner with the speed and the real elapsed time of the agent's run, for
  example "12× · agent running 6:40". It tells viewers the run was real and how long it took.
  Remove it at real speed.
- No still frame longer than 1.5 seconds unless the voice is talking over something worth reading.
- Highlight with restraint: a thin rounded outline or a soft dim of everything else, on the three
  `POST /orders` rows, the banner, the diff line. No arrows, emoji, glows or shakes.

**Type.** One family (SF Pro or Inter), two sizes at most, and no text in the video smaller than
28 px at 1080p, including UI text inside a zoom. Check UI text by looking at a still on a phone-sized
view. Captions burned in, at the bottom, on a
subtle dark pill, at most two lines of about 42 characters each, timed phrase by phrase. Place them
so they never cover the area the shot is about: frame the zooms so the bottom band is free. Also
render a version with no captions, and a `captions.srt`.

**End card.** Mimic's app icon (`App/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`
in the repo), the name, one line ("Local mock APIs for macOS"), `brew install --cask
srpadrono/tap/mimic` in monospace, and `mimic-mock.app`. Dark text on a light background, or the
other way round, with real contrast (at least 7:1). Hold it 4 seconds, and let it fade from the
last shot instead of cutting.

If PR #149 has been merged when you finish, add `github.com/srpadrono/mimic`, "docs/examples/acme-store"
to the end card, so viewers can run the same test. If it hasn't, leave that out.

**Sound.** Voice only. No music bed, no whooshes. Keep the voice continuous over the cuts.

## 6. Voice

Write the narration after the picture is locked, timed to it. Write it the way an engineer talks to
a colleague who is looking at their screen: first person, short sentences, concrete things on the
screen. Every sentence is about something the viewer can see right then.

Rules for the voiceover, captions and post:

- One idea per sentence, real details only. Say "five-oh-three" the way engineers say it.
- No hype or SaaS words: seamless, effortless, powerful, supercharge, unlock, game-changer,
  revolutionize, magic, just works, in seconds, imagine, meet. No rhetorical questions, no em
  dashes, no exclamation marks, no hashtags, no invented numbers or users.
- If a line could appear in any product ad, cut it.
- Don't overclaim the backend. The "real" services here are a local stand-in, so say "the backend"
  or "a checkout", not "production" or "the live payment provider".

A reference for tone and length (about 150 words), to rewrite against the real picture and the
real numbers, not to read as is:

> This checkout just told a customer their payment failed. Payments was only busy. It sent a
> five-oh-three and asked us to retry in a second, and the app gave up after two tries.
> The spec says three. You can't make a real payment service fail on cue, so bugs like this ship.
> Mimic sits between the app and its three backends. I run one checkout through it, and it keeps
> every response.
> Then I hand checkout to Claude Code. It reads the spec, the recording and the app code, and
> scripts each case as a Mimic journey: a declined card, an expired session, an item that sells
> out, a slow catalog, payments busy.
> It runs the app through every one. One fails. Two attempts at the order, not three.
> The fix is one line.
> Same journey again. Busy, busy, paid. All seven pass.
> Mimic is free and open source, for the Mac.

Keep it to about 150 words for 80 seconds (around 140 words a minute, with room to breathe).

Generate it with ElevenLabs, voice Liam (`TX3LPaxmHKxFdv7VOQHJ`). Generate one clip per sentence,
passing `previous_text` and `next_text` so the delivery joins up. Measure each clip with `ffprobe`
and let those lengths set each scene's timing and each caption's timing. Never stretch audio to fit
picture. For a calm, conversational read, try `eleven_multilingual_v2` with stability about 0.75,
similarity about 0.9 and style 0 to 0.1, then try `eleven_v3` in its natural setting, and keep
whichever sounds less like a trailer. Generate three takes of each line and keep the best. Put
pauses in as silence during the edit; don't rely on ellipses in the text. No gap over 1.2 seconds
while the picture is busy.

Master the voice: high-pass at 80 Hz, light compression, a gentle de-ess, then loudnorm the final
mix to -14 LUFS integrated and -1.5 dBTP true peak. Transcribe the result locally with whisper.cpp
(installed through Remotion's `@remotion/install-whisper-cpp` package) and check "Mimic",
"Claude", "five-oh-three", "Acme", "journey". Use the same word timings for the captions.

Also save `narration-teleprompter.md`: the same script with a timestamp per line. I may record my
own voice over the locked picture later and swap it in.

## 7. Check before you call it done

Watch it as a stranger would, then check it as an editor:

- Extract a frame every 0.5 seconds and look at all of them. Every frame should be sharp, framed
  on purpose, and readable at 1080p. Nothing personal, no empty Mimic panels, no approval prompts
  you didn't cut.
- `ffmpeg -vf blackdetect` and `freezedetect=n=0.003:d=1.5` find nothing outside the end card.
- `silencedetect=n=-40dB:d=1.5` finds no gap except before the end card.
- Each caption matches the voice word for word and appears while that thing is on screen.
- Each claim matches `beats.md` and `qa-report.md`. If the agent found six scenarios, say six.
- Play the first 3 seconds with the sound off. A developer should already see that something is
  wrong with a checkout.
- Make a 1280-wide still sheet of the whole video and look at it as one image. If more than a
  third of the frames look the same, the edit is too slow.

- Look at the stills twice: once at the 0.5 second marks, then again shifted by a quarter second,
  because problems hide between samples.
- Get a second opinion from fresh eyes. Start three reviewer subagents with no context except the
  storyboard, the writing rules above and the frames: one for readability and framing, one for
  pacing and motion, one for truth (every on-screen claim and caption against `beats.md`,
  `qa-report.md` and the raw takes). You built it, so you will see what you meant, not what is
  there. The truth reviewer has the final say.
- `ffprobe` the final file: length, 1920 × 1080, 60 fps, both streams present, and loudness
  within 1 LU of -14 LUFS.

Fix what you find and render again. Stop after three rounds of fixes on the same scene and tell me
what's still wrong instead of going round again. Frames can't show how motion feels and you can't
hear pronunciation, so end with a short list of exactly what I should watch and listen for.

## Deliverables in `~/MimicDemo/output/`

- `mimic-checkout-bug.mp4`, the final cut with captions, and `mimic-checkout-bug-clean.mp4` without
- `mimic-checkout-bug-2160p.mp4` if the sources allow it
- `mimic-checkout-bug-loop.mp4` and `mimic-checkout-bug-loop-poster.jpg`: a silent 8 to 15 second
  loop for the landing page, from 503, 503, red banner to 503, 503, 201, receipt, looping
  cleanly with no text except what the apps show
- `mimic-checkout-bug-uncut.mp4`: the whole agent take at real speed with a one-line title card,
  for anyone who wants to see the full run
- the raw takes (`a-record.mov`, `b-agent.mov`, `c-bug.mov`, `d-fixed.mov`) and `beats.md`
- `agent-diff.txt` and `qa-report.md`, the filmed agent's own change and report
- `narration.txt`, `narration-teleprompter.md`, `captions.srt`
- the Remotion project in `~/MimicDemo/edit`, with `storyboard.md`, so changes are easy to make
- `x-post.md`: a post for @DEVXA_LTD, at most 280 characters including https://mimic-mock.app,
  same writing rules, true to what happened
- `README.md`: what each file is, every camera move and anything done by hand, every build fix
  pushed to the branch, how long the agent ran, and anything that looked wrong

Then reset the screen (Dock, Do Not Disturb, cursor size, desktop picture), leave `~/MimicDemo` and
the Acme Store project in place, and tell me in plain words what you made and anything I should
look at first, so I can paste it back to the project thread.

Stop and tell me if something blocks you: a missing permission, a sign-in, the Mimic CLI not
reaching the app, or the app not building after a reasonable fix. Don't work around it.
