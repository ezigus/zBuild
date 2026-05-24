import { describe, it, expect } from "vitest";
import { renderPipelineSVG, renderDoraGrades } from "./pipeline-rail";
import type { PipelineInfo } from "../../types/api";

describe("renderPipelineSVG", () => {
  it("renders SVG for an empty pipeline", () => {
    const pipeline = { status: "pending" } as PipelineInfo;
    const svg = renderPipelineSVG(pipeline);
    expect(svg).toContain("<svg");
    expect(svg).toContain("</svg>");
    expect(svg).toContain("pipeline-svg");
  });

  it("renders completed stages with green fill", () => {
    const pipeline = {
      stagesDone: ["intake", "plan"],
      stage: "build",
      status: "running",
    } as PipelineInfo;
    const svg = renderPipelineSVG(pipeline);
    expect(svg).toContain("#4ade80"); // green for completed
    expect(svg).toContain("#00d4ff"); // cyan for active
  });

  it("renders failed pipeline with red fill", () => {
    const pipeline = {
      stagesDone: ["intake", "plan"],
      stage: "build",
      status: "failed",
    } as PipelineInfo;
    const svg = renderPipelineSVG(pipeline);
    expect(svg).toContain("#f43f5e"); // red for failed
  });

  it("renders stage labels", () => {
    const pipeline = {
      stagesDone: [],
      stage: "intake",
      status: "running",
    } as PipelineInfo;
    const svg = renderPipelineSVG(pipeline);
    expect(svg).toContain("intake");
  });

  it("renders connecting lines between stages", () => {
    const pipeline = { status: "pending" } as PipelineInfo;
    const svg = renderPipelineSVG(pipeline);
    expect(svg).toContain("<line");
  });

  it("renders animation for active stage", () => {
    const pipeline = {
      stagesDone: [],
      stage: "intake",
      status: "running",
    } as PipelineInfo;
    const svg = renderPipelineSVG(pipeline);
    expect(svg).toContain("animate");
    expect(svg).toContain("stage-node-active");
  });

  it("uses dashed lines for incomplete connections", () => {
    const pipeline = {
      stagesDone: [],
      stage: "intake",
      status: "running",
    } as PipelineInfo;
    const svg = renderPipelineSVG(pipeline);
    expect(svg).toContain("stroke-dasharray");
  });
});

describe("renderDoraGrades", () => {
  it("returns empty string for null dora", () => {
    expect(renderDoraGrades(null)).toBe("");
  });

  it("returns empty string for undefined dora", () => {
    expect(renderDoraGrades(undefined)).toBe("");
  });

  it("renders DORA metrics cards", () => {
    const dora = {
      deploy_freq: { grade: "Elite", value: 7.5, unit: "/week" },
      lead_time: { grade: "High", value: 2.1, unit: "hours" },
      cfr: { grade: "Medium", value: 15.0, unit: "%" },
      mttr: { grade: "Low", value: 24.0, unit: "hours" },
    };
    const html = renderDoraGrades(dora);
    expect(html).toContain("dora-grades-row");
    expect(html).toContain("Deploy Frequency");
    expect(html).toContain("Lead Time");
    expect(html).toContain("Change Failure Rate");
    expect(html).toContain("Mean Time to Recovery");
    expect(html).toContain("Elite");
    expect(html).toContain("dora-elite");
    expect(html).toContain("7.5");
    expect(html).toContain("/week");
  });

  it("handles missing metrics gracefully", () => {
    const dora = {
      deploy_freq: { grade: "Elite", value: 5.0, unit: "/week" },
    };
    const html = renderDoraGrades(dora);
    expect(html).toContain("Deploy Frequency");
    expect(html).not.toContain("Lead Time");
  });

  it("handles null value with dash", () => {
    const dora = {
      cfr: { grade: "N/A", value: null as unknown as number, unit: "%" },
    };
    const html = renderDoraGrades(dora);
    expect(html).toContain("\u2014");
  });
});
