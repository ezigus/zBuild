// Submarine Layout System — Compartment positioning, hull geometry, and navigation paths

import type { StageName } from "../design/tokens";
import { COMPARTMENTS, STAGE_TO_COMPARTMENT } from "../design/submarine-theme";
import { layout, timing } from "../design/submarine-theme";

// ── Types ────────────────────────────────────────────────────────────────────

export interface Point {
  x: number;
  y: number;
}

export interface CompartmentRect {
  stage: StageName;
  label: string;
  icon: string;
  x: number;
  y: number;
  width: number;
  height: number;
  centerX: number;
  centerY: number;
  stationX: number; // where agent stands to work
  stationY: number;
}

export interface HullGeometry {
  x: number;
  y: number;
  width: number;
  height: number;
  radius: number;
}

export interface PipeSegment {
  from: Point;
  to: Point;
}

// ── SubmarineLayout class ────────────────────────────────────────────────────

export class SubmarineLayout {
  compartments: CompartmentRect[] = [];
  hull: HullGeometry = { x: 0, y: 0, width: 0, height: 0, radius: 0 };
  pipes: PipeSegment[] = [];
  portholes: Point[] = [];
  width = 0;
  height = 0;

  recalculate(width: number, height: number): void {
    this.width = width;
    this.height = height;

    // Compute available space
    const depthGaugeWidth = layout.depthGaugeWidth;
    const gap = 12; // gap between depth gauge and hull
    const manifestHeight = layout.manifestHeight;
    const hullPadding = layout.hullPadding;
    const compartmentGap = layout.compartmentGap;

    const availableWidth = width - depthGaugeWidth - gap;
    const availableHeight = height - manifestHeight;

    // Hull takes up ~85% of height, centered vertically
    const hullHeightRatio = 0.85;
    const hullHeight = Math.floor(availableHeight * hullHeightRatio);
    const hullWidth = availableWidth - gap;

    // Center hull vertically
    const topMargin = Math.floor((availableHeight - hullHeight) / 2);
    const hullX = depthGaugeWidth + gap;
    const hullY = topMargin;

    this.hull = {
      x: hullX,
      y: hullY,
      width: hullWidth,
      height: hullHeight,
      radius: layout.hullRadius,
    };

    // Compute compartment layout: 3 rows
    this.computeCompartments();
    this.computePipes();
    this.computePortholes();
  }

  private computeCompartments(): void {
    this.compartments = [];

    const innerX = this.hull.x + layout.hullPadding;
    const innerY = this.hull.y + layout.hullPadding;
    const innerWidth = this.hull.width - layout.hullPadding * 2;
    const innerHeight = this.hull.height - layout.hullPadding * 2;

    // Row sizes: 4, 4, 3 compartments
    const rowSizes = [4, 4, 3];
    const numRows = rowSizes.length;
    const rowHeight =
      (innerHeight - (numRows - 1) * layout.compartmentGap) / numRows;

    for (let rowIdx = 0; rowIdx < numRows; rowIdx++) {
      const colCount = rowSizes[rowIdx];
      const colWidth =
        (innerWidth - (colCount - 1) * layout.compartmentGap) / colCount;

      const rowY = innerY + rowIdx * (rowHeight + layout.compartmentGap);

      for (let colIdx = 0; colIdx < colCount; colIdx++) {
        const compartment = COMPARTMENTS.find(
          (c) => c.row === rowIdx && c.col === colIdx,
        );

        if (!compartment) continue;

        const x = innerX + colIdx * (colWidth + layout.compartmentGap);

        const rect: CompartmentRect = {
          stage: compartment.stage,
          label: compartment.label,
          icon: compartment.icon,
          x,
          y: rowY,
          width: colWidth,
          height: rowHeight,
          centerX: x + colWidth / 2,
          centerY: rowY + rowHeight / 2,
          stationX: x + colWidth / 2,
          stationY: rowY + rowHeight / 2,
        };

        this.compartments.push(rect);
      }
    }
  }

