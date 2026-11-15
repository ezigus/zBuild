## review-lens-security — pass

- found: low: The load-time probe array _ZB_SED_INPLACE_ARGS is not declared readonly, so any code in the same shell process that runs after compat.sh is sourced can append or replace its elements, injecting extra sed arguments (e.g. -e or -f flags) into every subsequent zbuild_sed_inplace call. (scripts/lib/compat.sh) (and 1 more)

- low: The load-time probe array _ZB_SED_INPLACE_ARGS is not declared readonly, so any code in the same shell process that runs after compat.sh is sourced can append or replace its elements, injecting extra sed arguments (e.g. -e or -f flags) into every subsequent zbuild_sed_inplace call. (scripts/lib/compat.sh)
- low: _zb_target_mode_v guards _ZB_STAT_MODE_CMD with ${_ZB_STAT_MODE_CMD:-}, so if the variable is unset or cleared after load (e.g. by a test that sources helpers.sh then runs unset _ZB_STAT_MODE_CMD) the function silently falls through to the BSD stat -f branch on a GNU host, returning mode 600 for every existing file. (scripts/lib/helpers.sh)
- score: 8
