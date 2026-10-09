import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";

// We need to mock the DOM and store before importing the router
describe("Router", () => {
  let store: any;
  let router: typeof import("./router");

  beforeEach(async () => {
    // Reset DOM
    document.body.innerHTML = `
      <div class="tab-btn" data-tab="overview">Overview</div>
      <div class="tab-btn" data-tab="pipelines">Pipelines</div>
      <div class="tab-btn" data-tab="metrics">Metrics</div>
      <div class="tab-btn" data-tab="team">Team</div>
      <div class="tab-panel" id="panel-overview"></div>
      <div class="tab-panel" id="panel-pipelines"></div>
      <div class="tab-panel" id="panel-metrics"></div>
      <div class="tab-panel" id="panel-team"></div>
    `;

    // Reset hash
    location.hash = "";

    // Fresh imports
    vi.resetModules();
    store = (await import("./state")).store;
    router = await import("./router");
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("registerView", () => {
    it("registers a view for a tab", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("overview", mockView);

      const views = router.getRegisteredViews();
      expect(views.get("overview")).toBe(mockView);
    });
  });

  describe("switchTab", () => {
    it("updates the active tab in the store", () => {
      store.set("activeTab", "overview");
      router.switchTab("pipelines");
      expect(store.get("activeTab")).toBe("pipelines");
    });

    it("updates the location hash", () => {
      store.set("activeTab", "overview");
      router.switchTab("pipelines");
      expect(location.hash).toBe("#pipelines");
    });

    it("adds active class to the correct tab button", () => {
      store.set("activeTab", "overview");
      router.switchTab("pipelines");

      const btns = document.querySelectorAll(".tab-btn");
      const pipelinesBtn = Array.from(btns).find(
        (b) => b.getAttribute("data-tab") === "pipelines",
      );
      const overviewBtn = Array.from(btns).find(
        (b) => b.getAttribute("data-tab") === "overview",
      );

      expect(pipelinesBtn?.classList.contains("active")).toBe(true);
      expect(overviewBtn?.classList.contains("active")).toBe(false);
    });

    it("adds active class to the correct panel", () => {
      store.set("activeTab", "overview");
      router.switchTab("pipelines");

      const pipelinesPanel = document.getElementById("panel-pipelines");
      const overviewPanel = document.getElementById("panel-overview");

      expect(pipelinesPanel?.classList.contains("active")).toBe(true);
      expect(overviewPanel?.classList.contains("active")).toBe(false);
    });

    it("does nothing when switching to the current tab", () => {
      store.set("activeTab", "overview");
      const prevHash = location.hash;
      router.switchTab("overview");
      // Should not change anything
      expect(store.get("activeTab")).toBe("overview");
    });

    it("initializes the view on first switch", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", mockView);

      store.set("activeTab", "overview");
      router.switchTab("metrics");

      expect(mockView.init).toHaveBeenCalledTimes(1);
    });

    it("destroys the previous view on tab switch", () => {
      const overviewView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      const metricsView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };

      router.registerView("overview", overviewView);
      router.registerView("metrics", metricsView);

      // First, switch to overview so it gets initialized
      store.set("activeTab", "pipelines");
      router.switchTab("overview");
      expect(overviewView.init).toHaveBeenCalledTimes(1);

      // Now switch to metrics
      router.switchTab("metrics");
      expect(overviewView.destroy).toHaveBeenCalledTimes(1);
      expect(metricsView.init).toHaveBeenCalledTimes(1);
    });

    it("renders with fleet state if available", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", mockView);

      const fakeState = { pipelines: [], machines: [] };
      store.set("fleetState", fakeState);
      store.set("activeTab", "overview");

      router.switchTab("metrics");
      expect(mockView.render).toHaveBeenCalledWith(fakeState);
    });

    it("clears team refresh timer when leaving team tab", () => {
      const timer = setInterval(() => {}, 999999);
      router.__setTeamRefreshTimerForTest(timer);

      const clearSpy = vi.spyOn(global, "clearInterval");

      store.set("activeTab", "team");
      router.switchTab("overview");

      expect(clearSpy).toHaveBeenCalledWith(timer);

      router.__setTeamRefreshTimerForTest(null);
      clearSpy.mockRestore();
    });
  });

  describe("error boundaries", () => {
    it("shows string errors when non-Error is thrown", () => {
      const errorView = {
        init: vi.fn(() => {
          throw "string error";
        }),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("activeTab", "overview");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const errorBoundary = panel?.querySelector(".tab-error-boundary");
      expect(errorBoundary).toBeTruthy();
      expect(errorBoundary?.textContent).toContain("string error");

      consoleSpy.mockRestore();
    });

    it("catches init errors and shows error boundary", () => {
      const errorView = {
        init: vi.fn(() => {
          throw new Error("Init failed!");
        }),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      // Suppress console.error for this test
      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("activeTab", "overview");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const errorBoundary = panel?.querySelector(".tab-error-boundary");
      expect(errorBoundary).toBeTruthy();
      expect(errorBoundary?.textContent).toContain("Init failed!");

      consoleSpy.mockRestore();
    });

    it("catches render errors and shows error boundary", () => {
      const errorView = {
        init: vi.fn(),
        render: vi.fn(() => {
          throw new Error("Render exploded!");
        }),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("fleetState", { pipelines: [] });
      store.set("activeTab", "overview");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const errorBoundary = panel?.querySelector(".tab-error-boundary");
      expect(errorBoundary).toBeTruthy();
      expect(errorBoundary?.textContent).toContain("Render exploded!");

      consoleSpy.mockRestore();
    });

    it("does not stack multiple error boundaries", () => {
      const errorView = {
        init: vi.fn(() => {
          throw new Error("Fail");
        }),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("activeTab", "overview");
      router.switchTab("metrics");

      // Try to trigger again (should not add second boundary)
      store.set("activeTab", "pipelines");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const boundaries = panel?.querySelectorAll(".tab-error-boundary");
      expect(boundaries?.length).toBeLessThanOrEqual(1);

      consoleSpy.mockRestore();
    });
  });

  describe("renderActiveView", () => {
    it("renders the current active view with fleet state", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("overview", mockView);

      const fakeState = { pipelines: [] };
      store.set("fleetState", fakeState);
      store.set("activeTab", "overview");

      router.renderActiveView();

      expect(mockView.render).toHaveBeenCalledWith(fakeState);
    });

    it("does nothing when no fleet state is available", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("overview", mockView);
      store.set("activeTab", "overview");

      router.renderActiveView();
      expect(mockView.render).not.toHaveBeenCalled();
    });

    it("does nothing when no view is registered for active tab", () => {
      store.set("activeTab", "agents");
      store.set("fleetState", { pipelines: [] });

      expect(() => router.renderActiveView()).not.toThrow();
    });

    it("catches render errors and shows error boundary", () => {
      const errorView = {
        init: vi.fn(),
        render: vi.fn(() => {
          throw new Error("renderActiveView render failed!");
        }),
        destroy: vi.fn(),
      };
      router.registerView("overview", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("fleetState", { pipelines: [] });
      store.set("activeTab", "overview");

      router.renderActiveView();

      const panel = document.getElementById("panel-overview");
      const errorBoundary = panel?.querySelector(".tab-error-boundary");
      expect(errorBoundary).toBeTruthy();
      expect(errorBoundary?.textContent).toContain(
        "renderActiveView render failed!",
      );

      consoleSpy.mockRestore();
    });
  });

  describe("error boundary retry", () => {
    it("retry button reinitalizes view and re-renders on success", () => {
      let initCalled = 0;
      const errorView = {
        init: vi.fn(() => {
          initCalled++;
          if (initCalled === 1) throw new Error("First init failed");
        }),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("fleetState", { pipelines: [] });
      store.set("activeTab", "overview");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const retryBtn = panel?.querySelector(".error-boundary-retry");
      expect(retryBtn).toBeTruthy();

      retryBtn?.dispatchEvent(new Event("click", { bubbles: true }));

      expect(errorView.init).toHaveBeenCalledTimes(2);
      expect(errorView.render).toHaveBeenCalledWith({ pipelines: [] });
      expect(panel?.querySelector(".tab-error-boundary")).toBeFalsy();

      consoleSpy.mockRestore();
    });

    it("retry button does not call render when fleetState is null", () => {
      const errorView = {
        init: vi.fn(),
        render: vi.fn(() => {
          throw new Error("Render failed");
        }),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("fleetState", { pipelines: [] });
      store.set("activeTab", "overview");
      router.switchTab("metrics");
      expect(errorView.render).toHaveBeenCalledTimes(1);

      store.set("fleetState", null);

      const panel = document.getElementById("panel-metrics");
      const retryBtn = panel?.querySelector(".error-boundary-retry");
      retryBtn?.dispatchEvent(new Event("click", { bubbles: true }));

      expect(errorView.init).toHaveBeenCalledTimes(2);
      expect(errorView.render).toHaveBeenCalledTimes(1);

      consoleSpy.mockRestore();
    });

    it("retry button shows error boundary again when retry fails", () => {
      const errorView = {
        init: vi.fn(() => {
          throw new Error("Retry failed!");
        }),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("metrics", errorView);

      const consoleSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      store.set("fleetState", { pipelines: [] });
      store.set("activeTab", "overview");
      router.switchTab("metrics");

      const panel = document.getElementById("panel-metrics");
      const retryBtn = panel?.querySelector(".error-boundary-retry");
      retryBtn?.dispatchEvent(new Event("click", { bubbles: true }));

      const errorBoundary = panel?.querySelector(".tab-error-boundary");
      expect(errorBoundary).toBeTruthy();
      expect(errorBoundary?.textContent).toContain("Retry failed!");

      consoleSpy.mockRestore();
    });
  });

  describe("setupRouter", () => {
    beforeEach(async () => {
      vi.resetModules();
      store = (await import("./state")).store;
      router = await import("./router");
    });

    it("handles tab button clicks and switches tab", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("pipelines", mockView);

      router.setupRouter();

      const pipelinesBtn = document.querySelector(
        '[data-tab="pipelines"]',
      ) as HTMLElement;
      pipelinesBtn?.click();

      expect(store.get("activeTab")).toBe("pipelines");
    });

    it("does not switch when tab button has no data-tab", () => {
      document.body.innerHTML = `
        <div class="tab-btn">No Tab</div>
        <div class="tab-btn" data-tab="overview">Overview</div>
        <div class="tab-panel" id="panel-overview"></div>
      `;
      store.set("activeTab", "overview");
      router.registerView("overview", {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      });

      router.setupRouter();

      const noTabBtn = document.querySelector(".tab-btn");
      noTabBtn?.dispatchEvent(new Event("click", { bubbles: true }));

      expect(store.get("activeTab")).toBe("overview");
    });

    it("switches to tab from valid initial hash", () => {
      location.hash = "#team";

      router.registerView("team", {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      });
      router.setupRouter();

      expect(store.get("activeTab")).toBe("team");
      expect(location.hash).toBe("#team");
    });

    it("initializes current view when hash is invalid", () => {
      location.hash = "#invalid";
      store.set("activeTab", "overview");

      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("overview", mockView);

      router.setupRouter();

      expect(mockView.init).toHaveBeenCalledTimes(1);
    });

    it("responds to hashchange events", () => {
      router.registerView("overview", {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      });
      router.registerView("metrics", {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      });

      router.setupRouter();

      store.set("activeTab", "overview");
      location.hash = "#metrics";

      window.dispatchEvent(new HashChangeEvent("hashchange"));

      expect(store.get("activeTab")).toBe("metrics");
    });

    it("does not switch on hashchange when hash matches current tab", () => {
      router.registerView("metrics", {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      });

      router.setupRouter();

      store.set("activeTab", "metrics");
      location.hash = "#metrics";

      const switchSpy = vi.spyOn(router, "switchTab");
      window.dispatchEvent(new HashChangeEvent("hashchange"));

      expect(switchSpy).not.toHaveBeenCalled();
    });

    it("re-renders active view when fleetState changes", () => {
      const mockView = {
        init: vi.fn(),
        render: vi.fn(),
        destroy: vi.fn(),
      };
      router.registerView("overview", mockView);

      store.set("activeTab", "overview");
      router.setupRouter();

      store.set("fleetState", { pipelines: [], machines: [] });

      expect(mockView.render).toHaveBeenCalledWith({
        pipelines: [],
        machines: [],
      });
    });
  });
});
