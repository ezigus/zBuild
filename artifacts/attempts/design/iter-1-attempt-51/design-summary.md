## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: lens-correctness-design finding 1: done — The finding is correct. After the from-stage target unit is found and `skip_until_stage` is cleared (runner.sh:3653 cycle:* arm; runner.sh:3977 stage:* arm), `resume_mode` remains `true`. Every subsequent dispatch-unit iteration then satisfies `$resume_mode && [[ -z "$skip_until_stage" ]]`, causing the resume skip guard to fire for stages after `<s>`. Stages after `<s>` marked complete in the interrupted run are then silently skipped, violating RQFROM-1 ("the run starts at `<s>`").
