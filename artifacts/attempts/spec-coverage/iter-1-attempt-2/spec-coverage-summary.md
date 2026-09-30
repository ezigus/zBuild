## spec-coverage — uncovered

- Three items from the "What this plugin adopts" list have no covering SPEC: `provides.events` declared in the manifest (#1717), `provides.role` declared in the manifest (#1704), and the `cleanup` adoption (#1829) — which requires the hook's absence to be explicitly recorded, not merely implied by omission.

- NOT COVERED: `provides.events` declared in the manifest (#1717)
- NOT COVERED: `provides.role` declared in the manifest (#1704)
- NOT COVERED: `cleanup` hook — if no live resources, hook is absent and that fact is recorded (not implied) (#1829)
