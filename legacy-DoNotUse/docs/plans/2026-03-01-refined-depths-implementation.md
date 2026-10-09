# Refined Depths Brand Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Unify Shipwright and Skipper under the "Refined Depths" design system — deeper backgrounds, cyan-primary accent, system fonts, frosted glass effects, restrained gradients.

**Architecture:** Three CSS files drive the Skipper dashboard (theme.css, layout.css, components.css). One CSS file drives the Shipwright Fleet Command dashboard (styles.css). Both get updated to share the same design tokens. HTML files lose Google Fonts imports. Documentation (CLAUDE.md, design-system.md) gets updated to reflect the new system.

**Tech Stack:** CSS custom properties, system font stacks, backdrop-filter for frosted glass.

---

### Task 1: Update Skipper Dashboard — theme.css (Dark Mode)

**Files:**

- Modify: `skipper/crates/skipper-api/static/css/theme.css:90-137`

**Step 1: Replace dark mode CSS variables**

Replace the `[data-theme="dark"]` block (lines 90-137) with new Refined Depths values:

```css
[data-theme="dark"] {
  /* Backgrounds — Ocean Depths, quieted */
  --bg: #050508;
  --bg-primary: #08090e;
  --bg-elevated: #0e1018;
  --surface: #171c28;
  --surface2: #1e2536;
  --surface3: #111520;
  --border: #1e2536;
  --border-light: #2a3244;
  --border-subtle: #151a24;
  --text: #e8eaed;
  --text-secondary: #b0b4bc;
  --text-dim: #8b8f9a;
  --text-muted: #555a66;

  /* Brand — Cyan accent */
  --accent: #00d4ff;
  --accent-light: #33ddff;
  --accent-dim: #00a8cc;
  --accent-glow: rgba(0, 212, 255, 0.12);
  --accent-subtle: rgba(0, 212, 255, 0.08);

  /* Status */
  --success: #4ade80;
  --success-dim: #22c55e;
  --success-subtle: rgba(74, 222, 128, 0.1);
  --error: #f43f5e;
  --error-dim: #e11d48;
  --error-subtle: rgba(244, 63, 94, 0.1);
  --warning: #fbbf24;
  --warning-dim: #d97706;
  --warning-subtle: rgba(251, 191, 36, 0.1);
  --info: #3b82f6;
  --info-dim: #2563eb;
  --info-subtle: rgba(59, 130, 246, 0.1);
  --success-muted: rgba(74, 222, 128, 0.2);
  --error-muted: rgba(244, 63, 94, 0.2);
  --warning-muted: rgba(251, 191, 36, 0.2);
  --info-muted: rgba(59, 130, 246, 0.2);
  --border-strong: #2a3244;
  --card-highlight: rgba(255, 255, 255, 0.03);

  /* Chat */
  --agent-bg: #0a0d14;
  --user-bg: #0a1520;

  /* Shadows — deeper for dark mode */
  --shadow-xs: 0 1px 2px rgba(0, 0, 0, 0.3), 0 0 1px rgba(0, 0, 0, 0.1);
  --shadow-sm: 0 1px 3px rgba(0, 0, 0, 0.3), 0 0 1px rgba(0, 0, 0, 0.1);
  --shadow-md: 0 4px 8px rgba(0, 0, 0, 0.3), 0 0 1px rgba(0, 0, 0, 0.1);
  --shadow-lg: 0 12px 24px rgba(0, 0, 0, 0.4), 0 0 1px rgba(0, 0, 0, 0.1);
  --shadow-xl: 0 24px 48px rgba(0, 0, 0, 0.5), 0 0 1px rgba(0, 0, 0, 0.1);
  --shadow-glow: 0 0 40px rgba(0, 0, 0, 0.4);
  --shadow-accent: 0 4px 16px rgba(0, 212, 255, 0.1);
  --shadow-inset: inset 0 1px 0 rgba(255, 255, 255, 0.03);
}
```

**Step 2: Verify the file compiles (open in browser or check syntax)**