  private computePipes(): void {
    this.pipes = [];

    // Connect adjacent compartments in the same row horizontally
    const compartmentsByRow: { [key: number]: CompartmentRect[] } = {};
    for (const comp of this.compartments) {
      const compartment = COMPARTMENTS.find((c) => c.stage === comp.stage);
      if (compartment) {
        if (!compartmentsByRow[compartment.row]) {
          compartmentsByRow[compartment.row] = [];
        }
        compartmentsByRow[compartment.row].push(comp);
      }
    }

    // Connect horizontally within rows
    for (const row of Object.values(compartmentsByRow)) {
      row.sort((a, b) => a.x - b.x);
      for (let i = 0; i < row.length - 1; i++) {
        this.pipes.push({
          from: { x: row[i].x + row[i].width, y: row[i].centerY },
          to: { x: row[i + 1].x, y: row[i + 1].centerY },
        });
      }
    }

    // Connect rows vertically at the end of each row
    for (let rowIdx = 0; rowIdx < 2; rowIdx++) {
      const currentRow = compartmentsByRow[rowIdx];
      const nextRow = compartmentsByRow[rowIdx + 1];
      if (currentRow && nextRow) {
        const lastInCurrent = currentRow[currentRow.length - 1];
        const firstInNext = nextRow[0];
        this.pipes.push({
          from: {
            x: lastInCurrent.centerX,
            y: lastInCurrent.y + lastInCurrent.height,
          },
          to: { x: firstInNext.centerX, y: firstInNext.y },
        });
      }
    }
  }

  private computePortholes(): void {
    this.portholes = [];

    const portholesPerEdge = 4;
    const topY = this.hull.y + layout.portholeRadius;
    const bottomY = this.hull.y + this.hull.height - layout.portholeRadius;

    // Top portholes
    for (let i = 0; i < portholesPerEdge; i++) {
      const x =
        this.hull.x +
        layout.portholeRadius +
        (i * (this.hull.width - 2 * layout.portholeRadius)) /
          (portholesPerEdge - 1);
      this.portholes.push({ x, y: topY });
    }

    // Bottom portholes
    for (let i = 0; i < portholesPerEdge; i++) {
      const x =
        this.hull.x +
        layout.portholeRadius +
        (i * (this.hull.width - 2 * layout.portholeRadius)) /
          (portholesPerEdge - 1);
      this.portholes.push({ x, y: bottomY });
    }
  }

  getCompartment(stage: StageName): CompartmentRect | undefined {
    return this.compartments.find((c) => c.stage === stage);
  }

  getPathBetween(from: StageName, to: StageName): Point[] {
    const fromComp = this.getCompartment(from);
    const toComp = this.getCompartment(to);

    if (!fromComp || !toComp) return [];
    if (from === to) return [{ x: fromComp.stationX, y: fromComp.stationY }];

    const fromCompartmentDef = STAGE_TO_COMPARTMENT[from];
    const toCompartmentDef = STAGE_TO_COMPARTMENT[to];

    const fromRow = fromCompartmentDef.row;
    const toRow = toCompartmentDef.row;

    const waypoints: Point[] = [{ x: fromComp.stationX, y: fromComp.stationY }];

    if (fromRow === toRow) {
      // Same row: straight horizontal path
      waypoints.push({ x: toComp.stationX, y: toComp.stationY });
    } else {
      // Different rows: exit compartment, move to row connector, vertical, then horizontal to target

      // Move to right edge of current compartment
      waypoints.push({
        x: fromComp.x + fromComp.width + layout.compartmentGap / 2,
        y: fromComp.centerY,
      });

      // Move vertically to target row
      waypoints.push({
        x: fromComp.x + fromComp.width + layout.compartmentGap / 2,
        y: toComp.centerY,
      });

      // Move horizontally to target
      waypoints.push({ x: toComp.stationX, y: toComp.stationY });
    }

    return waypoints;
  }

  hitTestCompartment(x: number, y: number): CompartmentRect | undefined {
    for (const comp of this.compartments) {
      if (
        x >= comp.x &&
        x <= comp.x + comp.width &&
        y >= comp.y &&
        y <= comp.y + comp.height
      ) {
        return comp;
      }
    }
    return undefined;
  }
}
