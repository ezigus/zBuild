# Shipwright Go-To-Market Strategy & Roadmap

**Status:** Strategic Planning Phase
**Version:** 1.0
**Last Updated:** February 14, 2026

---

## Executive Summary

Shipwright is positioned to disrupt autonomous software delivery by bringing AI-driven agent teams to every developer and DevOps team. Unlike closed proprietary platforms, Shipwright's open-source, self-hosted architecture removes adoption friction, enables enterprise customization, and builds community momentum.

This document outlines how to scale from technical early adopters to mainstream adoption across three market segments: individual developers, dev teams, and enterprises.

---

## Part I: Go-To-Market Strategy

### I.1 Market Positioning

**Core Value Proposition**

> "Ship code 10x faster with autonomous Claude Code agent teams — no AI API vendor lock-in, runs on your infra, integrates with your GitHub."

**Unique Advantages**

1. **Self-hosted + Open Source**: No SaaS lock-in. Companies control their data and deployment.
2. **Native GitHub Integration**: Deep API hooks (Checks, Deployments, CODEOWNERS) — not a bolted-on add-on.
3. **Agent Team Orchestration**: First autonomous tool to coordinate multiple AI agents with clear task boundaries and role specialization.
4. **Built-in Intelligence**: Predictive risk scoring, adversarial review, DORA metrics, self-optimization — not separate expensive add-ons.
5. **Cost Transparency**: Per-pipeline cost tracking, budget enforcement, adaptive model routing. Developers know what they pay.
6. **Bash-Everything**: Runs anywhere bash runs. Linux, macOS, WSL, even older CI systems. Zero language lock-in.

**Target Competition**

- **GitHub Copilot for Enterprises** → Shipwright is automation, not just code completion
- **Sourcegraph/Cody** → Cody is chat-based; Shipwright executes full workflows autonomously
- **Conventional CI/CD** (GitHub Actions, GitLab CI, Jenkins) → Shipwright removes human-in-loop for entire delivery
- **Cursor IDE** → Works inside an editor; Shipwright orchestrates across multiple services
- **Linear/Jira PM tools** → Don't execute code; Shipwright closes the issue-to-deployment gap

---

### I.2 Distribution Model

**Open Source First, Enterprise Second**

```
Community Edition (Free)
    ↓ (natural upgrade path)
Hosted Shipwright SaaS (Optional)
    ↓ (support + premium features)
Enterprise Edition (Self-Hosted + Support)
```

**Phase 1: Community-Driven Growth (Now)**

- 100% open source on GitHub
- Zero artificial feature limitations
- Community support via GitHub Discussions + Discord
- Early adopter testimonials on website

**Phase 2: Premium SaaS Optional Layer (Q3 2026)**

- **Hosted Shipwright**: Run daemon on Shipwright servers, retain data ownership via encrypted certs
- **Premium Features**: Advanced telemetry, team invites, shared dashboards, GitHub org-level analytics
- **Pricing**: $49/month for individuals, $299/month for teams (5 concurrent jobs max)
- **Free tier**: 2 concurrent jobs for open-source projects

**Phase 3: Enterprise Edition (Q4 2026+)**

- **Self-Hosted Enterprise**: Per-org licenses ($5K-$50K/year) with SLA and priority support
- **Managed Services**: Shipwright runs agents on customer's infra (VPC/on-prem) with dedicated support
- **Compliance**: SOC 2 certification, HIPAA addendum, audit logs
- **Features**: SAML/OAuth, team RBAC, usage quotas, Slack integration, PagerDuty escalation

**Freemium Positioning**

- Community edition unlimited but feature-gated (can process 1 issue at a time, 10 workflows/month)
- Premium ungate concurrency and webhook limits
- Enterprise adds compliance + support SLAs + custom integrations

---

### I.3 Adoption Funnel

**Stage 1: Awareness (GitHub Discovery)**

- Target: Senior engineers, DevOps leads, engineering managers
- Channels:
  - **GitHub Trending** (organic): High-quality Bash + agent orchestration novelty
  - **Hacker News**: "From labeled GitHub issue to merged PR — zero human intervention"
  - **Product Hunt**: Show live demo running on Shipwright's own issues
  - **Indie Hackers**: Cost savings angle (save $50K/year on CI/deployment labor)
  - **Dev.to** + **CSS-Tricks**: Tutorial: "Set up Shipwright daemon in 5 minutes"

