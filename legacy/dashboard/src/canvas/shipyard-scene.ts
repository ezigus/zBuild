// Shipyard Scene — Main CanvasScene compositing hull, compartments, agents, and effects
// Implements the CanvasScene interface for CanvasRenderer.

import { store } from "../core/state";
import { colors, STAGES, STAGE_HEX } from "../design/tokens";
import type { StageName } from "../design/tokens";
import {
  nautical,
  layout as layoutConst,
  STAGE_TO_COMPARTMENT,
  crewRoleForStage,
} from "../design/submarine-theme";
import { formatDuration } from "../core/helpers";
import {
  drawText,
  drawRoundRect,
  drawCircle,
  type CanvasScene,
} from "./renderer";
import { SubmarineLayout, type CompartmentRect } from "./submarine-layout";
import { PixelAgent } from "./pixel-agent";
import { renderSprite, getSpawnMask, clearSpriteCache } from "./pixel-sprites";
import { NauticalEffects } from "./shipyard-effects";
import type { FleetState, PipelineInfo } from "../types/api";

// ── ShipyardScene ────────────────────────────────────────────────────────────

export class ShipyardScene implements CanvasScene {
  layout = new SubmarineLayout();
  agents: PixelAgent[] = [];
  effects = new NauticalEffects();
  time = 0;
  width = 0;
  height = 0;

  // Interaction
  hoveredAgent: PixelAgent | null = null;
  hoveredCompartment: CompartmentRect | null = null;
  mouseX = 0;
  mouseY = 0;

  // Track previous pipeline stages for detecting stage changes
  private prevStages: Map<number, string> = new Map();

  updateData(data: FleetState): void {
    if (!data.pipelines) return;

    const currentIssues = new Set(data.pipelines.map((p) => p.issue));

    // Despawn agents for pipelines that no longer exist
    for (const agent of this.agents) {
      if (!currentIssues.has(agent.issue) && agent.state !== "despawn") {
        agent.setDespawn();
      }
    }

    // Remove dead agents
    this.agents = this.agents.filter((a) => !a.isDead());

    // Sync existing agents and create new ones
    for (const pipeline of data.pipelines) {
      const existing = this.agents.find((a) => a.issue === pipeline.issue);

      if (existing) {
        // Detect stage changes for effects
        const prevStage = this.prevStages.get(pipeline.issue);
        if (prevStage && prevStage !== pipeline.stage) {
          // Stage completed — emit sonar ping at new compartment
          const comp = this.layout.getCompartment(pipeline.stage as StageName);
          if (comp) {
            const stageColor =
              STAGE_HEX[pipeline.stage as StageName] || colors.accent.cyan;
            this.effects.emitSonarPing(comp.centerX, comp.centerY, stageColor);
          }
        }

        existing.syncFromPipeline(
          {
            stage: pipeline.stage,
            elapsed_s: pipeline.elapsed_s,
            iteration: pipeline.iteration,
            status: pipeline.status || "active",
          },
          this.layout,
        );
      } else {
        // New pipeline — spawn agent
        const stage = pipeline.stage as StageName;
        const comp = this.layout.getCompartment(stage);
        if (comp) {
          const role = crewRoleForStage(stage);
          const agent = new PixelAgent(
            pipeline.issue,
            stage,
            role,
            comp.stationX,
            comp.stationY,
          );
          agent.elapsed_s = pipeline.elapsed_s;
          agent.iteration = pipeline.iteration;
          agent.status = pipeline.status || "active";
          this.agents.push(agent);
        }
      }

      this.prevStages.set(pipeline.issue, pipeline.stage);
    }

    // Clean up prevStages for gone pipelines
    for (const [issue] of this.prevStages) {
      if (!currentIssues.has(issue)) {
        this.prevStages.delete(issue);
      }
    }

    // Update active compartments in effects
    const activeStages = new Set(data.pipelines.map((p) => p.stage));
    for (const stage of STAGES) {
      this.effects.setActiveCompartment(stage, activeStages.has(stage));
    }

    // Update depth progress (average pipeline progress)
    if (data.pipelines.length > 0) {
      const totalProgress = data.pipelines.reduce((sum, p) => {
        const stageIdx = STAGES.indexOf(p.stage as StageName);
        return sum + (stageIdx >= 0 ? stageIdx / (STAGES.length - 1) : 0);
      }, 0);
      this.effects.setDepthProgress(totalProgress / data.pipelines.length);
    } else {
      this.effects.setDepthProgress(0);
    }

    // Update pipe flows
    this.effects.clearPipeFlows();
    for (const pipe of this.layout.pipes) {
      this.effects.addPipeFlow(pipe.from, pipe.to, nautical.pipeFlow);
    }
  }

