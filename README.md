# D0RKSTAR

**Universal Query Translation Engine**

D0RKSTAR converts a single canonical search query into 39 engine-native formats and executes them in parallel. It is not a search aggregator — it is a query permutation engine.

Write one query. Hit Enter. Get results from Google, Shodan, Censys, GitHub, VirusTotal, and 34 more engines simultaneously.

## Quick Start

```bash
# Install dependencies
cd dorkstar
npm install

# Configure API keys (interactive wizard)
npm run setup

# Start development server
npm run dev
```

Open `http://localhost:5173` in your browser.

## What It Does

You type a canonical query like:

```
site:example.com filetype:pdf intitle:"admin panel"
```

D0RKSTAR:
1. Parses it into an operator AST via a PEG grammar
2. Translates the AST into native syntax for each active engine
3. Shows you a real-time preview of what each engine will search
4. Warns you when operators have no equivalent on a target engine
5. Dispatches all queries in parallel
6. Deduplicates and scores results across engines
7. Presents results in a unified panel

## Supported Engines (39)

| Category | Engines |
|----------|---------|
| **Web** (10) | Google, Bing, Yandex, DuckDuckGo, Baidu, Yahoo, Qwant, Ecosia, Seznam, Sogou |
| **IoT/Network** (11) | Shodan, Censys, FOFA, ZoomEye, BinaryEdge, Onyphe, LeakIX, Netlas, Criminal IP, Hunter.how, FullHunt |
| **Code** (4) | GitHub, GitLab, Sourcegraph, grep.app |
| **Threat Intel** (4) | VirusTotal, urlscan.io, AlienVault OTX, ThreatCrowd |
| **Paste/Content** (4) | Pastebin, GitHub Gist, PublicWWW, grep.io |
| **Social** (3) | Twitter/X, Reddit, LinkedIn |
| **Academic** (3) | arXiv, Semantic Scholar, PubMed |

## Architecture

```
Layer 1: Canonical Query Layer    — PEG grammar parser → operator AST
Layer 2: Translation Layer        — 39 engine adapters → native syntax
Layer 3: Dispatch & Rate Mgmt     — Web Workers + Playwright headless pool
Layer 4: Results Normalization    — dedup, score, merge, export
```

## Setup

### API Key Configuration

Most engines require API keys. D0RKSTAR provides two setup modes:

```bash
npm run setup              # Interactive wizard (choose Register or Manual)
npm run setup:register     # Playwright opens browsers for each engine signup
npm run setup:manual       # Paste keys directly in terminal
npm run setup:check        # Show current key status
npm run setup:reset        # Clear all keys
```

Keys are stored in `.env.keys` (gitignored) and loaded at build time via Vite environment variables. At runtime, keys live exclusively in the browser's IndexedDB — never transmitted to any server.

### Docker

```bash
docker compose up --build
```

Exposes port 3000. Includes Playwright/Chromium for Tier 3 engine dispatch.

## Usage

### Query Syntax

```
site:example.com                    # Restrict to domain
filetype:pdf                        # Filter by file type
intitle:"admin panel"               # Match in page title
ip:1.2.3.4 port:443                 # IoT/network search
repo:owner/name content:"api_key"   # Code search
from:user since:2024-01-01          # Social search
```

### Boolean Operators

```
term1 AND term2       # Both required
term1 OR term2        # Either matches
NOT term              # Exclude
-term                 # Exclude (shorthand)
"exact phrase"        # Exact match
word1 AROUND(3) word2 # Proximity search
```

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Enter | Execute query |
| Ctrl+Shift+E | Toggle per-engine mode |
| Tab (in autocomplete) | Insert operator |
| Escape | Close panels |

## UI Features

- **VT100 terminal aesthetic** — phosphor green CRT with scanlines
- **Shell prompt** — `root@dorkstar:~#` with blinking block cursor
- **Collapsible engine categories** — Web, IoT, Code, Threat, Paste, Social, Academic
- **File type selector** — 16 groups + 14 suggested presets (Music, Movies, Documents, etc.)
- **Domain search** — multi-domain OR queries
- **Multi-item search** — one keyword per line, OR-joined
- **Operator reference** — inline coverage matrix for all 95+ operators across 39 engines
- **Help panel** — man page, README, FAQ, About
- **Export** — JSON, CSV, PDF, Save to file

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | SvelteKit 5 (Runes mode), TypeScript |
| Parser | Custom tokenizer + recursive-descent (Ohm grammar for reference) |
| Translation | 39 engine adapter modules |
| Dispatch | Web Workers (Tier 1/2) + Playwright headless (Tier 3) |
| Storage | Browser IndexedDB (keys), SQLite (results) |
| Export | pdfmake (PDF), papaparse (CSV) |
| Testing | Vitest + fast-check (property-based) |

## Testing

```bash
npm run test          # Run all 496 tests
npm run test:watch    # Watch mode
```

## Security

- All API keys stored exclusively in browser IndexedDB
- Zero server-side key storage
- CSP headers prevent XSS exfiltration
- All exports generated client-side
- Shodan credit confirmation dialogs before consumption
- Input sanitized through PEG grammar before engine dispatch

## License

For authorised security research and OSINT use only. Scope limited to publicly accessible engines. No credential harvesting. No exploitation. No evasion.