**Stage 2: Trial (First Use)**

- Target: Developers curious about Claude Code agent orchestration
- Activation barrier: Very low
  - One-liner install: `curl -fsSL https://... | bash`
  - Single command quick start: `shipwright init`
  - Works with existing GitHub repos (no migration)
  - First pipeline success within 5 minutes (on simple issues)
- Metrics to track:
  - Time-to-first-successful-pipeline (target: <10 min)
  - GitHub repo stars (viral growth signal)
  - Docker pulls + npm installs (adoption velocity)

**Stage 3: Conversion (Daemon Adoption)**

- Target: Dev teams processing 5+ issues per sprint
- Activation moment: "Let's run the daemon overnight and process 10 issues autonomously"
- Key commitments:
  - Label issues with `shipwright`
  - Configure issue templates + pipeline settings
  - Monitor first few daemon runs before full trust
- Conversion metric: Teams with daemon running > 7 days continuously

**Stage 4: Expansion (Fleet + Enterprise)**

- Target: Multi-repo orgs, DevOps platforms
- Expansion points:
  - **Fleet**: "Let's process issues across 10+ repos with shared worker pool"
  - **Integrations**: "Add Linear/Jira sync, PagerDuty alerts, Slack notifications"
  - **Enterprise**: "Audit compliance, SAML auth, dedicated support"

---

### I.4 Community Strategy

**GitHub Community**

1. **Templates + Examples**
   - Issue template (`shipwright.yml`) — make creating Shipwright-processable issues frictionless
   - Docstring examples for each command
   - Runbook: "Add Shipwright to my CI pipeline"
   - Example repos showing Shipwright in action

2. **GitHub Discussions**
   - Category: "Show & Tell" — share daemon wins, cost savings, time-to-deployment improvements
   - Category: "Help" — troubleshooting, setup issues
   - Category: "Feature Requests" — gauge demand, build community consensus
   - Pinned: "Quick wins" from community members

3. **Issues + Contributing**
   - Use Shipwright's own daemon to process incoming issues
   - Make it easy for community to contribute agents (custom `.claude/agents/`)
   - Highlight contributors in every release (social proof)

**Discord Community**

- **Channels:**
  - `#introductions` — new users, use case sharing
  - `#wins` — screenshots of issues Shipwright solved, cost savings, time savings
  - `#help` — real-time troubleshooting
  - `#integrations` — Linear/Jira/Slack/PagerDuty setup help
  - `#dev` — contributors, internal discussions

- **Engagement:**
  - Weekly demo: Record 5-min video of Shipwright processing a real issue end-to-end
  - Monthly AMA: Seth + team live Q&A on roadmap, debugging, performance tuning
  - Bounty board: $100-$500 per integration (Linear, Jira webhook, Datadog, etc.)

**Content Strategy**

| Content Type                     | Target        | Cadence   | Goal                           |
| -------------------------------- | ------------- | --------- | ------------------------------ |
| Blog: "Shipwright in Production" | Dev leads     | Monthly   | Case studies, metrics, lessons |
| Blog: "Reducing DORA lead time"  | DevOps/SRE    | Biweekly  | Thought leadership on metrics  |
| YouTube: Live coding             | Developers    | Weekly    | Build tutorials, walkthroughs  |
| Twitter/X: Wins thread           | Community     | Weekly    | Social proof, virality         |
| Conference talks                 | Dev community | Quarterly | Brand awareness, trust         |
| Webinar: "AI-native delivery"    | Enterprises   | Monthly   | Lead generation                |

---

### I.5 Partnership Opportunities

**Anthropic Ecosystem**

- **Claude Code Community**: Promote Shipwright as the orchestration layer for teams using Claude Code
- **Anthropic Blog**: Co-publish case study on agent team automation
- **Anthropic Website**: "Built with Claude Code" partnership badge + link exchange

**DevOps & CI/CD Platforms**

- **GitHub**: Native integration showcase (Checks API, Deployments), marketplace listing
- **GitLab**: GitLab CI agent integration, marketplace
- **Vercel / Netlify**: Deploy Shipwright alongside serverless functions
- **HashiCorp**: Terraform modules for Shipwright infrastructure (EC2 autoscaling, etc.)

**Enterprise Platforms**

