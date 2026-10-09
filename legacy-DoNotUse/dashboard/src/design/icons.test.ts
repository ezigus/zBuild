import { describe, it, expect } from "vitest";
import { icon, iconNames } from "./icons";
import type { IconName } from "./icons";

describe("Icons", () => {
  describe("iconNames", () => {
    it("exports a non-empty list of icon names", () => {
      expect(iconNames.length).toBeGreaterThan(0);
    });

    it("includes essential navigation icons", () => {
      const essential = [
        "anchor",
        "layout-dashboard",
        "users",
        "activity",
        "server",
      ];
      for (const name of essential) {
        expect(iconNames).toContain(name);
      }
    });

    it("includes status icons", () => {
      const status = [
        "circle-check",
        "circle-x",
        "circle-alert",
        "circle-pause",
      ];
      for (const name of status) {
        expect(iconNames).toContain(name);
      }
    });

    it("includes action icons", () => {
      const actions = ["play", "pause", "send", "plus", "x", "copy"];
      for (const name of actions) {
        expect(iconNames).toContain(name);
      }
    });
  });

  describe("icon()", () => {
    it("returns an SVG string for a valid icon", () => {
      const svg = icon("anchor");
      expect(svg).toContain("<svg");
      expect(svg).toContain("</svg>");
      expect(svg).toContain('xmlns="http://www.w3.org/2000/svg"');
    });

    it("returns empty string for unknown icon", () => {
      const svg = icon("nonexistent-icon-name" as IconName);
      expect(svg).toBe("");
    });

    it("uses default size of 16", () => {
      const svg = icon("anchor");
      expect(svg).toContain('width="16"');
      expect(svg).toContain('height="16"');
    });

    it("respects custom size", () => {
      const svg = icon("anchor", 24);
      expect(svg).toContain('width="24"');
      expect(svg).toContain('height="24"');
    });

    it("applies color attribute when provided", () => {
      const svg = icon("anchor", 16, "#ff0000");
      expect(svg).toContain('color="#ff0000"');
    });

    it("omits color attribute when not provided", () => {
      const svg = icon("anchor");
      expect(svg).not.toContain("color=");
    });

    it("always includes stroke attributes", () => {
      const svg = icon("anchor");
      expect(svg).toContain('stroke="currentColor"');
      expect(svg).toContain('stroke-width="2"');
      expect(svg).toContain('stroke-linecap="round"');
      expect(svg).toContain('stroke-linejoin="round"');
    });

    it("includes fill=none", () => {
      const svg = icon("anchor");
      expect(svg).toContain('fill="none"');
    });

    it("uses 24x24 viewBox", () => {
      const svg = icon("anchor");
      expect(svg).toContain('viewBox="0 0 24 24"');
    });

    it("renders every registered icon without error", () => {
      for (const name of iconNames) {
        const svg = icon(name);
        expect(svg).toContain("<svg");
        expect(svg).toContain("</svg>");
      }
    });
  });
});