Confirm: CSS variables are valid, no typos, no missing semicolons.

**Step 3: Commit**

```bash
git add skipper/crates/skipper-api/static/css/theme.css
git commit -m "style(skipper): update dark mode to Refined Depths palette"
```

---

### Task 2: Update Skipper Dashboard — theme.css (Light Mode)

**Files:**

- Modify: `skipper/crates/skipper-api/static/css/theme.css:5-88`

**Step 1: Replace light mode CSS variables**

Replace the `[data-theme="light"], :root` block (lines 5-88) with cool-gray Refined Depths values:

```css
[data-theme="light"],
:root {
  /* Backgrounds — cool grays */
  --bg: #f8f9fa;
  --bg-primary: #f1f3f5;
  --bg-elevated: #ffffff;
  --surface: #e9ecef;
  --surface2: #f1f3f5;
  --surface3: #dee2e6;
  --border: #ced4da;
  --border-light: #adb5bd;
  --border-subtle: #dee2e6;

  /* Text hierarchy */
  --text: #1a1d21;
  --text-secondary: #343a40;
  --text-dim: #495057;
  --text-muted: #868e96;

  /* Brand — Cyan accent (darker for light bg contrast) */
  --accent: #0091b3;
  --accent-light: #00b4d8;
  --accent-dim: #007a99;
  --accent-glow: rgba(0, 145, 179, 0.1);
  --accent-subtle: rgba(0, 145, 179, 0.05);

  /* Status colors */
  --success: #22c55e;
  --success-dim: #16a34a;
  --success-subtle: rgba(34, 197, 94, 0.08);
  --error: #ef4444;
  --error-dim: #dc2626;
  --error-subtle: rgba(239, 68, 68, 0.06);
  --warning: #f59e0b;
  --warning-dim: #d97706;
  --warning-subtle: rgba(245, 158, 11, 0.08);
  --info: #3b82f6;
  --info-dim: #2563eb;
  --info-subtle: rgba(59, 130, 246, 0.06);
  --success-muted: rgba(34, 197, 94, 0.15);
  --error-muted: rgba(239, 68, 68, 0.15);
  --warning-muted: rgba(245, 158, 11, 0.15);
  --info-muted: rgba(59, 130, 246, 0.15);
  --border-strong: #adb5bd;
  --card-highlight: rgba(0, 0, 0, 0.02);

  /* Chat-specific */
  --agent-bg: #f8f9fa;
  --user-bg: #e8f7fa;

  /* Layout */
  --sidebar-width: 240px;
  --sidebar-collapsed: 56px;
  --header-height: 48px;

  /* Radius */
  --radius-xs: 4px;
  --radius-sm: 6px;
  --radius-md: 10px;
  --radius-lg: 14px;
  --radius-xl: 20px;

  /* Shadows — light mode */
  --shadow-xs: 0 1px 2px rgba(0, 0, 0, 0.04);
  --shadow-sm: 0 1px 3px rgba(0, 0, 0, 0.08), 0 0 1px rgba(0, 0, 0, 0.04);
  --shadow-md: 0 4px 12px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.04);
  --shadow-lg: 0 12px 28px rgba(0, 0, 0, 0.1), 0 4px 8px rgba(0, 0, 0, 0.04);
  --shadow-xl: 0 24px 48px rgba(0, 0, 0, 0.12), 0 8px 16px rgba(0, 0, 0, 0.06);
  --shadow-glow: 0 0 40px rgba(0, 0, 0, 0.05);
  --shadow-accent: 0 4px 16px rgba(0, 145, 179, 0.1);
  --shadow-inset: inset 0 1px 0 rgba(255, 255, 255, 0.5);

  /* Typography — system fonts */
  --font-sans:
    -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, "Helvetica Neue",
    sans-serif;
  --font-mono:
    "SF Mono", ui-monospace, "Cascadia Code", "Geist Mono", monospace;

  /* Motion — toned-down spring */
  --ease-spring: cubic-bezier(0.34, 1.2, 0.64, 1);
  --ease-smooth: cubic-bezier(0.4, 0, 0.2, 1);
  --ease-out: cubic-bezier(0, 0, 0.2, 1);
  --ease-in: cubic-bezier(0.4, 0, 1, 1);
  --transition-fast: 0.15s var(--ease-smooth);
  --transition-normal: 0.25s var(--ease-smooth);
  --transition-spring: 0.4s var(--ease-spring);
}
```

