// Pixel Agent State Machine — Submarine crew members animated across compartments

import type { StageName } from "../design/tokens";
import type { CrewRole } from "../design/submarine-theme";
import { timing } from "../design/submarine-theme";
import { crewRoleForStage } from "../design/submarine-theme";
import type { SubmarineLayout } from "./submarine-layout";

// ── Types ────────────────────────────────────────────────────────────────────

export type AgentState =
  | "spawn"
  | "idle"
  | "walk"
  | "working"
  | "alert"
  | "despawn";

export type SpriteAction = "idle" | "walk" | "work" | "alert";

// ── PixelAgent class ────────────────────────────────────────────────────────

export class PixelAgent {
  // Identity
  issue: number;
  stage: StageName;
  role: CrewRole;

  // Position & movement
  x: number;
  y: number;
  targetX: number;
  targetY: number;
  direction: "left" | "right" = "right";
  path: Point[] = [];
  pathIndex: number = 0;

  // Animation state
  state: AgentState = "spawn";
  stateTime: number = 0;
  frameIndex: number = 0;
  frameTimer: number = 0;

  // Spawn/despawn progress (0-1)
  spawnProgress: number = 0;

  // Idle behavior
  idleBobOffset: number = 0;
  nextWanderTime: number = 0;

  // Pipeline data
  elapsed_s: number = 0;
  iteration: number = 0;
  status: string = "idle";

  constructor(
    issue: number,
    stage: StageName,
    role: CrewRole,
    x: number,
    y: number,
  ) {
    this.issue = issue;
    this.stage = stage;
    this.role = role;
    this.x = x;
    this.y = y;
    this.targetX = x;
    this.targetY = y;
    this.nextWanderTime =
      Math.random() * (timing.idleWanderRange[1] - timing.idleWanderRange[0]) +
      timing.idleWanderRange[0];
  }

  update(dt: number, layout: SubmarineLayout): void {
    this.stateTime += dt;
    this.frameTimer += dt;

    switch (this.state) {
      case "spawn":
        this.spawnProgress = Math.min(
          1,
          this.spawnProgress + dt / timing.spawnDuration,
        );
        if (this.spawnProgress >= 1) {
          this.state = "idle";
          this.stateTime = 0;
        }
        break;

      case "idle":
        this.updateIdleState(dt, layout);
        break;

      case "walk":
        this.updateWalkState(dt);
        break;

      case "working":
        this.updateWorkingState(dt);
        break;

      case "alert":
        this.updateAlertState(dt);
        break;

      case "despawn":
        this.spawnProgress = Math.max(
          0,
          this.spawnProgress - dt / timing.despawnDuration,
        );
        break;
    }
  }

  private updateIdleState(dt: number, layout: SubmarineLayout): void {
    // Idle bob animation
    const bobFreq = (2 * Math.PI) / timing.idleBobPeriod;
    this.idleBobOffset =
      Math.sin(this.stateTime * bobFreq) * timing.idleBobAmplitude;

    // Advance idle frame
    const idleFrameInterval = 0.5;
    if (this.frameTimer >= idleFrameInterval) {
      this.frameIndex = (this.frameIndex + 1) % 2;
      this.frameTimer = 0;
    }

    // Occasional wander
    this.nextWanderTime -= dt;
    if (this.nextWanderTime <= 0) {
      const wanderDistance = 20;
      const wanderX = this.x + (Math.random() - 0.5) * wanderDistance;
      const wanderY = this.y + (Math.random() - 0.5) * wanderDistance;
      this.targetX = wanderX;
      this.targetY = wanderY;

      this.nextWanderTime =
        Math.random() *
          (timing.idleWanderRange[1] - timing.idleWanderRange[0]) +
        timing.idleWanderRange[0];
    }
  }

