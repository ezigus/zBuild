# Documentation style standard

**All zBuild user-facing docs — the README and every wiki page — are written for someone who has never heard of zBuild.** This is a hard rule, not a preference. When docs are regenerated or updated (see Initiative 1.1 / #876 / the docs-automation EPIC), they must follow this standard.

## The rules

1. **Open for a total newcomer.** The top of every document assumes **zero** prior knowledge of zBuild. Say, in plain language, *what it is, who it's for, and what problem it solves* — before any mechanism. A first-time reader must understand the opening without a glossary.

2. **No unexplained jargon.** Define a term the first time it appears on a page, in one plain sentence. Words like *pipeline, plugin, template, stage, operator, persona, redaction, chokepoint* are jargon to a newcomer — introduce them gently or avoid them up top.

3. **Progressive disclosure.** As the reader moves **down** a page, detail increases: accessible overview first → how it works in the middle → specifics later. Never front-load the hardest material.

4. **Label advanced content.** Anything that only makes sense to someone already familiar with zBuild goes under a heading that literally starts with **"Advanced"**, with a one-line note that newcomers can skip it. This applies to internal architecture, ADR references, engine internals, etc.

5. **Every page is self-contained at the top.** Even deep reference pages (a single plugin, a single mechanic) open with a plain one-paragraph "what this is / why you'd care" before the details.

6. **Plain language + a concrete example early.** Short sentences, everyday words, and a real, copy-pasteable example as early as it makes sense.

## Quick test
Before publishing a page, ask: *"Could a developer who has never used zBuild read the first screenful and correctly explain what this page is about?"* If not, the top needs to be simpler.

## Applies to
- `README.md`
- every page in the wiki (`docs/wiki/` → published wiki)
- release notes intros (the "what is this" framing, not the changelog detail)

Automated doc regeneration (#876 docs-as-release, #1356 docs automation) must generate pages that conform to this standard; the coverage gate should treat a page with no plain-language opening as a failure.
