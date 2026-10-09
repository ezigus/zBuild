// Nautical visual effects system for submarine dashboard
// Bubbles, sonar pings, sparkles, depth gauge, pipe flow, and hull glow

import { ParticleSystem } from "./particles";
import { nautical, layout, timing } from "../design/submarine-theme";
import { drawText, drawCircle } from "./renderer";

export interface SonarPing {
  x: number;
  y: number;
  color: string;
  time: number;
  duration: number;
  rings: number;
}

export interface PipeFlow {
  fromX: number;
  fromY: number;
  toX: number;
  toY: number;
  color: string;
  offset: number;
}

export class NauticalEffects {
  private particles: ParticleSystem;
  private sonarPings: SonarPing[] = [];
  private pipeFlows: PipeFlow[] = [];
  private activeCompartments: Set<string> = new Set();
  private depthProgress: number = 0;
  private time: number = 0;

  constructor() {
    this.particles = new ParticleSystem();
  }

  update(dt: number): void {
    this.time += dt;
    this.particles.update(dt);

    // Update sonar pings
    for (let i = this.sonarPings.length - 1; i >= 0; i--) {
      this.sonarPings[i].time += dt;
      if (this.sonarPings[i].time >= this.sonarPings[i].duration) {
        this.sonarPings.splice(i, 1);
      }
    }

    // Update pipe flows (animate dash offset)
    for (const flow of this.pipeFlows) {
      flow.offset -= timing.pipeFlowSpeed * dt;
      // Reset offset when it goes too far
      if (flow.offset < -10) {
        flow.offset = 0;
      }
    }

    // Emit ambient bubbles (low probability per frame)
    if (Math.random() < 0.05) {
      const x = Math.random() * 800 - 400;
      const y = Math.random() * 600;
      this.emitAmbientBubbles(800, 600);
    }
  }

  draw(ctx: CanvasRenderingContext2D, width: number, height: number): void {
    // Draw background effects (before compartments)
    // Note: This is called by scene, order controlled by caller

    // Draw overlays (after compartments)
    this.drawSonarPings(ctx);
    this.drawPipeFlows(ctx);
    this.particles.draw(ctx);
  }

  // ── Bubble effects ──────────────────────────────────────────────

  emitBubbles(x: number, y: number, count: number = 3): void {
    for (let i = 0; i < count; i++) {
      const angle = Math.random() * Math.PI * 2;
      const speed = Math.random() * 10 + 5;

      this.particles.emit(
        x + Math.cos(angle) * 8,
        y + Math.sin(angle) * 8,
        "ambient",
        nautical.bubbleColor,
        1,
      );

      // Customize the last emitted particle for bubble behavior
      const particle = (this.particles as any).particles[
        (this.particles as any).particles.length - 1
      ];
      if (particle) {
        particle.vx = (Math.random() - 0.5) * 6; // Slight horizontal drift
        particle.vy = -(Math.random() * 10 + 15); // Rise upward
        particle.size = Math.random() * 2.5 + 1.5;
        particle.maxLife = Math.random() * 3 + 3; // 3-6s lifetime
      }
    }
  }

  emitAmbientBubbles(width: number, height: number): void {
    const x = Math.random() * width;
    const y = Math.random() * height;
    this.emitBubbles(x, y, Math.random() < 0.5 ? 1 : 2);
  }

  // ── Sonar effects ──────────────────────────────────────────────

  emitSonarPing(x: number, y: number, color: string): void {
    this.sonarPings.push({
      x,
      y,
      color,
      time: 0,
      duration: timing.sonarPingDuration,
      rings: timing.sonarPingRings,
    });
  }

  // ── Sparkle effects ────────────────────────────────────────────

  emitSparkle(x: number, y: number): void {
    const count = Math.random() * 4 + 8; // 8-12 particles
    for (let i = 0; i < count; i++) {
      this.particles.emit(x, y, "burst", nautical.sparkleColor, 1);
    }
    // Customize burst particles for sparkle behavior
    const particles = (this.particles as any).particles;
    for (
      let i = Math.max(0, particles.length - count);
      i < particles.length;
      i++
    ) {
      const p = particles[i];
      p.maxLife = 0.4;
      p.size = Math.random() * 1.5 + 1;
    }
  }

  // ── Compartment glow ───────────────────────────────────────────

  setActiveCompartment(stage: string, active: boolean): void {
    if (active) {
      this.activeCompartments.add(stage);
    } else {
      this.activeCompartments.delete(stage);
    }
  }

  // ── Depth gauge ────────────────────────────────────────────────

  setDepthProgress(progress: number): void {
    this.depthProgress = Math.max(0, Math.min(1, progress));
  }

  // ── Pipe flows ─────────────────────────────────────────────────

  addPipeFlow(
    from: { x: number; y: number },
    to: { x: number; y: number },
    color: string,
  ): void {
    this.pipeFlows.push({
      fromX: from.x,
      fromY: from.y,
      toX: to.x,
      toY: to.y,
      color,
      offset: 0,
    });
  }

  clearPipeFlows(): void {
    this.pipeFlows = [];
  }

  // ── Drawing methods ────────────────────────────────────────────

