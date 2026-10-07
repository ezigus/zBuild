## issue-acceptance — pass

- The diff implements all seven requirements — draft forcing on failed status (R-1) and max_iterations (R-2), convergence body with "not converged" and both iteration counts (R-4), failing gate names and reason in the body (R-3), the non-draft default preserved for passing runs (R-5), explicit `pr_draft: true` override still respected (R-6), and both regression tests confirmed red on main before the fix (R-7).

- every requirement the issue states is met by the change
