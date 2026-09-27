## spec-correspondence — partial

- judged 8 SPEC(s): 6 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-18 partial: The three assertions cover missing-input, probe-rc-clamping, and missing-state-file paths, but "all non-zero exits" is a universal claim and other exit paths (e.g. JSON write failures) are not tested.
- SPEC-20 partial: The grep confirms no router block exists in the config, but the requirement also requires that manifest_router_knob returns empty string for timeout_s and max_turns, which is never invoked or checked.