  drawSonarPings(ctx: CanvasRenderingContext2D): void {
    for (const ping of this.sonarPings) {
      const progress = ping.time / ping.duration;

      for (let ringIdx = 0; ringIdx < ping.rings; ringIdx++) {
        // Each ring starts with a delay
        const ringDelay = (ringIdx / ping.rings) * 0.4;
        const ringProgress =
          Math.max(0, progress - ringDelay) / (1 - ringDelay);

        if (ringProgress <= 0) continue;

        const maxRadius = 80;
        const radius = ringProgress * maxRadius;
        const alpha = Math.max(0, 0.6 * (1 - ringProgress));
        const lineWidth = Math.max(0.5, 2 * (1 - ringProgress));

        ctx.save();
        ctx.globalAlpha = alpha;
        ctx.strokeStyle = ping.color;
        ctx.lineWidth = lineWidth;
        drawCircle(
          ctx,
          ping.x,
          ping.y,
          radius,
          undefined,
          ping.color,
          lineWidth,
        );
        ctx.restore();
      }
    }
  }

  drawDepthGauge(
    ctx: CanvasRenderingContext2D,
    x: number,
    y: number,
    height: number,
  ): void {
    const width = layout.depthGaugeWidth;
    const gaugeHeight = height * 0.8;
    const gaugeY = y + (height - gaugeHeight) / 2;

    // Background
    ctx.fillStyle = nautical.depthGaugeBg;
    ctx.fillRect(x, gaugeY, width, gaugeHeight);

    // Fill (from bottom)
    const fillHeight = gaugeHeight * this.depthProgress;
    ctx.fillStyle = nautical.depthGaugeFill;
    ctx.fillRect(x, gaugeY + gaugeHeight - fillHeight, width, fillHeight);

    // Border
    ctx.strokeStyle = nautical.depthGaugeBorder;
    ctx.lineWidth = 1;
    ctx.strokeRect(x, gaugeY, width, gaugeHeight);

    // Stage notches
    const stages = 11;
    for (let i = 0; i <= stages; i++) {
      const notchY = gaugeY + (gaugeHeight * i) / stages;
      ctx.strokeStyle = nautical.depthGaugeBorder;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(x - 4, notchY);
      ctx.lineTo(x, notchY);
      ctx.stroke();
    }

    // Label "DEPTH"
    ctx.save();
    ctx.translate(x - 12, gaugeY + gaugeHeight / 2);
    ctx.rotate(-Math.PI / 2);
    drawText(ctx, "DEPTH", 0, 0, {
      font: "tiny",
      color: nautical.labelColor,
      align: "center",
      baseline: "middle",
    });
    ctx.restore();

    // Percentage at bottom
    const percent = Math.round(this.depthProgress * 100);
    drawText(ctx, `${percent}%`, x + width / 2, gaugeY + gaugeHeight + 8, {
      font: "caption",
      color: nautical.labelActive,
      align: "center",
    });
  }

  drawPipeFlows(ctx: CanvasRenderingContext2D): void {
    for (const flow of this.pipeFlows) {
      ctx.save();
      ctx.strokeStyle = flow.color;
      ctx.lineWidth = layout.pipeWidth;
      ctx.globalAlpha = 0.4;
      ctx.setLineDash([6, 4]);
      ctx.lineDashOffset = flow.offset;

      ctx.beginPath();
      ctx.moveTo(flow.fromX, flow.fromY);
      ctx.lineTo(flow.toX, flow.toY);
      ctx.stroke();

      ctx.restore();
    }
  }

  drawCompartmentGlow(
    ctx: CanvasRenderingContext2D,
    compartment: { x: number; y: number; width: number; height: number },
    color: string,
  ): void {
    ctx.save();
    ctx.shadowColor = color;
    ctx.shadowBlur = 12;
    ctx.shadowOffsetX = 0;
    ctx.shadowOffsetY = 0;

    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.globalAlpha = 0.3;

    // Draw a rectangle slightly larger than the compartment
    const inset = -2;
    ctx.strokeRect(
      compartment.x + inset,
      compartment.y + inset,
      compartment.width - inset * 2,
      compartment.height - inset * 2,
    );

    ctx.restore();
  }

  drawPortholeGlow(
    ctx: CanvasRenderingContext2D,
    portholes: { x: number; y: number }[],
  ): void {
    const glowIntensity = 0.4 + 0.3 * Math.sin(this.time * Math.PI);

    for (const porthole of portholes) {
      ctx.save();

      // Create radial gradient
      const gradient = ctx.createRadialGradient(
        porthole.x,
        porthole.y,
        0,
        porthole.x,
        porthole.y,
        layout.portholeRadius * 2,
      );
      gradient.addColorStop(0, nautical.portholeGlow);
      gradient.addColorStop(1, "rgba(0, 212, 255, 0)");

      ctx.fillStyle = gradient;
      ctx.globalAlpha = glowIntensity * 0.6;
      ctx.beginPath();
      ctx.arc(
        porthole.x,
        porthole.y,
        layout.portholeRadius * 2,
        0,
        Math.PI * 2,
      );
      ctx.fill();

      ctx.restore();
    }
  }

  // ── Cleanup ────────────────────────────────────────────────────

  clear(): void {
    this.particles.clear();
    this.sonarPings = [];
    this.pipeFlows = [];
    this.activeCompartments.clear();
    this.depthProgress = 0;
    this.time = 0;
  }
}