  update(dt: number): void {
    this.time += dt;

    // Update agents
    for (const agent of this.agents) {
      agent.update(dt, this.layout);

      // Emit bubbles near working agents
      if (agent.state === "working" && Math.random() < 0.02) {
        this.effects.emitBubbles(agent.x, agent.y - 10, 1);
      }
    }

    // Update effects
    this.effects.update(dt);

    // Ambient bubbles across the scene
    if (Math.random() < 0.03 && this.width > 0) {
      this.effects.emitAmbientBubbles(this.width, this.height);
    }
  }

  draw(ctx: CanvasRenderingContext2D, width: number, height: number): void {
    // ── 1. Ocean background ──
    this.drawOceanBackground(ctx, width, height);

    // ── 2. Porthole glow (behind hull) ──
    this.effects.drawPortholeGlow(ctx, this.layout.portholes);

    // ── 3. Hull ──
    this.drawHull(ctx);

    // ── 4. Compartments ──
    this.drawCompartments(ctx);

    // ── 5. Pipe flows ──
    this.effects.drawPipeFlows(ctx);

    // ── 6. Agents ──
    this.drawAgents(ctx);

    // ── 7. Sonar pings & particles ──
    this.effects.drawSonarPings(ctx);
    this.effects.draw(ctx, width, height);

    // ── 8. Depth gauge ──
    this.effects.drawDepthGauge(
      ctx,
      4,
      this.layout.hull.y,
      this.layout.hull.height,
    );

    // ── 9. HUD: crew manifest bar ──
    this.drawCrewManifest(ctx, width, height);

    // ── 10. Tooltip ──
    if (this.hoveredAgent) {
      this.drawAgentTooltip(ctx, this.hoveredAgent);
    }

    // ── 11. Empty state ──
    if (this.agents.length === 0) {
      this.drawEmptyState(ctx, width, height);
    }
  }

  // ── Drawing sub-methods ──────────────────────────────────────────────────