**Step 2: Update selection color**

Change line 172-175 from orange to cyan:

```css
::selection {
  background: var(--accent);
  color: white;
}
```

**Step 3: Commit**

```bash
git add skipper/crates/skipper-api/static/css/theme.css
git commit -m "style(skipper): update light mode to cool-gray Refined Depths palette"
```

---

### Task 3: Update Skipper Dashboard — theme.css (Animations & Global Styles)

**Files:**

- Modify: `skipper/crates/skipper-api/static/css/theme.css:201-277`

**Step 1: Remove shimmer and pulse-ring keyframes**

Delete the `@keyframes shimmer` block (lines 222-225) and `@keyframes pulse-ring` block (lines 227-231). Keep fadeIn, slideUp, slideDown, scaleIn, spin, and cardEntry.

**Step 2: Update the skeleton loading to use a simpler fade instead of shimmer**

Replace line 252-254:

```css
.skeleton {
  background: var(--surface);
  border-radius: var(--radius-sm);
  opacity: 0.5;
  animation: fadeIn 1s ease-in-out infinite alternate;
}
```

**Step 3: Update cardEntry spring to use toned-down spring**

The stagger classes reference `--ease-spring` which is now toned down (1.2 vs 1.56). No code change needed — the variable update in Task 2 handles it.

**Step 4: Commit**

```bash
git add skipper/crates/skipper-api/static/css/theme.css
git commit -m "style(skipper): remove shimmer/pulse animations, simplify skeleton loading"
```

---

### Task 4: Remove Google Fonts from Skipper Dashboard

**Files:**

- Modify: `skipper/crates/skipper-api/static/index_head.html:9-11`

**Step 1: Remove the three Google Fonts lines**

Remove lines 9-11:

```html
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link
  href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Geist+Mono:wght@400;500;600;700&display=swap"
  rel="stylesheet"
/>
```

**Step 2: Commit**

```bash
git add skipper/crates/skipper-api/static/index_head.html
git commit -m "style(skipper): remove Google Fonts imports, use system font stack"
```

---

### Task 5: Update Shipwright Fleet Command Dashboard — styles.css

**Files:**

- Modify: `dashboard/public/styles.css:10-82` (dark mode tokens)
- Modify: `dashboard/public/styles.css:85-121` (light mode tokens)

**Step 1: Replace dark mode CSS variables (lines 10-82)**

