import type { RequestHandler } from './$types';
import type { EngineQuery, RawResult, RawResultItem, DispatchError } from '$lib/dispatch/types';
import { ENGINE_REGISTRY } from '$lib/translation/adapters/registry';
import { json } from '@sveltejs/kit';
import { chromium } from 'playwright';

export const POST: RequestHandler = async ({ request }) => {
	const query: EngineQuery = await request.json();

	const result = await executePlaywrightQuery(query);

	// Always return a valid RawResult JSON response — never throw unhandled
	return json(result);
};

async function executePlaywrightQuery(query: EngineQuery): Promise<RawResult> {
	// 1. Look up engine in ENGINE_REGISTRY to get baseUrl
	const entry = ENGINE_REGISTRY.find((e) => e.id === query.engineId);

	if (!entry) {
		return {
			engineId: query.engineId,
			items: [],
			error: {
				code: 'unknown',
				message: `Engine not found in registry: ${query.engineId}`
			}
		};
	}

	// 2. Build search URL for the engine
	const searchUrl = buildSearchUrl(entry.baseUrl, query.nativeQuery);

	let browser;
	try {
		// 3. Launch Playwright chromium browser (headless)
		browser = await chromium.launch({ headless: true });
		const page = await browser.newPage();

		// 4. Navigate to the search URL
		const timeoutMs = query.options?.timeout ?? 15_000;
		await page.goto(searchUrl, { waitUntil: 'domcontentloaded', timeout: timeoutMs });

		// 5. Wait for results to load (brief wait for dynamic content)
		await page.waitForTimeout(1500);

		// 6. Detect CAPTCHA/bot detection
		const pageTitle = (await page.title()).toLowerCase();
		const pageContent = await page.content();
		const botIndicators = ['captcha', 'robot', 'verify', 'blocked', 'access denied', 'unusual traffic'];

		const isBotDetected =
			botIndicators.some((indicator) => pageTitle.includes(indicator)) ||
			botIndicators.some((indicator) => pageContent.toLowerCase().includes(indicator));

		if (isBotDetected) {
			await browser.close();
			const dispatchError: DispatchError = {
				code: 'anti_bot',
				message: `Bot detection triggered on ${query.engineId}`
			};
			return { engineId: query.engineId, items: [], error: dispatchError };
		}

		// 7. Extract results using common result selectors
		const items = await page.evaluate(() => {
			const selectors = ['.result', '.search-result', 'article', '[data-result]'];
			let resultElements: Element[] = [];

			for (const selector of selectors) {
				const found = Array.from(document.querySelectorAll(selector));
				if (found.length > 0) {
					resultElements = found;
					break;
				}
			}

			return resultElements.map((el) => {
				// Extract title
				const titleEl =
					el.querySelector('h1, h2, h3, h4, .title, [class*="title"]') ??
					el.querySelector('a');
				const title = titleEl?.textContent?.trim() ?? '';

				// Extract URL
				const linkEl = el.querySelector('a[href]');
				const url = linkEl?.getAttribute('href') ?? '';

				// Extract snippet
				const snippetEl = el.querySelector(
					'p, .snippet, .description, [class*="snippet"], [class*="desc"]'
				);
				const snippet = snippetEl?.textContent?.trim() ?? '';

				return { title, url, snippet };
			});
		});

		// 8. Close browser
		await browser.close();

		// Map extracted items to RawResultItem[]
		const rawItems: RawResultItem[] = items
			.filter((item) => item.title || item.url)
			.map((item) => ({
				url: item.url || undefined,
				title: item.title || undefined,
				snippet: item.snippet || undefined,
				metadata: { source: 'playwright', engine: query.engineId },
				timestamp: new Date().toISOString()
			}));

		// 9. Return RawResult as JSON
		return {
			engineId: query.engineId,
			items: rawItems,
			totalEstimated: rawItems.length
		};
	} catch (err: unknown) {
		// Ensure browser is closed on error
		if (browser) {
			try {
				await browser.close();
			} catch {
				// ignore close errors
			}
		}

		const message = err instanceof Error ? err.message : 'Unknown Playwright error';
		const dispatchError: DispatchError = {
			code: 'unknown',
			message: `Playwright error for ${query.engineId}: ${message}`
		};
		return { engineId: query.engineId, items: [], error: dispatchError };
	}
}

/**
 * Build a search URL for the given engine base URL and query string.
 * Uses common search parameter patterns.
 */
function buildSearchUrl(baseUrl: string, nativeQuery: string): string {
	const encoded = encodeURIComponent(nativeQuery);

	// Map known base URLs to their search path/param patterns
	const searchPatterns: Record<string, string> = {
		'https://www.qwant.com': `https://www.qwant.com/?q=${encoded}&t=web`,
		'https://www.ecosia.org': `https://www.ecosia.org/search?q=${encoded}`,
		'https://www.seznam.cz': `https://search.seznam.cz/?q=${encoded}`,
		'https://www.sogou.com': `https://www.sogou.com/web?query=${encoded}`
	};

	if (searchPatterns[baseUrl]) {
		return searchPatterns[baseUrl];
	}

	// Generic fallback: append ?q=<query> to the base URL
	return `${baseUrl}/search?q=${encoded}`;
}