  private drawOceanBackground(
    ctx: CanvasRenderingContext2D,
    width: number,
    height: number,
  ): void {
    // Gradient from deep ocean at top to slightly lighter at bottom
    const gradient = ctx.createLinearGradient(0, 0, 0, height);
    gradient.addColorStop(0, nautical.oceanDeep);
    gradient.addColorStop(0.5, nautical.oceanMid);
    gradient.addColorStop(1, nautical.oceanLight);
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, width, height);
  }

  private drawHull(ctx: CanvasRenderingContext2D): void {
    const h = this.layout.hull;
    if (h.width <= 0 || h.height <= 0) return;

    // Hull outer glow
    ctx.save();
    ctx.shadowColor = nautical.hullHighlight;
    ctx.shadowBlur = 20;
    drawRoundRect(ctx, h.x, h.y, h.width, h.height, h.radius);
    ctx.fillStyle = nautical.hullOuter;
    ctx.fill();
    ctx.restore();

    // Hull inner fill
    drawRoundRect(
      ctx,
      h.x + 2,
      h.y + 2,
      h.width - 4,
      h.height - 4,
      h.radius - 2,
    );
    ctx.fillStyle = nautical.hullInner;
    ctx.fill();

    // Hull border
    drawRoundRect(ctx, h.x, h.y, h.width, h.height, h.radius);
    ctx.strokeStyle = nautical.hullStroke;
    ctx.lineWidth = 2;
    ctx.stroke();

    // Portholes
    for (const p of this.layout.portholes) {
      drawCircle(
        ctx,
        p.x,
        p.y,
        layoutConst.portholeRadius,
        nautical.portholeGlass,
        nautical.portholeRing,
        1.5,
      );
    }
  }

  private drawCompartments(ctx: CanvasRenderingContext2D): void {
    for (const comp of this.layout.compartments) {
      const isHovered = this.hoveredCompartment === comp;
      const stageColor = STAGE_HEX[comp.stage] || colors.accent.cyan;

      // Compartment glow if active
      const hasActiveAgent = this.agents.some(
        (a) => a.stage === comp.stage && a.state !== "despawn",
      );
      if (hasActiveAgent) {
        this.effects.drawCompartmentGlow(ctx, comp, stageColor);
      }

      // Compartment background
      drawRoundRect(
        ctx,
        comp.x,
        comp.y,
        comp.width,
        comp.height,
        layoutConst.compartmentRadius,
      );
      ctx.fillStyle = isHovered
        ? nautical.compartmentActive
        : nautical.compartmentBg;
      ctx.fill();

      // Compartment border
      drawRoundRect(
        ctx,
        comp.x,
        comp.y,
        comp.width,
        comp.height,
        layoutConst.compartmentRadius,
      );
      ctx.strokeStyle = hasActiveAgent
        ? stageColor + "60"
        : nautical.compartmentBorder;
      ctx.lineWidth = 1;
      ctx.stroke();

      // Label
      drawText(ctx, comp.label, comp.centerX, comp.y + 6, {
        font: "tiny",
        color: hasActiveAgent ? nautical.labelActive : nautical.labelColor,
        align: "center",
      });

      // Stage abbreviation at bottom
      const shortLabel =
        comp.stage === "compound_quality"
          ? "QA"
          : comp.stage.toUpperCase().slice(0, 3);
      drawText(ctx, shortLabel, comp.centerX, comp.y + comp.height - 14, {
        font: "monoSm",
        color: stageColor + "80",
        align: "center",
      });
    }
  }

  private drawAgents(ctx: CanvasRenderingContext2D): void {
    for (const agent of this.agents) {
      const action = agent.getSpriteAction();
      const frame = agent.getSpriteFrame();
      const scale = 2;

      const spriteCanvas = renderSprite(
        agent.role,
        action,
        frame,
        agent.direction,
        scale,
      );

      const drawX = agent.x - spriteCanvas.width / 2;
      const drawY = agent.getDisplayY() - spriteCanvas.height + 8;

      if (agent.state === "spawn") {
        // Spawn cascade: draw only revealed rows
        const mask = getSpawnMask(agent.spawnProgress);
        const rowHeight = 24; // pixel height of sprite
        const revealedRows = Math.floor(rowHeight * agent.spawnProgress);

        ctx.save();
        ctx.globalAlpha = 0.5 + agent.spawnProgress * 0.5;
        ctx.drawImage(
          spriteCanvas,
          0,
          0,
          spriteCanvas.width,
          revealedRows * scale,
          drawX,
          drawY,
          spriteCanvas.width,
          revealedRows * scale,
        );
        ctx.restore();
      } else if (agent.state === "despawn") {
        ctx.save();
        ctx.globalAlpha = agent.spawnProgress;
        ctx.drawImage(spriteCanvas, drawX, drawY);
        ctx.restore();
      } else if (agent.state === "alert") {
        // Flash effect
        const flash = Math.sin(this.time * 8) > 0;
        ctx.save();
        if (flash) {
          ctx.globalAlpha = 0.5;
        }
        ctx.drawImage(spriteCanvas, drawX, drawY);
        ctx.restore();

        // Alert exclamation
        if (flash) {
          drawText(ctx, "!", agent.x, drawY - 8, {
            font: "title",
            color: colors.semantic.error,
            align: "center",
          });
        }
      } else {
        ctx.drawImage(spriteCanvas, drawX, drawY);
      }

      // Issue number label below agent
      drawText(ctx, `#${agent.issue}`, agent.x, agent.getDisplayY() + 12, {
        font: "monoSm",
        color: colors.text.muted,
        align: "center",
      });

      // Hover highlight
      if (this.hoveredAgent === agent) {
        drawCircle(
          ctx,
          agent.x,
          agent.getDisplayY() - 12,
          22,
          undefined,
          colors.accent.cyan,
          1.5,
        );
      }
    }
  }

  private drawCrewManifest(
    ctx: CanvasRenderingContext2D,
    width: number,
    height: number,
  ): void {
    const barY = height - layoutConst.manifestHeight;
    const barHeight = layoutConst.manifestHeight;

    // Background
    ctx.fillStyle = nautical.oceanDeep;
    ctx.fillRect(0, barY, width, barHeight);

    // Top border
    ctx.strokeStyle = nautical.hullStroke;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, barY);
    ctx.lineTo(width, barY);
    ctx.stroke();

    // Label
    drawText(ctx, "CREW", 8, barY + 4, {
      font: "tiny",
      color: nautical.labelColor,
    });

    // Agent dots
    const dotStartX = 50;
    const dotSpacing = 24;
    for (let i = 0; i < this.agents.length; i++) {
      const agent = this.agents[i];
      const dx = dotStartX + i * dotSpacing;
      const dy = barY + barHeight / 2;

      // Status dot color
      let dotColor: string = colors.accent.cyan;
      if (agent.state === "working") dotColor = colors.semantic.success;
      else if (agent.state === "alert") dotColor = colors.semantic.error;
      else if (agent.state === "walk") dotColor = colors.semantic.warning;

      drawCircle(ctx, dx, dy, 4, dotColor);

      // Issue number
      drawText(ctx, `${agent.issue}`, dx, dy + 8, {
        font: "tiny",
        color: colors.text.muted,
        align: "center",
      });
    }

    // Pipeline count
    drawText(
      ctx,
      `${this.agents.length} active`,
      width - 8,
      barY + barHeight / 2 - 6,
      {
        font: "caption",
        color: nautical.labelColor,
        align: "right",
      },
    );
  }

  private drawAgentTooltip(
    ctx: CanvasRenderingContext2D,
    agent: PixelAgent,
  ): void {
    const lines = [
      `Issue #${agent.issue}`,
      `Stage: ${agent.stage}`,
      `Elapsed: ${formatDuration(agent.elapsed_s)}`,
      `Iteration: ${agent.iteration}`,
      `Status: ${agent.status}`,
    ];

    const padding = 8;
    const lineHeight = 16;
    const tooltipWidth = 160;
    const tooltipHeight = lines.length * lineHeight + padding * 2;

    let tx = this.mouseX + 12;
    let ty = this.mouseY - tooltipHeight - 4;
    if (tx + tooltipWidth > this.width) tx = this.mouseX - tooltipWidth - 12;
    if (ty < 0) ty = this.mouseY + 12;

    // Background
    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,0.5)";
    ctx.shadowBlur = 8;
    drawRoundRect(ctx, tx, ty, tooltipWidth, tooltipHeight, 6);
    ctx.fillStyle = colors.bg.deep + "f0";
    ctx.fill();
    ctx.restore();

    // Border
    drawRoundRect(ctx, tx, ty, tooltipWidth, tooltipHeight, 6);
    ctx.strokeStyle = colors.accent.cyan + "40";
    ctx.lineWidth = 1;
    ctx.stroke();

    // Text
    for (let i = 0; i < lines.length; i++) {
      drawText(ctx, lines[i], tx + padding, ty + padding + i * lineHeight, {
        font: i === 0 ? "caption" : "tiny",
        color: i === 0 ? colors.text.primary : colors.text.secondary,
      });
    }
  }

  private drawEmptyState(
    ctx: CanvasRenderingContext2D,
    width: number,
    height: number,
  ): void {
    const centerX = width / 2;
    const centerY = height / 2;

    drawText(ctx, "Awaiting Orders", centerX, centerY - 20, {
      font: "heading",
      color: nautical.labelColor,
      align: "center",
      baseline: "middle",
    });

    drawText(
      ctx,
      "No active pipelines. Start a pipeline to see your crew in action.",
      centerX,
      centerY + 10,
      {
        font: "body",
        color: colors.text.muted,
        align: "center",
        baseline: "middle",
        maxWidth: 400,
      },
    );
  }

  // ── CanvasScene lifecycle ──────────────────────────────────────────────────

  onResize(width: number, height: number): void {
    this.width = width;
    this.height = height;
    this.layout.recalculate(width, height);

    // Reposition agents to their current compartment stations
    for (const agent of this.agents) {
      const comp = this.layout.getCompartment(agent.stage);
      if (comp && agent.state !== "walk") {
        agent.x = comp.stationX;
        agent.y = comp.stationY;
        agent.targetX = comp.stationX;
        agent.targetY = comp.stationY;
      }
    }

    // Clear sprite cache on resize (scale may have changed)
    clearSpriteCache();
  }

  onMouseMove(x: number, y: number): void {
    this.mouseX = x;
    this.mouseY = y;

    // Hit test agents (check within 20px radius)
    this.hoveredAgent = null;
    for (const agent of this.agents) {
      const dx = x - agent.x;
      const dy = y - agent.getDisplayY();
      if (dx * dx + dy * dy < 400) {
        // 20px radius
        this.hoveredAgent = agent;
        break;
      }
    }

    // Hit test compartments
    this.hoveredCompartment = this.hoveredAgent
      ? null
      : this.layout.hitTestCompartment(x, y) || null;
  }

  onMouseClick(x: number, y: number): void {
    if (this.hoveredAgent) {
      // Click agent → navigate to pipeline theater
      const issue = this.hoveredAgent.issue;
      this.effects.emitSparkle(this.hoveredAgent.x, this.hoveredAgent.y);

      import("../core/router").then(({ switchTab }) => {
        store.set("selectedPipelineIssue", issue);
        switchTab("pipeline-theater");
      });
    }
  }

  onMouseWheel(_delta: number): void {
    // No zoom/pan for shipyard — fixed viewport
  }
}