```css
:root {
  /* Ocean Depths — quieted */
  --abyss: #050508;
  --deep: #0a0d14;
  --ocean: #111520;
  --surface: #171c28;
  --foam: #1e2536;

  /* Accent — cyan primary */
  --cyan: #00d4ff;
  --cyan-subtle: rgba(0, 212, 255, 0.08);
  --cyan-muted: rgba(0, 212, 255, 0.25);
  --purple: #7c3aed;
  --blue: #0066ff;

  /* Status */
  --green: #4ade80;
  --amber: #fbbf24;
  --rose: #f43f5e;

  /* Text */
  --text-primary: #e8eaed;
  --text-secondary: #8b8f9a;
  --text-muted: #555a66;

  /* Cards */
  --card-bg: rgba(10, 13, 20, 0.8);
  --card-border: rgba(255, 255, 255, 0.06);
  --card-hover-border: rgba(0, 212, 255, 0.15);
  --card-radius: 14px;

  /* Typography — system fonts */
  --font-body:
    -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, "Helvetica Neue",
    sans-serif;
  --font-mono:
    "SF Mono", ui-monospace, "Cascadia Code", "Geist Mono", monospace;

  /* Transitions */
  --transition-fast: 0.15s ease;
  --transition-base: 0.25s ease;
  --transition-slow: 0.4s ease;

  /* Spacing scale */
  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-5: 20px;
  --space-6: 24px;
  --space-8: 32px;
  --space-10: 40px;
  --space-12: 48px;
  --space-16: 64px;

  /* Border radius */
  --radius-sm: 6px;
  --radius-md: 10px;
  --radius-lg: 14px;
  --radius-xl: 20px;
  --radius-full: 9999px;

  /* Shadows */
  --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.3), 0 0 1px rgba(0, 0, 0, 0.1);
  --shadow-md: 0 4px 8px rgba(0, 0, 0, 0.3), 0 0 1px rgba(0, 0, 0, 0.1);
  --shadow-lg: 0 12px 24px rgba(0, 0, 0, 0.4), 0 0 1px rgba(0, 0, 0, 0.1);
  --shadow-elevated: 0 24px 48px rgba(0, 0, 0, 0.5), 0 0 1px rgba(0, 0, 0, 0.1);

  /* Z-index */
  --z-base: 1;
  --z-dropdown: 10;
  --z-sticky: 20;
  --z-overlay: 30;
  --z-modal: 40;
  --z-toast: 50;

  /* Easing */
  --ease-smooth: cubic-bezier(0.4, 0, 0.2, 1);
  --ease-spring: cubic-bezier(0.34, 1.2, 0.64, 1);
}
```

**Step 2: Replace light mode CSS variables (lines 85-121)**

```css
:root[data-theme="light"] {
  --abyss: #f8f9fa;
  --deep: #ffffff;
  --ocean: #f1f3f5;
  --surface: #e9ecef;
  --foam: #dee2e6;

  --cyan: #0091b3;
  --cyan-subtle: rgba(0, 145, 179, 0.08);
  --cyan-muted: rgba(0, 145, 179, 0.25);
  --purple: #6d28d9;
  --blue: #0055cc;

  --green: #16a34a;
  --amber: #d97706;
  --rose: #dc2626;

  --text-primary: #1a1d21;
  --text-secondary: #495057;
  --text-muted: #868e96;

  --card-bg: rgba(255, 255, 255, 0.9);
  --card-border: rgba(0, 0, 0, 0.06);
  --card-hover-border: rgba(0, 145, 179, 0.15);

  --shadow-sm: 0 1px 3px rgba(0, 0, 0, 0.08), 0 0 1px rgba(0, 0, 0, 0.04);
  --shadow-md: 0 4px 12px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.04);
  --shadow-lg: 0 12px 28px rgba(0, 0, 0, 0.1), 0 4px 8px rgba(0, 0, 0, 0.04);
  --shadow-elevated:
    0 24px 48px rgba(0, 0, 0, 0.12), 0 8px 16px rgba(0, 0, 0, 0.06);

  --border: rgba(0, 0, 0, 0.08);
}
```

**Step 3: Remove `--font-display` references**

Delete line 37: `--font-display: "Instrument Serif", Georgia, serif;`

Search for any usage of `--font-display` in styles.css and replace with `--font-body`.

**Step 4: Remove glow shadows**

Delete lines 65-68 (the `--shadow-glow-*` variables). Replace any usage of `--shadow-glow-cyan` etc. with `--shadow-md`.

**Step 5: Commit**

```bash
git add dashboard/public/styles.css
git commit -m "style(dashboard): update Fleet Command to Refined Depths palette"
```

---

### Task 6: Remove Google Fonts from Fleet Command Dashboard

**Files:**

- Modify: `dashboard/public/index.html:7-12`

**Step 1: Remove Google Fonts import lines**

Remove lines 7-12:

```html
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link
  href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=JetBrains+Mono:wght@400;500;700&family=Plus+Jakarta+Sans:wght@300;400;500;600;700&display=swap"
  rel="stylesheet"
/>
```

**Step 2: Commit**

