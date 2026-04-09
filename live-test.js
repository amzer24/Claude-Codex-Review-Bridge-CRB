// Rate limiter - allows N requests per window
function createRateLimiter(maxRequests, windowMs) {
  const clients = new Map();

  return function checkRate(clientId) {
    const now = Date.now();
    let record = clients.get(clientId);

    if (!record || now - record.start > windowMs) {
      record = { start: now, count: 1 };
      clients.set(clientId, record);
      return { allowed: true, remaining: maxRequests - 1 };
    }

    record.count++;
    if (record.count > maxRequests) {
      return { allowed: false, remaining: 0, retryAfter: record.start + windowMs - now };
    }

    return { allowed: true, remaining: maxRequests - record.count };
  };
}

module.exports = { createRateLimiter };