  private updateWalkState(dt: number): void {
    if (this.path.length === 0) {
      this.state = "working";
      this.stateTime = 0;
      this.frameIndex = 0;
      this.frameTimer = 0;
      return;
    }

    const target = this.path[this.pathIndex];
    const dx = target.x - this.x;
    const dy = target.y - this.y;
    const distance = Math.sqrt(dx * dx + dy * dy);

    // Update direction
    if (dx !== 0) {
      this.direction = dx > 0 ? "right" : "left";
    }

    if (distance < 2) {
      // Reached waypoint, move to next
      this.pathIndex++;
      if (this.pathIndex >= this.path.length) {
        this.x = target.x;
        this.y = target.y;
        this.state = "working";
        this.stateTime = 0;
        this.frameIndex = 0;
        this.frameTimer = 0;
      }
      return;
    }

    // Move toward target
    const moveDistance = Math.min(distance, timing.walkSpeed * dt);
    const moveRatio = moveDistance / distance;
    this.x += dx * moveRatio;
    this.y += dy * moveRatio;

    // Advance walk frame
    const walkFrameInterval = 0.15;
    if (this.frameTimer >= walkFrameInterval) {
      this.frameIndex = (this.frameIndex + 1) % 4;
      this.frameTimer = 0;
    }
  }

  private updateWorkingState(dt: number): void {
    // Work animation: 2 frames at 0.3s interval
    const workFrameInterval = timing.workFrameInterval;
    if (this.frameTimer >= workFrameInterval) {
      this.frameIndex = (this.frameIndex + 1) % 2;
      this.frameTimer = 0;
    }
  }

  private updateAlertState(dt: number): void {
    // Alert flash: frame 0 for 0.4s, frame 1 for 0.4s
    const flashInterval = timing.alertFlashInterval;
    const cycle = (this.stateTime % (flashInterval * 2)) / flashInterval;
    this.frameIndex = cycle < 1 ? 0 : 1;
  }

  moveTo(stage: StageName, layout: SubmarineLayout): void {
    const targetComp = layout.getCompartment(stage);
    if (!targetComp) return;

    const currentComp = layout.getCompartment(this.stage);
    if (!currentComp) return;

    this.path = layout.getPathBetween(this.stage, stage);
    if (this.path.length === 0) return;

    this.stage = stage;
    this.role = crewRoleForStage(stage);
    this.targetX = targetComp.stationX;
    this.targetY = targetComp.stationY;
    this.pathIndex = 0;
    this.state = "walk";
    this.stateTime = 0;
    this.frameIndex = 0;
    this.frameTimer = 0;
  }

  setAlert(): void {
    this.state = "alert";
    this.stateTime = 0;
    this.frameIndex = 0;
    this.frameTimer = 0;
  }

  setDespawn(): void {
    this.state = "despawn";
    this.spawnProgress = 1;
  }

  syncFromPipeline(
    pipeline: {
      stage: string;
      elapsed_s: number;
      iteration: number;
      status: string;
    },
    layout: SubmarineLayout,
  ): void {
    const newStage = pipeline.stage as StageName;
    const stageChanged = this.stage !== newStage;

    this.elapsed_s = pipeline.elapsed_s;
    this.iteration = pipeline.iteration;
    this.status = pipeline.status;

    if (stageChanged) {
      this.moveTo(newStage, layout);
    }

    if (pipeline.status === "failed") {
      this.setAlert();
    }
  }

  isDead(): boolean {
    return this.state === "despawn" && this.spawnProgress <= 0;
  }

  getSpriteAction(): SpriteAction {
    switch (this.state) {
      case "spawn":
      case "idle":
        return "idle";
      case "walk":
        return "walk";
      case "working":
        return "work";
      case "alert":
      case "despawn":
        return "alert";
    }
  }

  getSpriteFrame(): number {
    return this.frameIndex;
  }

  getDisplayY(): number {
    return this.y + this.idleBobOffset;
  }
}

// Re-export Point type from layout
export interface Point {
  x: number;
  y: number;
}
