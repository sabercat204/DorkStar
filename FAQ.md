# D0RKSTAR — Frequently Asked Questions

## General

### What is D0RKSTAR?
A universal query translation engine that converts a single canonical search query into 39 engine-native formats and executes them in parallel. It's a query permutation engine, not a search aggregator.

### Who is it for?
Security researchers, OSINT practitioners, penetration testers, bug bounty hunters, investigative journalists, and academic researchers who need to search across many platforms simultaneously.

### Is it free?
D0RKSTAR itself is free. Some search engines require paid API keys (e.g., Shodan charges per query). Many engines offer free tiers.

---

## Setup

### Why does my query return no results?
1. **No engines selected** — expand a category in the left sidebar and click engines to activate them
2. **No API keys configured** — run `npm run setup` to configure keys
3. **Parse errors** — check for red highlighting in the query input
4. **Rate limited** — check the status bar at the bottom for rate limit indicators

### How do I configure API keys?
```bash
npm run setup              # Interactive wizard
npm run setup:register     # Playwright opens browsers for signup
npm run setup:manual       # Paste keys in terminal
npm run setup:check        # Show current status
```

Keys are stored in `.env.keys` (gitignored, never committed) and loaded at build time.

### Where are my API keys stored?
Exclusively in your browser's IndexedDB. They never leave your device and are never transmitted to any server. The `.env.keys` file seeds IndexedDB on first load.

### Can I use D0RKSTAR without any API keys?
Tier 3 engines (Qwant, Ecosia, Seznam, Sogou) are dispatched via headless browser and don't require keys. However, they may be blocked by anti-bot detection. For reliable results, configure at least a few Tier 1/2 engine keys.

---

## Engines

### What are engine tiers?
| Tier | Description | Dispatch Method |
|------|-------------|-----------------|
| 1 | Full API with key | `fetch` via Web Worker |
| 2 | Limited free API | `fetch` via Web Worker |
| 3 | No public API | Playwright headless browser |

### What is a DegradationWarning?
When a canonical operator (e.g., `vuln:`) has no equivalent in a target engine (e.g., Google), D0RKSTAR emits a warning. The operator is omitted from that engine's query — never silently dropped. You'll see a ⚠ badge on the affected engine.

### What is Shodan credit consumption?
Shodan charges 1 credit per 100 result pages. D0RKSTAR shows a confirmation dialog before any Shodan query that would consume credits. IP lookups are free.

### What are Tier 3 engines?
Engines with no public API: Qwant, Ecosia, Seznam, Sogou. D0RKSTAR uses a Playwright headless browser to query them server-side. Availability is best-effort — anti-bot detection may block results.

---

## Queries

### How do I search multiple domains at once?
Use the Domain filter in the left sidebar. Enter one domain per line. Multiple domains are joined with OR:
```
(site:example.com OR site:foo.org)
```

### How do I search for multiple keywords?
Use the Multi-item filter in the left sidebar. Enter one term per line. Results matching ANY term are returned:
```
("admin panel" OR "login page" OR "password reset")
```

### How do I filter by file type?
Use the File Type filter in the left sidebar. Click individual types or use suggested presets (Music, Movies, Documents, etc.). Multiple types are OR-joined:
```
(filetype:pdf OR filetype:docx OR filetype:xlsx)
```

### What is Per-Engine mode?
Press Ctrl+Shift+E to write independent queries for each active engine. Use "Clone & Translate" to copy one engine's query to all others with auto-translation.

### How does deduplication work?
Results are deduplicated by canonical identifier (URL/IP). URLs are normalized: trailing slashes stripped, scheme and host lowercased, UTM parameters removed. Duplicates from multiple engines are merged into a single entry with all engine attributions preserved.

---

## Export

### Can I export results?
Yes. Use the [EXPORT] button in the left sidebar:
- **JSON** — structured data with all metadata
- **CSV** — spreadsheet-compatible
- **PDF** — formatted report
- **Save to file** — uses File System Access API (Chrome/Edge) for native file picker, falls back to download on other browsers

### Are exports sent to a server?
No. All exports are generated client-side in the browser. No result data is transmitted to any server.

---

## Docker

### How do I run D0RKSTAR in Docker?
```bash
cd dorkstar
docker compose up --build
```
Exposes port 3000. The Docker image includes Playwright/Chromium for Tier 3 engine dispatch.

### Does Docker persist data?
A named volume (`dorkstar-data`) persists the SQLite result store across container restarts. API keys are stored in the browser's IndexedDB, not in the container.

---

## Troubleshooting

### "No engines selected" error
Expand a category in the left sidebar (Web, IoT, Code, etc.) and click engine names to activate them.

### "No API keys configured" warning
Run `npm run setup` to configure keys. Without keys, Tier 1/2 engines return auth errors.

### Google blocks sign-in during Playwright registration
The registration script uses your system Chrome installation instead of Playwright's bundled Chromium. If Google still blocks it, complete registration manually at the engine's website and paste the key in the terminal.

### Tables look malformed in the Operator Reference
Clear your browser cache and reload. The app uses Courier New as the standard monospace font for reliable table rendering.