- **Slack**: Native integration for daemon alerts, issue notifications, PR reviews
- **PagerDuty**: Auto-escalate failed pipelines to on-call engineer
- **DataDog / New Relic**: APM instrumentation for pipeline metrics
- **Atlassian**: Jira deep integration (already built)

**Developer Communities**

- **CNCF**: Cloud-native deployment, Kubernetes operators
- **Bash / Shell**: Advanced scripting workshops
- **Go Community**: Promote as canonical example of Go + Bash integration (if dashboard goes Rust eventually)

---

### I.6 Content Marketing

**Blog Series: "The Future of Delivery"**

1. **"From Issue to Merged PR in 4 Minutes"** (1000 words)
   - Show real Shipwright run
   - Contrast with manual process
   - Highlight time/cost savings

2. **"Building Agents That Ship Code"** (2000 words)
   - Deep dive: agent team design patterns
   - Pitfalls (too much autonomy, validation gaps)
   - Memory/learning system advantages

3. **"DORA Metrics for Autonomous Teams"** (1500 words)
   - How Shipwright improves lead time, deployment frequency
   - CFR/MTTR impact analysis
   - Benchmark Shipwright against industry

4. **"GitOps + AI-Native Delivery"** (1500 words)
   - Contrast with traditional GitOps
   - When to use Shipwright vs. declarative IaC
   - Hybrid approaches (Terraform + Shipwright)

**Real-World Case Studies**

- **"How [Startup Y] Reduced Release Cycle from 2 weeks to 2 days"**
  - Metrics: lead time, deployment frequency, cost per deployment
  - Challenges: trust, validation, rollback strategy
  - ROI: labor hours saved, faster iteration

- **"Fleet Operations Across 50+ Repos"**
  - How scaling daemon across multiple repos works
  - Worker pool rebalancing, priority lanes
  - Cost per pipeline, ROI analysis

---

## Part II: Strategic Roadmap

### II.1 Phase Framework

Each phase is 8-12 weeks. Phases overlap to maintain release cadence.

```
Phase 1 (Now - Mar)      Core Excellence
Phase 2 (Feb - Apr)      Differentiation
Phase 3 (Apr - Jun)      Enterprise Ready
Phase 4 (Jun+)           Platform & Ecosystem
```

---

### II.2 Phase 1: Core Excellence (8 weeks)

**Goal:** Make Shipwright rock-solid for 80% of developer workflows.

**Pillars**

- **Stability**: Zero memory leaks, reliable long-running daemon, automatic recovery from crashes
- **Documentation**: Runbooks for common patterns, troubleshooting guides, video tutorials
- **DX (Developer Experience)**: Reduce time-to-first-success, clear error messages, intuitive CLI
- **Testing**: 95%+ code coverage on critical paths, E2E tests using real Claude Code CLI

**Issues to Resolve**

| Issue | Priority | Impact                                                               | Owner |
| ----- | -------- | -------------------------------------------------------------------- | ----- |
| 60    | P0       | Ruthless quality validation — gating auto-pass, zero false positives | @seth |
| 42    | P1       | Live terminal streaming — real-time pipeline visibility              | @team |
| 41    | P1       | tmux-native pipeline execution — eliminate subprocess noise          | @team |
| 45    | P1       | Dashboard mission control — centralized status + quick actions       | @team |
| 43    | P1       | Team-based pipeline stages — assign stages to specific team members  | @team |

**Success Metrics**

- Zero critical daemon crashes in production (100% uptime SLO for 30 days)
- 95%+ pipeline success rate on typical issues
- First-time-user success rate: 90% can run daemon within 10 minutes
- Docs: 1000+ monthly visitors, 500+ Discord members

**Deliverables**

- Automated quality gate that blocks auto-pass on risky changes
- Dashboard v1: Live pipeline progress, GitHub context sidebar
- Runbooks: "Set up daemon for a real team", "Debug failed pipelines"
- Video series: Quick starts (10 videos x 2-3 min each)

---

### II.3 Phase 2: Differentiation (12 weeks)

**Goal:** Introduce features that competitors can't easily replicate.

**Pillars**

- **Intelligence Layer**: Predictive risk, adversarial review, architecture enforcement
- **Cost Intelligence**: Per-pipeline ROI, budget enforcement, model routing
- **Multi-Model Orchestration**: Use cheaper models for simple tasks, frontier models for complex ones
- **Observability**: DORA metrics, pipeline vitals, cost trends, failure pattern analysis

