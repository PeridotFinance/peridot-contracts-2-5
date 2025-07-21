export interface RateLimit {
  userId: number;
  action: string;
  count: number;
  windowStart: number;
  lastAttempt: number;
}

export interface RateLimitConfig {
  windowMs: number; // Time window in milliseconds
  maxAttempts: number; // Max attempts per window
  cooldownMs?: number; // Additional cooldown after limit hit
}

export class RateLimiterService {
  private attempts: Map<string, RateLimit> = new Map();

  // Default rate limit configurations
  private readonly configs: Record<string, RateLimitConfig> = {
    // Write operations - more restrictive
    supply: { windowMs: 60000, maxAttempts: 3, cooldownMs: 30000 }, // 3 per minute, 30s cooldown
    borrow: { windowMs: 60000, maxAttempts: 3, cooldownMs: 30000 },
    repay: { windowMs: 60000, maxAttempts: 5, cooldownMs: 15000 }, // Repay is less risky
    redeem: { windowMs: 60000, maxAttempts: 5, cooldownMs: 15000 },
    claim: { windowMs: 300000, maxAttempts: 2, cooldownMs: 60000 }, // 2 per 5 minutes
    approve: { windowMs: 180000, maxAttempts: 3, cooldownMs: 30000 }, // 3 per 3 minutes

    // Export operations - very restrictive
    export_private_key: {
      windowMs: 300000,
      maxAttempts: 2,
      cooldownMs: 120000,
    }, // 2 per 5 minutes
    export_mnemonic: { windowMs: 300000, maxAttempts: 2, cooldownMs: 120000 },

    // General commands - more lenient
    position: { windowMs: 60000, maxAttempts: 10 },
    markets: { windowMs: 60000, maxAttempts: 15 },
    balance: { windowMs: 60000, maxAttempts: 10 },
  };

  /**
   * Check if user can perform action
   */
  canPerformAction(
    userId: number,
    action: string
  ): {
    allowed: boolean;
    remainingAttempts?: number;
    resetTime?: number;
    cooldownUntil?: number;
    message?: string;
  } {
    const config = this.configs[action];
    if (!config) {
      // No rate limit configured for this action
      return { allowed: true };
    }

    const key = `${userId}:${action}`;
    const now = Date.now();
    const limit = this.attempts.get(key);

    if (!limit) {
      // First attempt for this user/action
      return {
        allowed: true,
        remainingAttempts: config.maxAttempts - 1,
        resetTime: now + config.windowMs,
      };
    }

    // Check if we're in cooldown period
    if (config.cooldownMs && limit.lastAttempt + config.cooldownMs > now) {
      const cooldownUntil = limit.lastAttempt + config.cooldownMs;
      const remainingCooldown = Math.ceil((cooldownUntil - now) / 1000);

      return {
        allowed: false,
        cooldownUntil,
        message: `Action blocked. Cooldown active for ${remainingCooldown} more seconds.`,
      };
    }

    // Check if window has expired
    if (now - limit.windowStart > config.windowMs) {
      // Reset window
      return {
        allowed: true,
        remainingAttempts: config.maxAttempts - 1,
        resetTime: now + config.windowMs,
      };
    }

    // Check if limit exceeded
    if (limit.count >= config.maxAttempts) {
      const resetTime = limit.windowStart + config.windowMs;
      const remainingWindow = Math.ceil((resetTime - now) / 1000);

      return {
        allowed: false,
        resetTime,
        message: `Rate limit exceeded. Try again in ${remainingWindow} seconds.`,
      };
    }

    // Within limits
    const remainingAttempts = config.maxAttempts - limit.count - 1;
    return {
      allowed: true,
      remainingAttempts,
      resetTime: limit.windowStart + config.windowMs,
    };
  }

  /**
   * Record an attempt (should be called after canPerformAction returns true)
   */
  recordAttempt(userId: number, action: string): void {
    const config = this.configs[action];
    if (!config) return;

    const key = `${userId}:${action}`;
    const now = Date.now();
    const existing = this.attempts.get(key);

    if (!existing || now - existing.windowStart > config.windowMs) {
      // New window
      this.attempts.set(key, {
        userId,
        action,
        count: 1,
        windowStart: now,
        lastAttempt: now,
      });
    } else {
      // Increment existing window
      existing.count++;
      existing.lastAttempt = now;
    }
  }

  /**
   * Get rate limit status for a user/action
   */
  getStatus(
    userId: number,
    action: string
  ): {
    hasLimit: boolean;
    currentCount?: number;
    maxAttempts?: number;
    windowStart?: number;
    windowEnd?: number;
    lastAttempt?: number;
  } {
    const config = this.configs[action];
    if (!config) {
      return { hasLimit: false };
    }

    const key = `${userId}:${action}`;
    const limit = this.attempts.get(key);

    if (!limit) {
      return {
        hasLimit: true,
        currentCount: 0,
        maxAttempts: config.maxAttempts,
      };
    }

    return {
      hasLimit: true,
      currentCount: limit.count,
      maxAttempts: config.maxAttempts,
      windowStart: limit.windowStart,
      windowEnd: limit.windowStart + config.windowMs,
      lastAttempt: limit.lastAttempt,
    };
  }

  /**
   * Reset rate limits for a user (admin function)
   */
  resetUserLimits(userId: number): void {
    const toDelete: string[] = [];

    for (const [key, limit] of this.attempts.entries()) {
      if (limit.userId === userId) {
        toDelete.push(key);
      }
    }

    toDelete.forEach((key) => this.attempts.delete(key));
  }

  /**
   * Clean up expired entries
   */
  cleanup(): void {
    const now = Date.now();
    const toDelete: string[] = [];

    for (const [key, limit] of this.attempts.entries()) {
      const config = this.configs[limit.action];
      if (!config) continue;

      // Remove if window expired and no cooldown, or cooldown also expired
      const windowExpired = now - limit.windowStart > config.windowMs;
      const cooldownExpired =
        !config.cooldownMs || now - limit.lastAttempt > config.cooldownMs;

      if (windowExpired && cooldownExpired) {
        toDelete.push(key);
      }
    }

    toDelete.forEach((key) => this.attempts.delete(key));
  }

  /**
   * Get statistics
   */
  getStats(): {
    totalEntries: number;
    activeUsers: number;
    topActions: Array<{ action: string; count: number }>;
  } {
    const actionCounts: Record<string, number> = {};
    const uniqueUsers = new Set<number>();

    for (const limit of this.attempts.values()) {
      uniqueUsers.add(limit.userId);
      actionCounts[limit.action] =
        (actionCounts[limit.action] || 0) + limit.count;
    }

    const topActions = Object.entries(actionCounts)
      .map(([action, count]) => ({ action, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 10);

    return {
      totalEntries: this.attempts.size,
      activeUsers: uniqueUsers.size,
      topActions,
    };
  }

  /**
   * Configure rate limits (admin function)
   */
  setRateLimit(action: string, config: RateLimitConfig): void {
    this.configs[action] = config;
  }
}
