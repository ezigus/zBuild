// Submarine Theme — Nautical design constants for the Shipyard tab
// Maps pipeline stages to submarine compartments, crew roles, and visual styling.

import type { StageName } from "./tokens";

// ── Compartment definitions ──────────────────────────────────────────────────

export interface Compartment {
  stage: StageName;
  label: string;
  icon: string;
  row: number; // 0=top, 1=mid, 2=bottom
  col: number; // position within row
}

export const COMPARTMENTS: Compartment[] = [
  // Row 0 — upper deck
  { stage: "intake", label: "Airlock", icon: "\u{1F6AA}", row: 0, col: 0 },
  { stage: "plan", label: "Bridge", icon: "\u{1F9ED}", row: 0, col: 1 },
  { stage: "design", label: "Nav Room", icon: "\u{1F4D0}", row: 0, col: 2 },
  {
    stage: "build",
    label: "Engine Room",
    icon: "\u2699\uFE0F",
    row: 0,
    col: 3,
  },
  // Row 1 — mid deck
  { stage: "test", label: "Testing Bay", icon: "\u{1F52C}", row: 1, col: 0 },
  { stage: "review", label: "War Room", icon: "\u{1F4CB}", row: 1, col: 1 },
  {
    stage: "compound_quality",
    label: "Sonar Room",
    icon: "\u{1F4E1}",
    row: 1,
    col: 2,
  },
  { stage: "pr", label: "Comms", icon: "\u{1F4FB}", row: 1, col: 3 },
  // Row 2 — lower deck
  { stage: "merge", label: "Reactor", icon: "\u269B\uFE0F", row: 2, col: 0 },
  { stage: "deploy", label: "Ballast", icon: "\u{1F680}", row: 2, col: 1 },
  { stage: "monitor", label: "Periscope", icon: "\u{1F52D}", row: 2, col: 2 },
];

export const STAGE_TO_COMPARTMENT: Record<StageName, Compartment> =
  Object.fromEntries(COMPARTMENTS.map((c) => [c.stage, c])) as Record<
    StageName,
    Compartment
  >;

// ── Crew roles ───────────────────────────────────────────────────────────────

export type CrewRole =
  | "captain"
  | "engineer"
  | "navigator"
  | "operator"
  | "medic"
  | "sonarTech";

export interface CrewPalette {
  role: CrewRole;
  /** Primary uniform hue (0-360) */
  hue: number;
  /** Saturation % */
  sat: number;
  /** Lightness for body */
  bodyL: number;
  /** Lightness for highlight/trim */
  trimL: number;
  /** Accent color hex (hat, badge, accessory) */
  accent: string;
  /** Skin tone base (HSL lightness) */
  skinL: number;
}

export const CREW_PALETTES: Record<CrewRole, CrewPalette> = {
  captain: {
    role: "captain",
    hue: 220,
    sat: 70,
    bodyL: 25,
    trimL: 55,
    accent: "#ffd700",
    skinL: 72,
  },
  engineer: {
    role: "engineer",
    hue: 25,
    sat: 85,
    bodyL: 45,
    trimL: 60,
    accent: "#ff8c00",
    skinL: 72,
  },
  navigator: {
    role: "navigator",
    hue: 140,
    sat: 55,
    bodyL: 30,
    trimL: 55,
    accent: "#2ecc71",
    skinL: 72,
  },
  operator: {
    role: "operator",
    hue: 50,
    sat: 80,
    bodyL: 50,
    trimL: 65,
    accent: "#f1c40f",
    skinL: 72,
  },
  medic: {
    role: "medic",
    hue: 0,
    sat: 0,
    bodyL: 90,
    trimL: 95,
    accent: "#e74c3c",
    skinL: 72,
  },
  sonarTech: {
    role: "sonarTech",
    hue: 185,
    sat: 70,
    bodyL: 35,
    trimL: 55,
    accent: "#00d4ff",
    skinL: 72,
  },
};