**Issues to Resolve**

| Issue | Priority | Impact                                                          | Owner |
| ----- | -------- | --------------------------------------------------------------- | ----- |
| 56    | P1       | Multi-model orchestration — adaptive model selection            | @team |
| 60    | P0       | Ruthless quality validation (continued) — iterative improvement | @seth |
| 35    | P3       | OpenTelemetry observability — integrate with DataDog, New Relic | @team |
| 30    | P3       | DORA metrics dashboard — lead time, deployment frequency, CFR   | @team |
| 38    | P3       | Autonomous PM agent — proactive issue analysis + labeling       | @team |

**Success Metrics**

- Intelligence layer enabled by default; >70% of pipelines use predictive risk scoring
- Cost savings quantified: avg 20% reduction via intelligent model routing
- Observability: 1000+ orgs using DORA metrics dashboard
- GitHub stars: 5K+ (organic growth signal)

**Deliverables**

- Multi-model orchestration engine (SPRT-based model switching)
- Cost dashboard: per-pipeline ROI, model cost breakdown
- DORA metrics dashboard: lead time trends, deployment frequency, CFR
- Adversarial review enabled by default (red-team every PR)
- Autonomous PM agent that labels issues, predicts effort, assigns to right team

---

### II.4 Phase 3: Enterprise Ready (12 weeks)

**Goal:** Unlock $100K+ deals with mid-market and enterprise.

**Pillars**

- **Auth & RBAC**: SAML/OIDC SSO, team-based access control, audit logs
- **Compliance & Security**: SOC 2, HIPAA addendum, vulnerability scanning
- **SLA Guarantees**: 99.9% uptime SLO, dedicated support, priority bug fixes
- **Advanced Integrations**: Linear/Jira webhook sync, Slack/PagerDuty escalation, GitHub Advanced Security

**Issues to Resolve**

| Issue | Priority | Impact                                                         | Owner |
| ----- | -------- | -------------------------------------------------------------- | ----- |
| 57    | P2       | GitHub App for native integration — first-class auth, webhooks | @team |
| 58    | P2       | Automated dependency updates — Dependabot auto-merge workflow  | @team |
| 15    | P2       | Dashboard authentication — SAML/OIDC, team RBAC                | @team |
| 25    | P2       | Public real-time dashboard — allow public view of deployments  | @team |
| 32    | P3       | Multi-repo fleet visualization — org-wide dashboard            | @team |

**Success Metrics**

- Enterprise tier pricing active; 5+ enterprise deals closed
- SOC 2 Type II certified
- SLA: 99.9% uptime demonstrated over 90 days
- Integrations: GitHub App installed on 500+ orgs

**Deliverables**

- GitHub App (Checks API, Deployments API, webhooks) — zero setup friction
- Enterprise Edition with SAML/OIDC, team RBAC, audit logs
- Automated Dependabot workflow (auto-review, test, merge)
- SLA documentation + uptime dashboard
- Managed Services offering (agents run on Shipwright infra)

---

### II.5 Phase 4: Platform & Ecosystem (Ongoing)

**Goal:** Position Shipwright as the canonical orchestration platform for AI-native delivery.

**Pillars**

- **Agent Marketplace**: Community builds custom agents (security review, performance audit, etc.)
- **Template Library**: Pre-built workflows for common patterns (monorepo, microservices, etc.)
- **Extensibility**: Webhooks, plugins, custom context providers
- **Cross-Platform**: Kubernetes operators, Docker Compose templates, Terraform modules

**Issues to Resolve**

| Issue | Priority | Impact                                                               | Owner |
| ----- | -------- | -------------------------------------------------------------------- | ----- |
| 51    | P1       | Event-driven architecture — replace polling with durable event bus   | @team |
| 52    | P2       | Production feedback loop — auto-create issues from runtime errors    | @team |
| 53    | P2       | Cross-pipeline real-time learning — share discoveries between builds | @team |
| 54    | P2       | Intelligent issue decomposition — auto-split large issues            | @team |
| 59    | P2       | Release train automation — batched releases, semantic versioning     | @team |

**Success Metrics**

