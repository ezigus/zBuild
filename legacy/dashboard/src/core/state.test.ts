import { describe, it, expect, beforeEach, vi } from "vitest";

// Re-create store for each test to avoid state leakage
function createStore() {
  // Reset module cache to get fresh store
  const mod = require("./state");
  return mod.store;
}

// Since the module exports a singleton, we'll test the Store class behavior
// by importing and using the exported store, resetting between tests
import { store } from "./state";
import type { AppState } from "./state";

describe("Store", () => {
  beforeEach(() => {
    // Reset to default state
    store.update({
      connected: false,
      connectedAt: null,
      fleetState: null,
      activeTab: "overview",
      selectedPipelineIssue: null,
      pipelineDetail: null,
      pipelineFilter: "all",
      activityFilter: "all",
      activityIssueFilter: "",
      activityEvents: [],
      activityOffset: 0,
      activityHasMore: false,
      metricsCache: null,
      insightsCache: null,
      machinesCache: null,
      joinTokensCache: null,
      costBreakdownCache: null,
      alertsCache: null,
      alertDismissed: false,
      teamCache: null,
      teamActivityCache: null,
      daemonConfig: null,
      currentUser: null,
      selectedIssues: {},
      firstRender: true,
    });
  });

  describe("get/set", () => {
    it("returns the initial value for a key", () => {
      expect(store.get("connected")).toBe(false);
      expect(store.get("activeTab")).toBe("overview");
      expect(store.get("firstRender")).toBe(true);
    });

    it("sets and retrieves a value", () => {
      store.set("connected", true);
      expect(store.get("connected")).toBe(true);
    });

    it("sets activeTab correctly", () => {
      store.set("activeTab", "pipelines");
      expect(store.get("activeTab")).toBe("pipelines");
    });

    it("handles null values", () => {
      store.set("fleetState", null);
      expect(store.get("fleetState")).toBeNull();
    });

    it("handles numeric values", () => {
      store.set("selectedPipelineIssue", 42);
      expect(store.get("selectedPipelineIssue")).toBe(42);
    });
  });

  describe("getState", () => {
    it("returns a snapshot of the full state", () => {
      const state = store.getState();
      expect(state.connected).toBe(false);
      expect(state.activeTab).toBe("overview");
      expect(state).toHaveProperty("fleetState");
    });
  });

  describe("update", () => {
    it("updates multiple keys at once", () => {
      store.update({
        connected: true,
        connectedAt: 1234567890,
        activeTab: "metrics",
      });
      expect(store.get("connected")).toBe(true);
      expect(store.get("connectedAt")).toBe(1234567890);
      expect(store.get("activeTab")).toBe("metrics");
    });

    it("does not trigger listeners when values haven't changed", () => {
      const listener = vi.fn();
      store.subscribe("connected", listener);
      store.update({ connected: false }); // already false
      expect(listener).not.toHaveBeenCalled();
    });

    it("triggers listeners for each changed key", () => {
      const connectedListener = vi.fn();
      const tabListener = vi.fn();
      store.subscribe("connected", connectedListener);
      store.subscribe("activeTab", tabListener);

      store.update({ connected: true, activeTab: "insights" });

      expect(connectedListener).toHaveBeenCalledWith(true, false);
      expect(tabListener).toHaveBeenCalledWith("insights", "overview");
    });
  });

  describe("subscribe", () => {
    it("calls listener when the subscribed key changes", () => {
      const listener = vi.fn();
      store.subscribe("connected", listener);
      store.set("connected", true);
      expect(listener).toHaveBeenCalledWith(true, false);
    });

    it("does not call listener for unchanged value (same reference)", () => {
      const listener = vi.fn();
      store.subscribe("connected", listener);
      store.set("connected", false); // already false
      expect(listener).not.toHaveBeenCalled();
    });

    it("returns an unsubscribe function", () => {
      const listener = vi.fn();
      const unsub = store.subscribe("connected", listener);

      store.set("connected", true);
      expect(listener).toHaveBeenCalledTimes(1);

      unsub();
      store.set("connected", false);
      expect(listener).toHaveBeenCalledTimes(1); // not called again
    });

    it("supports multiple listeners on the same key", () => {
      const listener1 = vi.fn();
      const listener2 = vi.fn();
      store.subscribe("activeTab", listener1);
      store.subscribe("activeTab", listener2);

      store.set("activeTab", "team");

      expect(listener1).toHaveBeenCalledWith("team", "overview");
      expect(listener2).toHaveBeenCalledWith("team", "overview");
    });

    it("supports listeners on different keys independently", () => {
      const connListener = vi.fn();
      const tabListener = vi.fn();
      store.subscribe("connected", connListener);
      store.subscribe("activeTab", tabListener);

      store.set("connected", true);
      expect(connListener).toHaveBeenCalledTimes(1);
      expect(tabListener).not.toHaveBeenCalled();
    });
  });

  describe("onAny", () => {
    it("fires on any state change", () => {
      const listener = vi.fn();
      store.onAny(listener);

      store.set("connected", true);
      expect(listener).toHaveBeenCalledTimes(1);

      store.set("activeTab", "metrics");
      expect(listener).toHaveBeenCalledTimes(2);
    });

    it("returns an unsubscribe function", () => {
      const listener = vi.fn();
      const unsub = store.onAny(listener);

      store.set("connected", true);
      expect(listener).toHaveBeenCalledTimes(1);

      unsub();
      store.set("activeTab", "metrics");
      expect(listener).toHaveBeenCalledTimes(1);
    });

    it("receives the full state object", () => {
      const listener = vi.fn();
      store.onAny(listener);
      store.set("connected", true);

      const receivedState = listener.mock.calls[0][0] as AppState;
      expect(receivedState.connected).toBe(true);
      expect(receivedState.activeTab).toBe("overview");
    });
  });

  describe("edge cases", () => {
    it("handles rapid updates without losing data", () => {
      for (let i = 0; i < 100; i++) {
        store.set("activityOffset", i);
      }
      expect(store.get("activityOffset")).toBe(99);
    });

    it("handles object values (reference equality check)", () => {
      const events = [{ type: "test" }];
      const listener = vi.fn();
      store.subscribe("activityEvents", listener);

      store.set("activityEvents", events);
      expect(listener).toHaveBeenCalledTimes(1);

      // Same reference, should not fire
      store.set("activityEvents", events);
      expect(listener).toHaveBeenCalledTimes(1);

      // New reference with same content, WILL fire (reference check)
      store.set("activityEvents", [...events]);
      expect(listener).toHaveBeenCalledTimes(2);
    });

    it("handles selectedIssues record updates", () => {
      store.set("selectedIssues", { "123": true, "456": true });
      expect(store.get("selectedIssues")).toEqual({
        "123": true,
        "456": true,
      });
    });
  });
});
