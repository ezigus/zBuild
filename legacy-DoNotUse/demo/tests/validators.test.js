const { validateUser } = require('../src/validators');

describe('validateUser', () => {
  it('should accept valid user data', () => {
    const { error, value } = validateUser({
      name: 'Jane Doe',
      email: 'jane@example.com'
    });
    expect(error).toBeUndefined();
    expect(value.name).toBe('Jane Doe');
    expect(value.email).toBe('jane@example.com');
  });

  it('should reject missing name', () => {
    const { error } = validateUser({ email: 'test@example.com' });
    expect(error).toBeDefined();
    expect(error.details[0].path).toContain('name');
  });

  it('should reject missing email', () => {
    const { error } = validateUser({ name: 'Test User' });
    expect(error).toBeDefined();
    expect(error.details[0].path).toContain('email');
  });

  it('should reject name shorter than 2 characters', () => {
    const { error } = validateUser({ name: 'A', email: 'a@example.com' });
    expect(error).toBeDefined();
    expect(error.details[0].message).toMatch(/at least 2/);
  });

  it('should reject invalid email format', () => {
    const { error } = validateUser({ name: 'Test User', email: 'not-valid' });
    expect(error).toBeDefined();
    expect(error.details[0].path).toContain('email');
  });

  it('should reject empty object', () => {
    const { error } = validateUser({});
    expect(error).toBeDefined();
    expect(error.details.length).toBeGreaterThanOrEqual(2);
  });

  it('should reject unknown fields', () => {
    const { error } = validateUser({
      name: 'Test User',
      email: 'test@example.com',
      role: 'admin'
    });
    expect(error).toBeDefined();
    expect(error.details[0].message).toMatch(/not allowed/);
  });
});
