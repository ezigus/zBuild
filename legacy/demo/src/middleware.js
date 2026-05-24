/**
 * Authentication middleware.
 *
 * Expects an "Authorization" header with value "Bearer <token>".
 * Any non-empty bearer token is accepted for this demo.
 *
 * Returns 401 Unauthorized per RFC 7235 when credentials are missing or malformed.
 */
function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;

  if (!authHeader) {
    res.set("WWW-Authenticate", "Bearer");
    return res.status(401).json({ error: "Authorization header required" });
  }

  const parts = authHeader.split(" ");
  if (parts.length !== 2 || parts[0] !== "Bearer") {
    res.set("WWW-Authenticate", "Bearer");
    return res
      .status(401)
      .json({ error: "Invalid authorization format. Use: Bearer <token>" });
  }

  const token = parts[1];
  if (!token || token.trim() === "") {
    res.set("WWW-Authenticate", 'Bearer error="invalid_token"');
    return res.status(401).json({ error: "Token required" });
  }

  // In a real app, we'd verify the token here
  req.userId = "demo-user";
  next();
}

module.exports = { authMiddleware };