- Agent Marketplace: 50+ custom agents contributed
- Template Library: 100+ templates covering common patterns
- Event-driven: Zero polling, full async architecture
- Production feedback loop: 100+ orgs integrating error tracking
- Thought leadership: Shipwright mentioned in Gartner MQ for AI-native delivery

**Deliverables**

- Durable event bus (replaces polling)
- Agent Marketplace with templating + testing harness
- Production feedback loop integration (error → issue)
- Release train automation (semantic versioning, changelogs)
- Kubernetes operator for running Shipwright daemon
- Terraform modules for AWS/GCP deployment

---

## Part III: Quick Wins (This Week)

**High-impact, low-effort items that accelerate GTM immediately:**

### 1. **GitHub Profile README** (4 hours)

- Create `/profile/README.md` in `github.com/sethdford` account
- Showcase Shipwright as primary project
- Link to live demo, quick start, Discord
- Social proof: GitHub stars, contributor count, recent wins

### 2. **Product Hunt Launch** (6 hours)

- Schedule launch for next Tuesday (high engagement)
- Prepare demo video (2 min)
- Write compelling hunt post (pain point → solution → demo)
- Tag relevant categories (DevTools, Development, Automation)
- Target: 500+ upvotes, top 5 in category

### 3. **Hacker News Story** (2 hours)

- Post to HN with title: "Shipwright: Autonomously deliver features from GitHub issues to PRs"
- Embed demo video in comments
- Be ready to engage in comments, answer technical questions
- Target: 100+ points, top 3 on front page

### 4. **Discord Community Setup** (3 hours)

- Create Discord server (free)
- Setup channels: intros, help, wins, dev, releases
- Invite early users + Anthropic contacts
- Post weekly demo video
- Target: 50+ members by week 2

### 5. **Benchmark Comparison Table** (4 hours)

- Create `/docs/strategy/01-competitive-analysis.md`
- Matrix: Shipwright vs. GitHub Copilot, Cursor, Cody, Conventional CI
- Highlight unique advantages: agent orchestration, self-hosted, cost transparency
- Publish on website + use in sales collateral

### 6. **Case Study: Shipwright on Shipwright** (6 hours)

- Document 3 real issues Shipwright solved (with before/after)
- Metrics: time-to-resolution, cost, test coverage
- Publish as `/docs/strategy/02-case-studies.md` + blog post
- Use in early sales conversations

### 7. **Conference Talk Proposal** (4 hours)

- Submit to GitHub Universe, QCon, DevOps Days (all June-August)
- Title: "Autonomous Teams: Building AI-Native Delivery Pipelines"
- Abstract: cost reduction, agent orchestration, real-world patterns
- Target: 1-2 talks accepted by summer

---

## Part IV: Success Metrics & KPIs

### Growth Metrics

| KPI                   | Target (Q2) | Target (Q4) | Measurement                     |
| --------------------- | ----------- | ----------- | ------------------------------- |
| GitHub Stars          | 2K          | 5K+         | github.com/sethdford/shipwright |
| Monthly Installs      | 100         | 500+        | npm + curl downloads            |
| Active Daemons        | 20          | 100+        | Telemetry / heartbeat check     |
| Community Members     | 100         | 500+        | Discord + GitHub Discussions    |
| Blog Monthly Visitors | 500         | 2K+         | Google Analytics                |

### Adoption Metrics

| KPI                       | Target | Measurement                                         |
| ------------------------- | ------ | --------------------------------------------------- |
| Daemon Retention (7 days) | 40%    | % of trial users with daemon running >7 days        |
| Fleet Adoption            | 15%    | % of daemon users configuring fleet across 3+ repos |
| Intelligence Enabled      | 70%    | % of pipelines with predictive risk scoring active  |
| Cost Savings Tracked      | 50%    | % of users examining cost dashboard                 |

### Business Metrics

| KPI                       | Target (Q3) | Target (Q4) |
| ------------------------- | ----------- | ----------- |
| Freemium Signups          | 100         | 500+        |
| Premium Trial Conversions | 10%         | 20%+        |
| Enterprise Pilots         | 2           | 5+          |
| Revenue (MRR)             | $2K         | $10K+       |

---

## Part V: Risks & Mitigations

### Risk: Anthropic's Claude API pricing/availability changes

**Impact**: High — Shipwright's value prop depends on Claude Code quality and cost efficiency

**Mitigation**

