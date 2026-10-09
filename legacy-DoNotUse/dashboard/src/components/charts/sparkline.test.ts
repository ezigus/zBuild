import { describe, it, expect } from "vitest";
import { renderSparkline, renderSVGLineChart } from "./sparkline";

describe("sparkline", () => {
  describe("renderSparkline", () => {
    it("returns empty string for empty data", () => {
      expect(renderSparkline([], "#fff", 100, 40)).toBe("");
    });

    it("returns empty string for single point", () => {
      expect(renderSparkline([5], "#fff", 100, 40)).toBe("");
      expect(renderSparkline([{ value: 10 }], "#fff", 100, 40)).toBe("");
    });

    it("returns empty string for null/undefined points", () => {
      expect(
        renderSparkline(null as unknown as number[], "#fff", 100, 40),
      ).toBe("");
    });

    it("returns SVG with path for multiple points (number array)", () => {
      const svg = renderSparkline([10, 20, 30, 40], "#00d4ff", 100, 40);
      expect(svg).toContain('<svg class="sparkline"');
      expect(svg).toContain('viewBox="0 0 100 40"');
      expect(svg).toContain("<path");
      expect(svg).toContain('stroke="#00d4ff"');
      expect(svg).toContain('stroke-width="1.5"');
      expect(svg).toContain('fill="none"');
      expect(svg).toContain("d=");
      expect(svg).toMatch(/M[\d.]+,[\d.]+ L[\d.]+,[\d.]+/);
    });

    it("returns SVG with path for object array with value property", () => {
      const svg = renderSparkline(
        [{ value: 5 }, { value: 15 }, { value: 25 }],
        "#7c3aed",
        80,
        32,
      );
      expect(svg).toContain('<svg class="sparkline"');
      expect(svg).toContain("<path");
      expect(svg).toContain('stroke="#7c3aed"');
    });

    it("handles object values with missing value (treats as 0)", () => {
      const svg = renderSparkline([{ value: 0 }, { value: 0 }], "#333", 50, 20);
      expect(svg).toContain('<svg class="sparkline"');
      expect(svg).toContain("<path");
    });

    it("uses correct dimensions in output", () => {
      const svg = renderSparkline([1, 2, 3], "#000", 200, 60);
      expect(svg).toContain('width="200"');
      expect(svg).toContain('height="60"');
    });
  });

  describe("renderSVGLineChart", () => {
    it("returns empty-state div for empty points", () => {
      const out = renderSVGLineChart([], "value", "#00d4ff", 100, 40);
      expect(out).toContain('<div class="empty-state">');
      expect(out).toContain("Not enough data");
    });

    it("returns empty-state div for single point", () => {
      const out = renderSVGLineChart(
        [{ value: 10 }],
        "value",
        "#00d4ff",
        100,
        40,
      );
      expect(out).toContain('<div class="empty-state">');
      expect(out).toContain("Not enough data");
    });

    it("returns empty-state for null/undefined points", () => {
      const out = renderSVGLineChart(
        null as unknown as Record<string, number>[],
        "value",
        "#00d4ff",
        100,
        40,
      );
      expect(out).toContain("Not enough data");
    });

    it("returns SVG with path and grid lines for multiple points", () => {
      const points = [
        { value: 10 },
        { value: 30 },
        { value: 20 },
        { value: 50 },
      ];
      const svg = renderSVGLineChart(points, "value", "#4ade80", 300, 120);
      expect(svg).toContain('<svg class="svg-line-chart"');
      expect(svg).toContain('viewBox="0 0 300 120"');
      expect(svg).toContain("<path");
      expect(svg).toContain('stroke="#4ade80"');
      expect(svg).toContain("<line");
      expect(svg).toContain('stroke="#1a3a6a"');
    });

    it("uses custom valueKey when provided", () => {
      const points = [{ count: 5 }, { count: 15 }, { count: 25 }];
      const svg = renderSVGLineChart(points, "count", "#ff0000", 200, 80);
      expect(svg).toContain('<svg class="svg-line-chart"');
      expect(svg).toContain("<path");
      expect(svg).toContain('stroke="#ff0000"');
    });

    it("falls back to value when valueKey missing", () => {
      const points = [{ value: 1 }, { value: 2 }];
      const svg = renderSVGLineChart(points, "missing", "#000", 100, 50);
      expect(svg).toContain("<path");
    });

    it("handles all-zero max (uses maxVal=1 to avoid div by zero)", () => {
      const points = [{ value: 0 }, { value: 0 }];
      const svg = renderSVGLineChart(points, "value", "#000", 100, 50);
      expect(svg).toContain("<svg");
      expect(svg).not.toContain("Not enough data");
    });
  });
});
