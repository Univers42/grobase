import { SanitizeMiddleware } from './sanitize.middleware';

describe('SanitizeMiddleware', () => {
  let middleware: SanitizeMiddleware;
  let mockReq: any;
  let mockRes: any;
  let mockNext: jest.Mock;

  beforeEach(() => {
    middleware = new SanitizeMiddleware();
    mockRes = {};
    mockNext = jest.fn();
  });

  describe('NoSQL injection prevention', () => {
    it('should strip MongoDB $gt operator from body', () => {
      mockReq = {
        body: { email: 'test@example.com', password: { $gt: '' } },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.password).toEqual({});
      expect(mockNext).toHaveBeenCalled();
    });

    it('should strip $ne operator from body', () => {
      mockReq = {
        body: { role: { $ne: 'user' } },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.role).toEqual({});
    });

    it('should strip $regex operator', () => {
      mockReq = {
        body: { name: { $regex: '.*admin.*' } },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.name).toEqual({});
    });

    it('should strip $in operator with array', () => {
      mockReq = {
        body: { status: { $in: ['admin', 'superadmin'] } },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.status).toEqual({});
    });
  });

  describe('XSS prevention', () => {
    it('should strip HTML script tags from strings', () => {
      mockReq = {
        body: { name: '<script>alert("xss")</script>Hello' },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.name).not.toContain('<script>');
      expect(mockReq.body.name).toContain('Hello');
    });

    it('should escape HTML entities in strings', () => {
      mockReq = {
        body: { bio: 'I like <b>bold</b> text & "quotes"' },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.bio).not.toContain('<b>');
      expect(mockReq.body.bio).toContain('&amp;');
    });
  });

  describe('Prototype pollution prevention', () => {
    it('should strip __proto__ key', () => {
      mockReq = {
        body: { __proto__: { isAdmin: true }, name: 'test' },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.__proto__).toBeUndefined();
      expect(mockReq.body.name).toBeDefined();
    });

    it('should strip constructor key', () => {
      mockReq = {
        body: { constructor: { prototype: { isAdmin: true } } },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      // constructor should be stripped
      expect(mockReq.body.constructor).toBeUndefined();
    });
  });

  describe('Query sanitization', () => {
    it('should sanitize query parameters', () => {
      mockReq = {
        body: {},
        query: { search: '<img onerror="alert(1)">', limit: '10' },
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.query.search).not.toContain('<img');
    });
  });

  describe('Non-destructive for valid data', () => {
    it('should not modify valid string values', () => {
      mockReq = {
        body: { name: 'John Doe', age: 25 },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.name).toBe('John Doe');
      expect(mockReq.body.age).toBe(25);
    });

    it('should preserve arrays with valid data', () => {
      mockReq = {
        body: { tags: ['music', 'rock', 'jazz'] },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.tags).toEqual(['music', 'rock', 'jazz']);
    });

    it('should handle null and undefined gracefully', () => {
      mockReq = {
        body: { field: null, other: undefined },
        query: {},
      };

      middleware.use(mockReq, mockRes, mockNext);

      expect(mockReq.body.field).toBeNull();
      expect(mockNext).toHaveBeenCalled();
    });
  });
});