/** Map stages to default crew roles */
export const STAGE_CREW_ROLE: Record<StageName, CrewRole> = {
  intake: "sonarTech",
  plan: "captain",
  design: "navigator",
  build: "engineer",
  test: "engineer",
  review: "medic",
  compound_quality: "medic",
  pr: "sonarTech",
  merge: "operator",
  deploy: "operator",
  monitor: "navigator",
};

/** Pick a crew role for a pipeline based on its current stage */
export function crewRoleForStage(stage: StageName): CrewRole {
  return STAGE_CREW_ROLE[stage];
}

// ── Nautical color palette ───────────────────────────────────────────────────

export const nautical = {
  // Hull
  hullOuter: "#1a2a3a",
  hullInner: "#0f1d2d",
  hullStroke: "#2a4a6a",
  hullHighlight: "rgba(0, 212, 255, 0.08)",

  // Ocean / background
  oceanDeep: "#040810",
  oceanMid: "#071018",
  oceanLight: "#0a1828",

  // Compartment
  compartmentBg: "#0c1a2e",
  compartmentBorder: "#1a3050",
  compartmentActive: "rgba(0, 212, 255, 0.12)",

  // Pipes
  pipeColor: "#1a3050",
  pipeFlow: "#00d4ff",
  pipeFlowDim: "rgba(0, 212, 255, 0.3)",

  // Porthole
  portholeRing: "#2a4a6a",
  portholeGlass: "rgba(0, 212, 255, 0.06)",
  portholeGlow: "rgba(0, 212, 255, 0.15)",

  // Effects
  bubbleColor: "rgba(120, 200, 255, 0.4)",
  sonarColor: "#00d4ff",
  sparkleColor: "#ffffff",

  // Depth gauge
  depthGaugeBg: "#0a1628",
  depthGaugeFill: "#00d4ff",
  depthGaugeBorder: "#1a3050",

  // Text
  labelColor: "#8899b8",
  labelActive: "#e8ecf4",
} as const;

// ── Layout constants ─────────────────────────────────────────────────────────

export const layout = {
  /** Rows in the submarine */
  rows: 3,
  /** Max columns per row */
  maxCols: 4,
  /** Padding inside hull */
  hullPadding: 24,
  /** Gap between compartments */
  compartmentGap: 12,
  /** Compartment corner radius */
  compartmentRadius: 6,
  /** Hull corner radius */
  hullRadius: 32,
  /** Depth gauge width */
  depthGaugeWidth: 24,
  /** Crew manifest bar height */
  manifestHeight: 36,
  /** Min compartment size */
  minCompartmentW: 100,
  minCompartmentH: 70,
  /** Pipe width */
  pipeWidth: 2,
  /** Porthole radius */
  portholeRadius: 8,
} as const;

// ── Animation timing ─────────────────────────────────────────────────────────

export const timing = {
  /** Agent walk speed in pixels/second */
  walkSpeed: 48,
  /** Idle bob amplitude in pixels */
  idleBobAmplitude: 1,
  /** Idle bob period in seconds */
  idleBobPeriod: 2,
  /** Idle wander interval range [min, max] seconds */
  idleWanderRange: [2, 4] as [number, number],
  /** Working frame interval in seconds */
  workFrameInterval: 0.3,
  /** Alert flash interval in seconds */
  alertFlashInterval: 0.4,
  /** Spawn cascade duration in seconds */
  spawnDuration: 0.5,
  /** Despawn dissolve duration in seconds */
  despawnDuration: 0.5,
  /** Sonar ping ring expand duration */
  sonarPingDuration: 1.5,
  /** Sonar ping ring count */
  sonarPingRings: 3,
  /** Pipe flow dash speed (px/s) */
  pipeFlowSpeed: 30,
  /** Bubble rise speed (px/s) */
  bubbleRiseSpeed: 15,
} as const;
