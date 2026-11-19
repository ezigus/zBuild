## review-lens-security — fail

- found: medium: The holder string extracted from a GitHub issue comment by _ccgl_read_holder is passed to error(), which uses `echo -e "… $*"`, so backslash sequences (\n, \033[…) in the holder are interpreted by echo, allowing a crafted run-status comment to inject fake log lines or terminal control sequences into the operator's stderr. (core/pipeline/runner.sh)

- medium: The holder string extracted from a GitHub issue comment by _ccgl_read_holder is passed to error(), which uses `echo -e "… $*"`, so backslash sequences (\n, \033[…) in the holder are interpreted by echo, allowing a crafted run-status comment to inject fake log lines or terminal control sequences into the operator's stderr. (core/pipeline/runner.sh)
- score: 8
