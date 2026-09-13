## spec-coverage — uncovered

- The issue's explicit acceptance checkbox "the plugin constructs no artifact paths in code — assert by grep over its `plugin.sh`" requires a blanket grep assertion across all declared inputs, but SPEC-15 only asserts the absence of one specific path construction (`state_dir` concatenated with `scope-manifest.md`) and does not cover the general no-path-construction requirement for every input the plugin declares.

- NOT COVERED: blanket grep assertion that plugin.sh constructs no artifact paths in code for any declared input (SPEC-15 covers only scope_manifest's state_dir concatenation, not all inputs)
