import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  formatDuration,
  formatTime,
  escapeHtml,
  fmtNum,
  truncate,
  padZero,
  getBadgeClass,
  getTypeShort,
  animateValue,
  timeAgo,
  formatMarkdown,
} from "./helpers";

describe("helpers", () => {
  describe("formatDuration", () => {
    it("returns em dash for null/undefined", () => {
      expect(formatDuration(null)).toBe("\u2014");
      expect(formatDuration(undefined)).toBe("\u2014");
    });

    it("formats seconds (< 60)", () => {
      expect(formatDuration(0)).toBe("0s");
      expect(formatDuration(30)).toBe("30s");
      expect(formatDuration(59)).toBe("59s");
    });

    it("formats minutes and seconds (60-3599)", () => {
      expect(formatDuration(60)).toBe("1m 0s");
      expect(formatDuration(90)).toBe("1m 30s");
      expect(formatDuration(125)).toBe("2m 5s");
      expect(formatDuration(3599)).toBe("59m 59s");
    });

    it("formats hours and minutes (>= 3600)", () => {
      expect(formatDuration(3600)).toBe("1h 0m");
      expect(formatDuration(3661)).toBe("1h 1m");
      expect(formatDuration(7325)).toBe("2h 2m");
    });

    it("floors fractional seconds", () => {
      expect(formatDuration(59.9)).toBe("59s");
      expect(formatDuration(60.9)).toBe("1m 0s");
    });

    it("handles negative values (formats as seconds when abs < 60)", () => {
      expect(formatDuration(-5)).toBe("-5s");
      expect(formatDuration(-65)).toBe("-65s");
    });
  });

  describe("formatTime", () => {
    it("returns em dash for null/undefined/empty", () => {
      expect(formatTime(null)).toBe("\u2014");
      expect(formatTime(undefined)).toBe("\u2014");
      expect(formatTime("")).toBe("\u2014");
    });

    it("formats ISO string as HH:MM:SS (local time)", () => {
      const result = formatTime("2025-02-17T14:30:45Z");
      expect(result).toMatch(/^\d{2}:\d{2}:\d{2}$/);
      const [, , sec] = result.split(":");
      expect(Number(sec)).toBe(45);
    });
  });

  describe("escapeHtml", () => {
    it("returns empty string for null/undefined", () => {
      expect(escapeHtml(null)).toBe("");
      expect(escapeHtml(undefined)).toBe("");
    });

    it("escapes XSS characters", () => {
      expect(escapeHtml("<script>")).toBe("&lt;script&gt;");
      expect(escapeHtml(">")).toBe("&gt;");
      expect(escapeHtml("&")).toBe("&amp;");
      expect(escapeHtml('"')).toBe("&quot;");
    });

    it("escapes combined characters", () => {
      expect(escapeHtml('<img src="x">')).toBe("&lt;img src=&quot;x&quot;&gt;");
    });

    it("leaves single quote unchanged (not escaped in impl)", () => {
      expect(escapeHtml("'")).toBe("'");
    });
  });

  describe("fmtNum", () => {
    it("returns 0 for null/undefined", () => {
      expect(fmtNum(null)).toBe("0");
      expect(fmtNum(undefined)).toBe("0");
    });

    it("formats numbers with locale string", () => {
      expect(fmtNum(0)).toBe("0");
      expect(fmtNum(1000)).toBe("1,000");
      expect(fmtNum(1234567)).toBe("1,234,567");
    });
  });

  describe("truncate", () => {
    it("returns empty string for null/undefined", () => {
      expect(truncate(null, 10)).toBe("");
      expect(truncate(undefined, 10)).toBe("");
    });

    it("returns string as-is when within maxLen", () => {
      expect(truncate("hello", 10)).toBe("hello");
      expect(truncate("hello", 5)).toBe("hello");
    });

    it("truncates with ellipsis when exceeding maxLen", () => {
      expect(truncate("hello world", 5)).toBe("hello…");
      expect(truncate("abcdefghij", 8)).toBe("abcdefgh…");
    });
  });

  describe("padZero", () => {
    it("pads single digits with leading zero", () => {
      expect(padZero(0)).toBe("00");
      expect(padZero(5)).toBe("05");
      expect(padZero(9)).toBe("09");
    });

    it("does not pad double digits", () => {
      expect(padZero(10)).toBe("10");
      expect(padZero(99)).toBe("99");
    });
  });

  describe("getBadgeClass", () => {
    it("returns intervention for intervention type", () => {
      expect(getBadgeClass("foo.intervention")).toBe("intervention");
    });

    it("returns heartbeat for heartbeat type", () => {
      expect(getBadgeClass("machine.heartbeat")).toBe("heartbeat");
    });

    it("returns recovery for recovery/checkpoint", () => {
      expect(getBadgeClass("stage.recovery")).toBe("recovery");
      expect(getBadgeClass("foo.checkpoint")).toBe("recovery");
    });

    it("returns remote for remote/distributed", () => {
      expect(getBadgeClass("job.remote")).toBe("remote");
      expect(getBadgeClass("distributed.task")).toBe("remote");
    });

    it("returns other specific classes", () => {
      expect(getBadgeClass("poll")).toBe("poll");
      expect(getBadgeClass("spawn")).toBe("spawn");
      expect(getBadgeClass("started")).toBe("started");
      expect(getBadgeClass("completed")).toBe("completed");
      expect(getBadgeClass("reap")).toBe("completed");
      expect(getBadgeClass("failed")).toBe("failed");
      expect(getBadgeClass("stage")).toBe("stage");
      expect(getBadgeClass("scale")).toBe("scale");
    });

    it("returns default for unknown type", () => {
      expect(getBadgeClass("unknown")).toBe("default");
    });
  });

  describe("getTypeShort", () => {
    it("returns last segment of dotted type", () => {
      expect(getTypeShort("foo.bar.baz")).toBe("baz");
      expect(getTypeShort("machine.heartbeat")).toBe("heartbeat");
    });

    it("returns full string when no dots", () => {
      expect(getTypeShort("simple")).toBe("simple");
    });

    it("returns unknown for null/undefined (String converts)", () => {
      expect(getTypeShort("")).toBe("unknown");
    });
  });

  describe("animateValue", () => {
    let el: HTMLElement;

    beforeEach(() => {
      el = document.createElement("span");
      vi.useFakeTimers({ toFake: ["requestAnimationFrame"] });
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("does nothing when el is null", () => {
      animateValue(null, 0, 100, 1000);
      vi.advanceTimersToNextFrame();
      expect(el.textContent).toBe("");
    });

    it("sets final value immediately when start equals end", () => {
      animateValue(el, 50, 50, 1000);
      expect(el.textContent).toBe("50");
    });

    it("uses requestAnimationFrame when start differs from end", () => {
      animateValue(el, 0, 100, 1000);
      vi.advanceTimersToNextFrame();
      expect(el.textContent).toBe("0");
      vi.advanceTimersByTime(1000);
      vi.advanceTimersToNextFrame();
      expect(el.textContent).toBe("100");
    });

    it("appends suffix when provided", () => {
      animateValue(el, 10, 10, 1000, "%");
      expect(el.textContent).toBe("10%");
    });
  });

  describe("timeAgo", () => {
    const now = 1708200000000; // fixed timestamp

    beforeEach(() => {
      vi.useFakeTimers();
      vi.setSystemTime(now);
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("returns seconds ago when < 60s", () => {
      const date = new Date(now - 30 * 1000);
      expect(timeAgo(date)).toBe("30s ago");
      expect(timeAgo(new Date(now - 0))).toBe("0s ago");
      expect(timeAgo(new Date(now - 59 * 1000))).toBe("59s ago");
    });

    it("returns minutes ago when 60s to < 60m", () => {
      expect(timeAgo(new Date(now - 60 * 1000))).toBe("1m ago");
      expect(timeAgo(new Date(now - 90 * 1000))).toBe("1m ago");
      expect(timeAgo(new Date(now - 3599 * 1000))).toBe("59m ago");
    });

    it("returns hours ago when 60m to < 24h", () => {
      expect(timeAgo(new Date(now - 3600 * 1000))).toBe("1h ago");
      expect(timeAgo(new Date(now - 7200 * 1000))).toBe("2h ago");
      expect(timeAgo(new Date(now - 23 * 3600 * 1000))).toBe("23h ago");
    });

    it("returns days ago when >= 24h", () => {
      expect(timeAgo(new Date(now - 24 * 3600 * 1000))).toBe("1d ago");
      expect(timeAgo(new Date(now - 48 * 3600 * 1000))).toBe("2d ago");
    });
  });

  describe("formatMarkdown", () => {
    it("returns empty string for null/undefined", () => {
      expect(formatMarkdown(null)).toBe("");
      expect(formatMarkdown(undefined)).toBe("");
    });

    it("converts headers to strong", () => {
      expect(formatMarkdown("# Title")).toContain("<strong>Title</strong>");
      expect(formatMarkdown("## Subtitle")).toContain(
        "<strong>Subtitle</strong>",
      );
      expect(formatMarkdown("### Small")).toContain("<strong>Small</strong>");
    });

    it("converts code blocks to pre", () => {
      const result = formatMarkdown("```\nconst x = 1;\n```");
      expect(result).toContain('<pre class="artifact-code">');
      expect(result).toContain("const x = 1;");
      expect(result).toContain("</pre>");
    });

    it("converts inline code to code", () => {
      expect(formatMarkdown("Use `foo()` here")).toContain(
        "<code>foo()</code>",
      );
    });

    it("converts list items", () => {
      const result = formatMarkdown("- item one\n- item two");
      expect(result).toContain("<li>item one</li>");
      expect(result).toContain("<li>item two</li>");
    });

    it("converts newlines to br", () => {
      expect(formatMarkdown("line1\nline2")).toContain("line1<br>line2");
    });

    it("escapes HTML in content", () => {
      const result = formatMarkdown("<script>alert(1)</script>");
      expect(result).toContain("&lt;script&gt;");
      expect(result).not.toContain("<script>");
    });
  });
});
