import { describe, it, expect } from "vitest";
import { renderSVGBarChart } from "./bar";

describe("bar", () => {
  describe("renderSVGBarChart", () => {
    it("returns empty string for empty data", () => {
      expect(renderSVGBarChart([])).toBe("");
    });

    it("returns empty string for null/undefined", () => {
      expect(renderSVGBarChart(null as unknown as never[])).toBe("");
    });

    it("returns SVG with rect for single bar", () => {
      const data = [{ date: "2025-02-17", completed: 5, failed: 2 }];
      const svg = renderSVGBarChart(data);
      expect(svg).toContain('<svg class="svg-bar-chart"');
      expect(svg).toContain("<rect");
      expect(svg).toContain('fill="#4ade80"');
      expect(svg).toContain('fill="#f43f5e"');
    });

    it("returns SVG with multiple rects for multiple bars", () => {
      const data = [
        { date: "2025-02-15", completed: 3, failed: 0 },
        { date: "2025-02-16", completed: 5, failed: 1 },
        { date: "2025-02-17", completed: 2, failed: 3 },
      ];
      const svg = renderSVGBarChart(data);
      expect(svg).toContain('<svg class="svg-bar-chart"');
      const rectCount = (svg.match(/<rect/g) || []).length;
      expect(rectCount).toBeGreaterThanOrEqual(3);
      const textCount = (svg.match(/<text/g) || []).length;
      expect(textCount).toBe(3);
    });

    it("renders zero-value bars as thin rect (1px)", () => {
      const data = [{ date: "2025-02-17", completed: 0, failed: 0 }];
      const svg = renderSVGBarChart(data);
      expect(svg).toContain("<rect");
      expect(svg).toContain('height="1"');
      expect(svg).toContain('fill="#0d1f3c"');
    });

    it("renders labels from date (MM/DD format)", () => {
      const data = [{ date: "2025-02-17", completed: 1, failed: 0 }];
      const svg = renderSVGBarChart(data);
      expect(svg).toContain("02/17");
    });

    it("handles dates without enough parts (falls back to full date)", () => {
      const data = [{ date: "2025", completed: 1, failed: 0 }];
      const svg = renderSVGBarChart(data);
      expect(svg).toContain("2025");
    });

    it("escapes HTML in labels", () => {
      const data = [{ date: "2025-02-17<script>", completed: 1, failed: 0 }];
      const svg = renderSVGBarChart(data);
      expect(svg).toContain("&lt;script&gt;");
      expect(svg).not.toContain("<script>");
    });

    it("handles missing completed/failed (treats as 0)", () => {
      const data = [
        { date: "2025-02-17", completed: undefined, failed: undefined },
      ];
      const svg = renderSVGBarChart(data as never[]);
      expect(svg).toContain("<rect");
      expect(svg).toContain('height="1"');
    });

    it("has correct viewBox dimensions", () => {
      const data = [{ date: "2025-02-17", completed: 5, failed: 2 }];
      const svg = renderSVGBarChart(data);
      expect(svg).toContain('viewBox="0 0 700 120"');
    });
  });
});
