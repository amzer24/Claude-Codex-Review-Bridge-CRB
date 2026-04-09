// Rate limiter — allows N requests per sliding window
function createRateLimiter(maxRequests, windowMs) {
  const clients = new Map();
  let cleanupInterval = null;

  function checkRate(clientId) {
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
  }

  function startCleanup(intervalMs) {
    stopCleanup();
    cleanupInterval = setInterval(() => {
      const now = Date.now();
      for (const [key, record] of clients) {
        if (now - record.start > windowMs) {
          clients.delete(key);
        }
      }
    }, intervalMs);
  }

  function stopCleanup() {
    if (cleanupInterval !== null) {
      clearInterval(cleanupInterval);
      cleanupInterval = null;
    }
  }

  return { checkRate, startCleanup, stopCleanup };
}

module.exports = { createRateLimiter };
