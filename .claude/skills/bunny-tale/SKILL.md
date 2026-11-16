---
name: bunny-tale
description: Kirjuta tänane jänkujutt (unejutt jänkuperest) või arhiveeri hoitud jutt. Write tonight's bunny bedtime story or archive a kept one from khe-bunny-tales. Use when the operator asks for a jänkujutt, unejutt, õhtujutt or bunny story, or says to keep or archive one.
---

# Bunny tale

The stories, their world and the procedure live in the private repo
`repos/khe-bunny-tales`. Read `repos/khe-bunny-tales/AGENTS.md` and follow
it: "Uus jutt" for a new story, "Arhiveeri jutt" when the operator keeps one.

Work from the workspace root, so the commit gate runs the repo's check on an
archive commit. If `repos/khe-bunny-tales` is missing, run
`scripts/workspace.sh clone`; if its `.venv` is missing, set it up by the
command in its AGENTS.md before archiving.

Archiving a story includes its picture, drawn from its full text and
rendered by `scripts/scenes/` ("Arhiveeri jutt" step 4), which the operator
approves before it is kept.

Archiving needs no audio. The reading is exported (`scripts/export.py`) and
uploaded to the audio store (`scripts/upload_audio.sh`) on the laptop, and a
story is published to khe.ee/stories/ by its `published:` line; the push to
`main` deploys both builds of the stories app (its AGENTS.md "Deploy").

Talk with the operator in Estonian. A new story goes to the operator in the
reply; nothing is saved until they keep it.
