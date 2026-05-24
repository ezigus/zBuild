import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { SSEClient } from "./sse";

const EventSourceOpen = 1;
const EventSourceClosed = 2;

describe("SSEClient", () => {
  let mockEventSource: {
    close: ReturnType<typeof vi.fn>;
    readyState: number;
    onmessage: ((e: { data: string }) => void) | null;
    onerror: (() => void) | null;
  };
  let EventSourceConstructor: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockEventSource = {
      close: vi.fn(),
      readyState: EventSourceClosed,
      onmessage: null,
      onerror: null,
    };
    EventSourceConstructor = vi.fn(function (this: unknown) {
      return mockEventSource;
    }) as ReturnType<typeof vi.fn> & { OPEN: number };
    EventSourceConstructor.OPEN = EventSourceOpen;
    EventSourceConstructor.CLOSED = EventSourceClosed;
    EventSourceConstructor.CONNECTING = 0;
    vi.stubGlobal("EventSource", EventSourceConstructor);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  describe("constructor", () => {
    it("stores url and callbacks", () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const client = new SSEClient(
        "https://example.com/events",
        onMessage,
        onError,
      );
      expect(client).toBeDefined();
      // Verify connect uses stored values
      client.connect();
      expect(EventSourceConstructor).toHaveBeenCalledWith(
        "https://example.com/events",
      );
    });
  });

  describe("connect", () => {
    it("creates EventSource with url", () => {
      const client = new SSEClient("/api/logs/42/stream", vi.fn());
      client.connect();
      expect(EventSourceConstructor).toHaveBeenCalledWith(
        "/api/logs/42/stream",
      );
    });

    it("closes existing connection before reconnecting", () => {
      const client = new SSEClient("/api/stream", vi.fn());
      client.connect();
      const firstES = EventSourceConstructor.mock.results[0].value;
      client.connect();
      expect(firstES.close).toHaveBeenCalled();
    });

    it("registers onmessage handler that forwards to callback", () => {
      const onMessage = vi.fn();
      const client = new SSEClient("/api/stream", onMessage);
      client.connect();

      expect(mockEventSource.onmessage).toBeDefined();
      mockEventSource.onmessage!({ data: "hello world" });
      expect(onMessage).toHaveBeenCalledWith("hello world");
    });

    it("registers onerror handler when onError provided", () => {
      const onError = vi.fn();
      const client = new SSEClient("/api/stream", vi.fn(), onError);
      client.connect();

      expect(mockEventSource.onerror).toBeDefined();
      mockEventSource.onerror!();
      expect(onError).toHaveBeenCalled();
    });
  });

  describe("close", () => {
    it("closes EventSource and sets to null", () => {
      const client = new SSEClient("/api/stream", vi.fn());
      client.connect();
      client.close();
      expect(mockEventSource.close).toHaveBeenCalled();
      // eventSource is private, but isConnected should reflect closed state
      mockEventSource.readyState = EventSourceClosed;
      expect(client.isConnected()).toBe(false);
    });

    it("is safe to call when not connected", () => {
      const client = new SSEClient("/api/stream", vi.fn());
      expect(() => client.close()).not.toThrow();
    });
  });

  describe("isConnected", () => {
    it("returns false when not connected", () => {
      const client = new SSEClient("/api/stream", vi.fn());
      expect(client.isConnected()).toBe(false);
    });

    it("returns false when EventSource is closed", () => {
      const client = new SSEClient("/api/stream", vi.fn());
      client.connect();
      mockEventSource.readyState = EventSourceClosed;
      expect(client.isConnected()).toBe(false);
    });

    it("returns true when EventSource is OPEN", () => {
      const client = new SSEClient("/api/stream", vi.fn());
      client.connect();
      mockEventSource.readyState = EventSourceOpen;
      expect(client.isConnected()).toBe(true);
    });
  });

  describe("message handling", () => {
    it("receives multiple messages", () => {
      const onMessage = vi.fn();
      const client = new SSEClient("/api/stream", onMessage);
      client.connect();

      mockEventSource.onmessage!({ data: "msg1" });
      mockEventSource.onmessage!({ data: "msg2" });

      expect(onMessage).toHaveBeenCalledTimes(2);
      expect(onMessage).toHaveBeenNthCalledWith(1, "msg1");
      expect(onMessage).toHaveBeenNthCalledWith(2, "msg2");
    });
  });
});
