import type { RateLimitConfig } from '../translation/types';

/**
 * Token-bucket rate limiter that serializes concurrent acquire() calls
 * to prevent over-consumption of tokens.
 *
 * Implements Requirements 5.1–5.6.
 */
export class TokenBucketRateLimiter {
	private tokens: number;
	private readonly capacity: number;
	private readonly refillRate: number; // tokens per millisecond
	private lastRefill: number;
	private queue: Array<() => void>; // serialization queue for concurrent acquire() calls

	constructor(config: RateLimitConfig) {
		this.capacity = config.requestsPerMinute;
		this.refillRate = config.requestsPerMinute / 60_000;
		this.tokens = this.capacity;
		this.lastRefill = Date.now();
		this.queue = [];
	}

	async acquire(): Promise<void> {
		// Serialize concurrent calls using a promise-chain mutex.
		// Each acquire() appends itself to the queue and waits for the
		// previous call to complete before proceeding.
		return new Promise<void>((resolve) => {
			const run = async () => {
				// 1. Refill tokens based on elapsed time since lastRefill
				const now = Date.now();
				const elapsed = now - this.lastRefill;
				this.tokens = Math.min(this.capacity, this.tokens + elapsed * this.refillRate);
				this.lastRefill = now;

				// 2. If tokens >= 1: consume one token and return immediately
				if (this.tokens >= 1) {
					this.tokens -= 1;
					resolve();
					this.dequeue();
					return;
				}

				// 3. If tokens < 1: calculate wait time and sleep
				const waitMs = (1 - this.tokens) / this.refillRate;
				await sleep(waitMs);

				// After waiting, consume the token
				this.tokens = 0;
				this.lastRefill = Date.now();
				resolve();
				this.dequeue();
			};

			this.queue.push(run);

			// If this is the only item in the queue, start immediately
			if (this.queue.length === 1) {
				run();
			}
		});
	}

	/** Removes the completed head of the queue and starts the next waiter. */
	private dequeue(): void {
		this.queue.shift();
		if (this.queue.length > 0) {
			this.queue[0]();
		}
	}

	// Expose for testing
	getTokens(): number {
		return this.tokens;
	}
	getCapacity(): number {
		return this.capacity;
	}
}

/** Resolves after `ms` milliseconds. */
function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Factory function for creating a TokenBucketRateLimiter.
 */
export function createRateLimiter(config: RateLimitConfig): TokenBucketRateLimiter {
	return new TokenBucketRateLimiter(config);
}
