const request = require("supertest");
const http = require("http");
const app = require("../src/app");

const AUTH_HEADER = { Authorization: "Bearer test-token-123" };

let server;

beforeAll((done) => {
  server = http.createServer(app).listen(0, done);
});

afterAll((done) => {
  server.closeAllConnections?.();
  server.close(done);
});

describe("GET /health", () => {
  it("should return 200 with status ok", async () => {
    const res = await request(server).get("/health");
    expect(res.status).toBe(200);
    expect(res.body.status).toBe("ok");
    expect(res.body.timestamp).toBeDefined();
  });
});

describe("GET /users", () => {
  it("should return 401 when no auth header is provided", async () => {
    const res = await request(server).get("/users");
    expect(res.status).toBe(401);
  });

  it("should return 401 for malformed auth header", async () => {
    const res = await request(server)
      .get("/users")
      .set("Authorization", "InvalidFormat");
    expect(res.status).toBe(401);
  });

  it("should return users when authenticated", async () => {
    const res = await request(server).get("/users").set(AUTH_HEADER);
    expect(res.status).toBe(200);
    expect(res.body.users).toBeInstanceOf(Array);
    expect(res.body.count).toBeGreaterThanOrEqual(2);
  });
});

describe("GET /users/:id", () => {
  it("should return a single user by id", async () => {
    const res = await request(server).get("/users/1").set(AUTH_HEADER);
    expect(res.status).toBe(200);
    expect(res.body.name).toBe("Alice Johnson");
    expect(res.body.email).toBe("alice@example.com");
  });

  it("should return 404 for non-existent user", async () => {
    const res = await request(server).get("/users/999").set(AUTH_HEADER);
    expect(res.status).toBe(404);
    expect(res.body.error).toBe("User not found");
  });
});

describe("POST /users", () => {
  it("should create a new user with valid data", async () => {
    const res = await request(server)
      .post("/users")
      .set(AUTH_HEADER)
      .send({ name: "Charlie Brown", email: "charlie@example.com" });
    expect(res.status).toBe(201);
    expect(res.body.name).toBe("Charlie Brown");
    expect(res.body.email).toBe("charlie@example.com");
    expect(res.body.id).toBeDefined();
  });

  it("should reject user with missing name", async () => {
    const res = await request(server)
      .post("/users")
      .set(AUTH_HEADER)
      .send({ email: "noname@example.com" });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe("Validation failed");
  });

  it("should reject user with invalid email", async () => {
    const res = await request(server)
      .post("/users")
      .set(AUTH_HEADER)
      .send({ name: "Bad Email", email: "not-an-email" });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe("Validation failed");
  });
});

describe("404 handler", () => {
  it("should return 404 for unknown routes", async () => {
    const res = await request(server).get("/nonexistent");
    expect(res.status).toBe(404);
    expect(res.body.error).toBe("Not found");
  });
});
