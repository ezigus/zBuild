import { describe, it, expect } from "vitest";
import {
  colors,
  fonts,
  typeScale,
  spacing,
  radius,
  shadows,
  duration,
  easing,
  zIndex,
  STAGES,
  STAGE_SHORT,
  STAGE_COLORS,
  STAGE_HEX,
} from "./tokens";
import type { StageName } from "./tokens";

describe("Design Tokens", () => {
  describe("colors", () => {
    it("has all background colors", () => {
      expect(colors.bg).toHaveProperty("abyss");
      expect(colors.bg).toHaveProperty("deep");
      expect(colors.bg).toHaveProperty("ocean");
      expect(colors.bg).toHaveProperty("surface");
      expect(colors.bg).toHaveProperty("foam");
    });

    it("has accent colors as valid hex/rgba", () => {
      expect(colors.accent.cyan).toMatch(/^#[0-9a-f]{6}$/i);
      expect(colors.accent.purple).toMatch(/^#[0-9a-f]{6}$/i);
      expect(colors.accent.blue).toMatch(/^#[0-9a-f]{6}$/i);
      expect(colors.accent.cyanGlow).toMatch(/^rgba\(/);
    });

    it("has semantic colors", () => {
      expect(colors.semantic.success).toMatch(/^#/);
      expect(colors.semantic.warning).toMatch(/^#/);
      expect(colors.semantic.error).toMatch(/^#/);
    });

    it("has text colors", () => {
      expect(colors.text.primary).toMatch(/^#/);
      expect(colors.text.secondary).toMatch(/^#/);
      expect(colors.text.muted).toMatch(/^#/);
    });
  });

  describe("fonts", () => {
    it("defines display, body, and mono font stacks", () => {
      expect(fonts.display).toContain("serif");
      expect(fonts.body).toContain("sans-serif");
      expect(fonts.mono).toContain("monospace");
    });
  });

  describe("typeScale", () => {
    it("has all scale levels", () => {
      const levels = [
        "display",
        "heading",
        "title",
        "body",
        "caption",
        "tiny",
        "mono",
        "monoSm",
      ];
      for (const level of levels) {
        const entry = typeScale[level as keyof typeof typeScale];
        expect(entry).toHaveProperty("size");
        expect(entry).toHaveProperty("weight");
        expect(entry).toHaveProperty("family");
        expect(entry.size).toBeGreaterThan(0);
      }
    });

    it("sizes are ordered display > heading > title > body > caption > tiny", () => {
      expect(typeScale.display.size).toBeGreaterThan(typeScale.heading.size);
      expect(typeScale.heading.size).toBeGreaterThan(typeScale.title.size);
      expect(typeScale.title.size).toBeGreaterThan(typeScale.body.size);
      expect(typeScale.body.size).toBeGreaterThan(typeScale.caption.size);
      expect(typeScale.caption.size).toBeGreaterThan(typeScale.tiny.size);
    });
  });

  describe("spacing", () => {
    it("defines a spacing scale", () => {
      expect(spacing[0]).toBe(0);
      expect(spacing[1]).toBe(4);
      expect(spacing[2]).toBe(8);
      expect(spacing[4]).toBe(16);
      expect(spacing[8]).toBe(32);
    });

    it("has increasing values", () => {
      const keys = Object.keys(spacing)
        .map(Number)
        .sort((a, b) => a - b);
      for (let i = 1; i < keys.length; i++) {
        expect(spacing[keys[i]]).toBeGreaterThanOrEqual(spacing[keys[i - 1]]);
      }
    });
  });

  describe("radius", () => {
    it("has sm < md < lg < xl < full", () => {
      expect(radius.sm).toBeLessThan(radius.md);
      expect(radius.md).toBeLessThan(radius.lg);
      expect(radius.lg).toBeLessThan(radius.xl);
      expect(radius.xl).toBeLessThan(radius.full);
    });
  });

  describe("shadows", () => {
    it("has glow shadows for each semantic color", () => {
      expect(shadows.glow.cyan).toContain("rgba");
      expect(shadows.glow.purple).toContain("rgba");
      expect(shadows.glow.success).toContain("rgba");
      expect(shadows.glow.error).toContain("rgba");
    });

    it("has an elevated shadow", () => {
      expect(shadows.elevated).toContain("rgba");
    });
  });

  describe("duration", () => {
    it("has increasing animation durations", () => {
      expect(duration.fast).toBeLessThan(duration.base);
      expect(duration.base).toBeLessThan(duration.slow);
      expect(duration.slow).toBeLessThan(duration.glacial);
    });
  });

  describe("easing", () => {
    it("defines easing curves", () => {
      expect(easing.default).toBe("ease");
      expect(easing.smooth).toContain("cubic-bezier");
      expect(easing.spring).toContain("cubic-bezier");
    });
  });

  describe("zIndex", () => {
    it("has increasing z-index values", () => {
      expect(zIndex.base).toBeLessThan(zIndex.dropdown);
      expect(zIndex.dropdown).toBeLessThan(zIndex.sticky);
      expect(zIndex.sticky).toBeLessThan(zIndex.overlay);
      expect(zIndex.overlay).toBeLessThan(zIndex.modal);
      expect(zIndex.modal).toBeLessThan(zIndex.toast);
    });
  });

  describe("STAGES", () => {
    it("defines the pipeline stage sequence", () => {
      expect(STAGES).toHaveLength(11);
      expect(STAGES[0]).toBe("intake");
      expect(STAGES[STAGES.length - 1]).toBe("monitor");
    });

    it("includes all expected stages", () => {
      const expected = [
        "intake",
        "plan",
        "design",
        "build",
        "test",
        "review",
        "compound_quality",
        "pr",
        "merge",
        "deploy",
        "monitor",
      ];
      expect([...STAGES]).toEqual(expected);
    });
  });

  describe("STAGE_SHORT", () => {
    it("maps every stage to a short code", () => {
      for (const stage of STAGES) {
        expect(STAGE_SHORT[stage]).toBeDefined();
        expect(STAGE_SHORT[stage].length).toBeLessThanOrEqual(3);
      }
    });
  });

  describe("STAGE_COLORS", () => {
    it("has a color class for each stage", () => {
      expect(STAGE_COLORS).toHaveLength(STAGES.length);
      for (const cls of STAGE_COLORS) {
        expect(cls).toMatch(/^c-/);
      }
    });
  });

  describe("STAGE_HEX", () => {
    it("maps every stage to a hex color", () => {
      for (const stage of STAGES) {
        expect(STAGE_HEX[stage]).toMatch(/^#[0-9a-f]{6}$/i);
      }
    });
  });
});
