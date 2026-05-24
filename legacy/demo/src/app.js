const express = require('express');
const { authMiddleware } = require('./middleware');
const { validateUser } = require('./validators');

const app = express();
app.use(express.json());

// In-memory user store
const users = [
  { id: 1, name: 'Alice Johnson', email: 'alice@example.com' },
  { id: 2, name: 'Bob Smith', email: 'bob@example.com' }
];
let nextId = 3;

// Health check — no auth required
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// List users — requires auth
app.get('/users', authMiddleware, (req, res) => {
  res.json({ users, count: users.length });
});

// Get single user — requires auth
app.get('/users/:id', authMiddleware, (req, res) => {
  const user = users.find(u => u.id === parseInt(req.params.id, 10));
  if (!user) {
    return res.status(404).json({ error: 'User not found' });
  }
  res.json(user);
});

// Create user — requires auth + validation
app.post('/users', authMiddleware, (req, res) => {
  const { error, value } = validateUser(req.body);
  if (error) {
    return res.status(400).json({
      error: 'Validation failed',
      details: error.details.map(d => d.message)
    });
  }

  const newUser = { id: nextId++, ...value };
  users.push(newUser);
  res.status(201).json(newUser);
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Error handler
app.use((err, req, res, next) => {
  console.error(err.stack);
  res.status(500).json({ error: 'Internal server error' });
});

// Start server only when run directly
if (require.main === module) {
  const PORT = process.env.PORT || 3000;
  app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
  });
}

module.exports = app;