```bash
git add dashboard/public/index.html
git commit -m "style(dashboard): remove Google Fonts imports, use system font stack"
```

---

### Task 7: Update CLAUDE.md Color References

**Files:**

- Modify: `.claude/CLAUDE.md:944-951`

**Step 1: Update the Colors table**

Replace lines 944-951:

```markdown
### Colors

| Name  | Hex       | Usage                                |
| ----- | --------- | ------------------------------------ |
| Cyan  | `#00d4ff` | Primary accent, active borders, CTAs |
| Green | `#4ade80` | Success indicators                   |
| Amber | `#fbbf24` | Warning indicators                   |
| Rose  | `#f43f5e` | Error indicators                     |

Purple (`#7c3aed`) and Blue (`#0066ff`) are used only as gradient endpoints, never as standalone accents.
```

**Step 2: Commit**

```bash
git add .claude/CLAUDE.md
git commit -m "docs: update CLAUDE.md color table to Refined Depths system"
```

---

### Task 8: Update website/design-system.md

**Files:**

- Modify: `website/design-system.md` (full file)

**Step 1: Replace the entire file with the Refined Depths spec**

Copy the full content from `docs/plans/2026-03-01-refined-depths-brand-design.md` into `website/design-system.md`, updating the header to read "Shipwright Design System" (the canonical design system reference).

**Step 2: Commit**

```bash
git add website/design-system.md
git commit -m "docs: replace website design system with Refined Depths v3.0"
```

---

### Task 9: Verify and Fix Component CSS References

**Files:**

- Modify: `skipper/crates/skipper-api/static/css/components.css` (if needed)

**Step 1: Search for hardcoded orange colors**

Search components.css for any hardcoded `#FF5C00`, `#FF7A2E`, `#E05200`, or `rgb(255, 92, 0` references that bypass CSS variables. Replace with `var(--accent)`, `var(--accent-light)`, or `var(--accent-dim)`.

**Step 2: Search for hardcoded old background colors**

Search for `#080706`, `#0F0E0E`, `#161413`, `#1F1D1C`, `#F5F4F2`, `#EDECEB` — any hardcoded old palette values that should use CSS variables instead.

**Step 3: Search for `--accent` fallback references in index_body.html**

The inline styles in index_body.html use CSS variable fallbacks like `var(--accent, #7c3aed)`. Search for fallback values that reference the old orange or purple and update them:

- Replace fallback `#7c3aed` with `#00d4ff` where it represents the accent
- Replace fallback `#1e1e2e` with `#0a0d14`

**Step 4: Commit**

```bash
git add skipper/crates/skipper-api/static/css/components.css
git add skipper/crates/skipper-api/static/index_body.html
git commit -m "style(skipper): fix hardcoded color references to use CSS variables"
```

---

### Task 10: Update README Badge Colors

**Files:**

- Modify: `README.md:15-18`

**Step 1: Verify badge colors match new palette**

Lines 15-18 already use:

- `4ade80` (green) — stays
- `00d4ff` (cyan) — stays
- `7c3aed` (purple for bash badge) — change to `555a66` (muted, per design doc)

Replace line 18:

```markdown
  <img src="https://img.shields.io/badge/bash-3.2%2B-555a66?style=flat-square" alt="Bash 3.2+">
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README badge colors to Refined Depths palette"
```

---

### Task 11: Final Visual Verification

**Step 1: Build the Skipper dashboard and check in browser**

```bash
cd skipper && cargo build --workspace --lib
```

Open the Skipper dashboard in a browser and verify:

- Dark mode: near-black backgrounds, cyan accents, system fonts
- Light mode: cool-gray backgrounds, darker cyan accents
- Theme toggle works correctly
- All buttons, cards, badges render with new colors

**Step 2: Check the Fleet Command dashboard**

Start the dashboard server and verify visually.

**Step 3: Run any existing tests**

```bash
cd skipper && cargo test --workspace
```

**Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "style: final visual fixes for Refined Depths brand system"
```
