## issue-acceptance — fail

- Three pre-existing enforcement tests break: the plugin writes the bare string `"block"` in a verdict comparison without a `# verdict-ok:` annotation so `lint-verdict-words` flags it as an undeclared emitted verdict; the SIGTERM/SIGINT trap uses a raw `trap` instead of the required project signal-handling helper, failing `stage-signal-test.sh [G5]`; and `disposition=unavailable` on the fallback-gh fail path names no service, failing `lint-disposition-words [G5]`.

- NOT MET: valid_verdicts declared and every verdict the plugin can emit is in it (lint flags `block` at plugin.sh:116 as an undeclared verdict)
- NOT MET: SIGTERM/SIGINT handling uses the project signal helper
- NOT MET: fallback-gh `disposition=unavailable` names its service
