## spec-coverage — uncovered

- The "What this plugin adopts" bulleted list explicitly requires `provides.events` declared, `provides.role` declared, and `cleanup` recorded if absent — none of these three manifest requirements appear in any SPEC.

- NOT COVERED: `provides.events` declared in the manifest (#1717)
- NOT COVERED: `provides.role` declared in the manifest (#1704)
- NOT COVERED: `cleanup` hook recorded as absent if the plugin holds no live resources (#1829)