1. Support multi-model from day 1 (Haiku, Sonnet, Opus, plus open models via Ollama)
2. Build fallback to open-source models (Llama, Mistral)
3. Monitor Anthropic roadmap; align releases with Claude Code features
4. Maintain pricing transparency so customers understand cost sensitivity

---

### Risk: Competitors catch up (GitHub Copilot Agents, new Cursor features)

**Impact**: Medium — market becomes crowded, differentiation erodes

**Mitigation**

1. **Move fast on agent orchestration**: Get to 10,000+ deployments before competitors ship
2. **Build community moat**: Once 1000+ developers are using Shipwright, switching cost is high
3. **Go deeper on enterprise**: Copilot is consumer-first; we own self-hosted + compliance
4. **Unique positioning**: Agent teams + fleet orchestration is hard to replicate; own it

---

### Risk: Open-source adoption plateaus (early adopter ceiling)

**Impact**: Medium — community doesn't grow beyond 1K developers

**Mitigation**

1. Enterprise pricing tier unlocks revenue even if adoption plateaus
2. Partnerships with Anthropic, GitHub, DevOps platforms amplify reach
3. Focus on developer experience (one-liner install, <10 min to first success)
4. Measure and optimize for viral growth (referral loops, Twitter threads)

---

### Risk: Dashboard/SaaS offering dilutes focus from open-source

**Impact**: Low-Medium — team gets spread thin, quality degrades

**Mitigation**

1. Hire dedicated SaaS engineering team (Phase 3)
2. Keep OSS on critical path: SaaS = extension, not core
3. Clear separation: "Free community edition on your infra" vs. "Managed Shipwright"
4. Ensure SaaS is optional; worst case we remain pure OSS

---

### Risk: Enterprise deals take longer than expected (sales cycle)

**Impact**: Low — doesn't affect organic growth, just timing of revenue

**Mitigation**

1. Start enterprise conversations in Q3 (6-month sales cycle means Q4 closes)
2. Use freemium tier to build POC partnerships first
3. Price competitively ($5K-$15K/year for SMB, $50K+/year for enterprise)
4. Offer managed services as option (removes "complex to deploy" objection)

---

## Part VI: Organization & Roles

### Phase 1-2 (Self-Funded / Angel)

| Role             | Headcount | Responsibilities                          |
| ---------------- | --------- | ----------------------------------------- |
| Founder/Core Dev | 1         | Product, core features, community         |
| Contributors     | 3-5       | Agents, integrations, testing (part-time) |

### Phase 3 (Series A / Venture)

| Role            | Headcount | Responsibilities                   |
| --------------- | --------- | ---------------------------------- |
| Founder/CEO     | 1         | Product, strategy, fundraising     |
| Head of Product | 1         | Roadmap, prioritization, releases  |
| Lead Engineer   | 2         | Core pipeline, daemon, quality     |
| DevOps Engineer | 1         | Infrastructure, deploy automation  |
| DevRel          | 1         | Community, content, partnerships   |
| Sales Engineer  | 1         | Enterprise deals, customer success |

### Phase 4 (Series B)

| Role                   | Headcount |
| ---------------------- | --------- |
| Engineering            | 6-8       |
| Product/Design         | 2         |
| Sales/Customer Success | 3-4       |
| DevRel/Marketing       | 2         |
| Operations/Finance     | 1-2       |

---

## Part VII: Competitive Landscape

### Market Position

```
                      Self-Hosted                    SaaS
Proprietary          [GitHub Actions]         [GitHub Copilot for Enterprise]
                                              [Cursor + Team Workspace]

Open Source          [Shipwright]  <---        [Conventional CI/CD]
                                              (Jenkins, GitLab CI, etc.)

       Complexity → [Basic Agents] — [Orchestration] — [Multi-Agent Teams]
```

**Shipwright's Unique Quadrant**: Open-source + self-hosted + multi-agent orchestration.

### Competitive Advantages

| Feature              | Shipwright | Cursor  | Copilot Enterprise | Actions |
| -------------------- | ---------- | ------- | ------------------ | ------- |
| Autonomous pipelines | ✓          | ✗       | ✗                  | ✗       |
| Agent orchestration  | ✓          | Limited | ✗                  | ✗       |
| Self-hosted          | ✓          | ✗       | Limited            | ✓       |
| Cost transparency    | ✓          | ✗       | ✗                  | ✗       |
| DORA metrics         | ✓          | ✗       | ✗                  | Limited |
| GitHub integration   | ✓          | ✗       | Limited            | ✓       |

