const Joi = require('joi');

/**
 * Validate user creation payload.
 *
 * Expects:
 *   - name: string, 2-100 chars, required
 *   - email: valid email, required
 */
const userSchema = Joi.object({
  name: Joi.string()
    .min(2)
    .max(100)
    .required()
    .messages({
      'string.min': 'Name must be at least 2 characters',
      'string.max': 'Name must be at most 100 characters',
      'any.required': 'Name is required'
    }),

  email: Joi.string()
    .email()
    .required()
    .messages({
      'string.email': 'Must be a valid email address',
      'any.required': 'Email is required'
    })
});

function validateUser(data) {
  return userSchema.validate(data, { abortEarly: false });
}

module.exports = { validateUser, userSchema };
