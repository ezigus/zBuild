import { describe, it, expect } from "vitest";
import { renderSVGDonut } from "./donut";

describe("donut", () => {
  describe("renderSVGDonut", () => {
    it("renders SVG with zero rate", () => {
      const svg = renderSVGDonut(0);
      expect(svg).toContain('<svg class="svg-donut"');
      expect(svg).toContain('viewBox="0 0 120 120"');
      expect(svg).toContain("<circle");
      expect(svg).toContain("0.0%");
    });

    it("renders SVG with single segment (partial fill)", () => {
      const svg = renderSVGDonut(50);
      expect(svg).toContain('<svg class="svg-donut"');
      expect(svg).toContain("<circle");
      expect(svg).toContain("50.0%");
      expect(svg).toContain("stroke-dasharray");
      expect(svg).toContain("stroke-dashoffset");
    });

    it("renders SVG with full segment (100%)", () => {
      const svg = renderSVGDonut(100);
      expect(svg).toContain('<svg class="svg-donut"');
      expect(svg).toContain("100.0%");
    });

    it("contains expected SVG elements: circle, defs, text", () => {
      const svg = renderSVGDonut(75);
      expect(svg).toContain("<defs>");
      expect(svg).toContain("linearGradient");
      expect(svg).toContain("donut-grad");
      expect(svg).toContain("<circle");
      expect(svg).toContain("<text");
      expect(svg).toContain('text-anchor="middle"');
    });

    it("clamps negative rate to 0", () => {
      const svg = renderSVGDonut(-10);
      expect(svg).toContain("0.0%");
    });

    it("clamps rate above 100 to 100", () => {
      const svg = renderSVGDonut(150);
      expect(svg).toContain("100.0%");
    });

    it("renders label with percentage", () => {
      const svg = renderSVGDonut(33.5);
      expect(svg).toContain("33.5%");
    });

    it("has fixed size 120x120", () => {
      const svg = renderSVGDonut(25);
      expect(svg).toContain('width="120"');
      expect(svg).toContain('height="120"');
    });

    it("uses background circle and gradient stroke circle", () => {
      const svg = renderSVGDonut(50);
      const circleCount = (svg.match(/<circle/g) || []).length;
      expect(circleCount).toBe(2);
      expect(svg).toContain('stroke="#0d1f3c"');
      expect(svg).toContain('stroke="url(#donut-grad)"');
    });
  });
});