### Market Trends Favoring Shipwright

1. **AI Skepticism**: Enterprise wary of black-box SaaS; prefer self-hosted control
2. **Agent Craze**: Every dev tool adding "agentic capabilities"; Shipwright is native
3. **Cost Awareness**: Claude API costs rising; budget-conscious teams want ROI visibility
4. **DevOps Shift**: Delivery acceleration is now table-stakes competitive advantage
5. **Open Source Preference**: Enterprise favors OSS for critical infrastructure

---

## Appendix: Roadmap Prioritization Matrix

**Framework**: Impact (business value) × Effort (dev cost)

```
                 High Impact
                     |
    Fast Wins        |        Major Initiatives
  (do first)        |         (sequence carefully)
                    |
            ————————————————
 Low Effort |        |        | High Effort
            |        |        |
   Filler   |        |        | R&D / Exploration
            |        |        |
                 Low Impact
```

**Fast Wins** (Phase 1)

- Quality gates (issue 60)
- Dashboard v1 (issue 45)
- Terminal streaming (issue 42)

**Major Initiatives** (Phase 2-3)

- Multi-model orchestration (issue 56)
- GitHub App (issue 57)
- Event-driven architecture (issue 51)
- Enterprise RBAC (issue 15)

**R&D / Exploration** (Phase 4+)

- Production feedback loop (issue 52)
- Cross-pipeline learning (issue 53)
- Release train automation (issue 59)

---

## Implementation Timeline

```
Feb 2026 (Now)        Phase 1 Kickoff
├─ Launch Product Hunt + HN
├─ Setup Discord community
└─ Begin Phase 1 work (stability, docs, DX)

Mar 2026              Phase 1 Completion
├─ v1.13.0 Release (dashboard, streaming, quality gates)
├─ GitHub stars: 1K target
├─ Blog: Case studies published
└─ Begin Phase 2 work (intelligence, cost)

Apr-May 2026          Phase 2 Execution
├─ Multi-model orchestration
├─ Cost dashboard
├─ Conference talks submitted
└─ Community growth: 200+ Discord members

Jun 2026              Phase 2 Completion + Phase 3 Kickoff
├─ v1.14.0 Release (intelligence, cost, DORA metrics)
├─ GitHub stars: 3K target
├─ Begin Phase 3 work (enterprise, auth, integrations)
└─ Start enterprise sales conversations

Jul-Aug 2026          Phase 3 Execution
├─ GitHub App development
├─ Enterprise security audit
└─ Conference talks (GitHub Universe, QCon)

Sep 2026              Phase 3 Completion
├─ v1.15.0 Release (GitHub App, enterprise RBAC)
├─ SOC 2 Type II cert in progress
├─ GitHub stars: 5K target
└─ First enterprise pilot deal

Oct-Dec 2026          Phase 4 Transition
├─ Event-driven architecture work
├─ Production feedback loop
├─ Release train automation
└─ Marketplace + template library

2027+                 Scale & Platform
├─ 10K+ active deployments
├─ 50+ enterprise customers
├─ AI-native delivery standard in industry
└─ Strategic acquisition / Series B opportunity
```

---

## Conclusion

Shipwright is positioned at the intersection of three major industry shifts:

1. **AI-First Delivery**: Developers expect AI to ship code, not just complete it
2. **Agent Orchestration**: Multi-agent teams are the frontier; single agents are table-stakes
3. **Open Source Preference**: Enterprise trusts open-source infrastructure over proprietary black boxes

The go-to-market strategy leverages organic GitHub growth + strategic partnerships + targeted enterprise sales to reach $10M+ ARR by 2027.

**Success requires ruthless focus on:**

- Developer experience (time-to-first-success)
- Community momentum (virality)
- Enterprise trust (compliance, support)
- Cost transparency (build loyalty)

**Next 90 days:**

- Make Phase 1 rock solid (stability, docs, DX)
- Launch Product Hunt, Hacker News, Discord
- Publish case studies, competitive analysis
- Start enterprise sales outreach

---

**Document Owner**: Seth Ford
**Last Updated**: February 14, 2026
**Next Review**: March 31, 2026
