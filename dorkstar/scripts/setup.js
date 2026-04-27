#!/usr/bin/env node
/**
 * DORKSTAR Setup Script
 * ─────────────────────────────────────────────────────────────────────────────
 * Interactive CLI wizard that guides through API key configuration.
 * Keys are written to a local .env.keys file which is loaded at dev/build time
 * and injected into the app as Vite environment variables.
 *
 * Usage:
 *   node scripts/setup.js          — full interactive setup
 *   node scripts/setup.js --check  — show current key status only
 *   node scripts/setup.js --reset  — clear all configured keys
 *
 * The generated .env.keys file is gitignored by default.
 * Keys are NEVER sent to any server — they are embedded at build time and
 * stored in the browser's IndexedDB at runtime.
 */

import { createInterface } from 'readline';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const ENV_FILE = resolve(ROOT, '.env.keys');

// ── ANSI colours ─────────────────────────────────────────────────────────────
const G  = (s) => `\x1b[32m${s}\x1b[0m`;   // green
const DG = (s) => `\x1b[2;32m${s}\x1b[0m`; // dim green
const Y  = (s) => `\x1b[33m${s}\x1b[0m`;   // yellow
const R  = (s) => `\x1b[31m${s}\x1b[0m`;   // red
const B  = (s) => `\x1b[1m${s}\x1b[0m`;    // bold
const D  = (s) => `\x1b[2m${s}\x1b[0m`;    // dim
const C  = (s) => `\x1b[36m${s}\x1b[0m`;   // cyan

// ── Engine catalogue ──────────────────────────────────────────────────────────
const ENGINES = [
  // ── Web ──────────────────────────────────────────────────────────────────
  {
    id: 'google', name: 'Google CSE', category: 'Web', tier: 2,
    envKey: 'VITE_KEY_GOOGLE',
    docsUrl: 'https://developers.google.com/custom-search/v1/overview',
    notes: 'Requires a Custom Search Engine ID + API key. Free tier: 100 queries/day.',
    required: false,
  },
  {
    id: 'bing', name: 'Bing Search', category: 'Web', tier: 2,
    envKey: 'VITE_KEY_BING',
    docsUrl: 'https://learn.microsoft.com/en-us/bing/search-apis/bing-web-search/overview',
    notes: 'Azure Cognitive Services key. Free tier: 1,000 transactions/month.',
    required: false,
  },
  // ── IoT / Network ─────────────────────────────────────────────────────────
  {
    id: 'shodan', name: 'Shodan', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_SHODAN',
    docsUrl: 'https://account.shodan.io/',
    notes: 'Paid API key. 1 credit per 100 result pages. Confirmation dialog shown before use.',
    required: false,
  },
  {
    id: 'censys', name: 'Censys', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_CENSYS',
    docsUrl: 'https://search.censys.io/account/api',
    notes: 'Free tier available. Requires API ID + Secret (enter as "id:secret").',
    required: false,
  },
  {
    id: 'fofa', name: 'FOFA', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_FOFA',
    docsUrl: 'https://en.fofa.info/api',
    notes: 'Requires email + API key (enter as "email:key").',
    required: false,
  },
  {
    id: 'zoomeye', name: 'ZoomEye', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_ZOOMEYE',
    docsUrl: 'https://www.zoomeye.org/doc',
    notes: 'Free tier: 10,000 results/month.',
    required: false,
  },
  {
    id: 'binaryedge', name: 'BinaryEdge', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_BINARYEDGE',
    docsUrl: 'https://docs.binaryedge.io/api-v2/',
    notes: 'Paid API. Free trial available.',
    required: false,
  },
  {
    id: 'onyphe', name: 'Onyphe', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_ONYPHE',
    docsUrl: 'https://www.onyphe.io/documentation/api',
    notes: 'Free community tier available.',
    required: false,
  },
  {
    id: 'leakix', name: 'LeakIX', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_LEAKIX',
    docsUrl: 'https://leakix.net/docs/api',
    notes: 'Free API key available after registration.',
    required: false,
  },
  {
    id: 'netlas', name: 'Netlas', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_NETLAS',
    docsUrl: 'https://docs.netlas.io/api/',
    notes: 'Free tier: 50 requests/day.',
    required: false,
  },
  {
    id: 'criminalip', name: 'Criminal IP', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_CRIMINALIP',
    docsUrl: 'https://www.criminalip.io/developer/api/post-asset-search',
    notes: 'Free tier available.',
    required: false,
  },
  {
    id: 'hunter', name: 'Hunter.how', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_HUNTER',
    docsUrl: 'https://hunter.how/search-api',
    notes: 'Free tier: 100 queries/month.',
    required: false,
  },
  {
    id: 'fullhunt', name: 'FullHunt', category: 'IoT/Network', tier: 1,
    envKey: 'VITE_KEY_FULLHUNT',
    docsUrl: 'https://api-docs.fullhunt.io/',
    notes: 'Free tier available.',
    required: false,
  },
  // ── Code Search ───────────────────────────────────────────────────────────
  {
    id: 'github', name: 'GitHub', category: 'Code', tier: 1,
    envKey: 'VITE_KEY_GITHUB',
    docsUrl: 'https://github.com/settings/tokens',
    notes: 'Personal Access Token. Free. Unauthenticated: 10 req/min; authenticated: 30 req/min.',
    required: false,
  },
  {
    id: 'gitlab', name: 'GitLab', category: 'Code', tier: 1,
    envKey: 'VITE_KEY_GITLAB',
    docsUrl: 'https://gitlab.com/-/profile/personal_access_tokens',
    notes: 'Personal Access Token with read_api scope.',
    required: false,
  },
  {
    id: 'sourcegraph', name: 'Sourcegraph', category: 'Code', tier: 1,
    envKey: 'VITE_KEY_SOURCEGRAPH',
    docsUrl: 'https://sourcegraph.com/user/settings/tokens',
    notes: 'Access token from sourcegraph.com. Free for public code.',
    required: false,
  },
  // ── Threat Intelligence ───────────────────────────────────────────────────
  {
    id: 'virustotal', name: 'VirusTotal', category: 'Threat Intel', tier: 1,
    envKey: 'VITE_KEY_VIRUSTOTAL',
    docsUrl: 'https://www.virustotal.com/gui/my-apikey',
    notes: 'Free public API: 4 lookups/min, 500/day.',
    required: false,
  },
  {
    id: 'urlscan', name: 'urlscan.io', category: 'Threat Intel', tier: 1,
    envKey: 'VITE_KEY_URLSCAN',
    docsUrl: 'https://urlscan.io/user/profile/',
    notes: 'Free API key. 5,000 searches/day.',
    required: false,
  },
  {
    id: 'alienvault', name: 'AlienVault OTX', category: 'Threat Intel', tier: 1,
    envKey: 'VITE_KEY_ALIENVAULT',
    docsUrl: 'https://otx.alienvault.com/api',
    notes: 'Free API key after registration.',
    required: false,
  },
  // ── Paste / Content ───────────────────────────────────────────────────────
  {
    id: 'pastebin', name: 'Pastebin', category: 'Paste', tier: 1,
    envKey: 'VITE_KEY_PASTEBIN',
    docsUrl: 'https://pastebin.com/doc_api',
    notes: 'Requires Pro account for scraping API.',
    required: false,
  },
  // ── Social ────────────────────────────────────────────────────────────────
  {
    id: 'twitter', name: 'Twitter/X', category: 'Social', tier: 1,
    envKey: 'VITE_KEY_TWITTER',
    docsUrl: 'https://developer.twitter.com/en/portal/dashboard',
    notes: 'Bearer Token from Twitter Developer Portal. Free Basic tier: 500k tweets/month.',
    required: false,
  },
  {
    id: 'reddit', name: 'Reddit', category: 'Social', tier: 1,
    envKey: 'VITE_KEY_REDDIT',
    docsUrl: 'https://www.reddit.com/prefs/apps',
    notes: 'OAuth2 client credentials. Free. Enter as "client_id:client_secret".',
    required: false,
  },
  // ── Academic ──────────────────────────────────────────────────────────────
  {
    id: 'arxiv', name: 'arXiv', category: 'Academic', tier: 1,
    envKey: 'VITE_KEY_ARXIV',
    docsUrl: 'https://info.arxiv.org/help/api/user-manual.html',
    notes: 'No API key required — enter "none" to enable without a key.',
    required: false,
  },
  {
    id: 'semantic_scholar', name: 'Semantic Scholar', category: 'Academic', tier: 1,
    envKey: 'VITE_KEY_SEMANTIC_SCHOLAR',
    docsUrl: 'https://api.semanticscholar.org/api-docs/',
    notes: 'Free API. Optional key for higher rate limits.',
    required: false,
  },
  {
    id: 'pubmed', name: 'PubMed', category: 'Academic', tier: 1,
    envKey: 'VITE_KEY_PUBMED',
    docsUrl: 'https://www.ncbi.nlm.nih.gov/account/',
    notes: 'NCBI API key. Free. Without key: 3 req/sec; with key: 10 req/sec.',
    required: false,
  },
];

const CATEGORIES = [...new Set(ENGINES.map(e => e.category))];

// ── Helpers ───────────────────────────────────────────────────────────────────

function loadEnvFile() {
  if (!existsSync(ENV_FILE)) return {};
  const lines = readFileSync(ENV_FILE, 'utf8').split('\n');
  const env = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const val = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
    env[key] = val;
  }
  return env;
}

function saveEnvFile(env) {
  const lines = [
    '# DORKSTAR API Keys',
    '# Generated by: node scripts/setup.js',
    `# Updated: ${new Date().toISOString()}`,
    '# DO NOT COMMIT THIS FILE — add .env.keys to .gitignore',
    '',
  ];
  for (const [key, val] of Object.entries(env)) {
    if (val) lines.push(`${key}="${val}"`);
  }
  writeFileSync(ENV_FILE, lines.join('\n') + '\n', 'utf8');
}

function maskKey(key) {
  if (!key || key === 'none') return key;
  if (key.length <= 8) return '****';
  return key.slice(0, 4) + '****' + key.slice(-4);
}

function prompt(rl, question) {
  return new Promise(resolve => rl.question(question, resolve));
}

function printHeader() {
  console.log('');
  console.log(G('╔══════════════════════════════════════════════════════════════╗'));
  console.log(G('║') + B('  ✦ DORKSTAR  ') + D('Universal Query Translation Engine') + G('         ║'));
  console.log(G('║') + D('  API Key Configuration Wizard                                ') + G('║'));
  console.log(G('╚══════════════════════════════════════════════════════════════╝'));
  console.log('');
}

function printStatus(env) {
  console.log(B('\n  ENGINE KEY STATUS\n'));
  let configured = 0;
  for (const cat of CATEGORIES) {
    const catEngines = ENGINES.filter(e => e.category === cat);
    console.log(C(`  ── ${cat} ──`));
    for (const engine of catEngines) {
      const val = env[engine.envKey];
      const status = val ? G('✓ configured') : DG('○ not set');
      const masked = val ? D(`  [${maskKey(val)}]`) : '';
      console.log(`    ${status}  ${engine.name}${masked}`);
      if (val) configured++;
    }
    console.log('');
  }
  console.log(D(`  ${configured}/${ENGINES.length} engines configured\n`));
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  const env = loadEnvFile();

  printHeader();

  // --check: show status and exit
  if (args.includes('--check')) {
    printStatus(env);
    process.exit(0);
  }

  // --reset: clear all keys
  if (args.includes('--reset')) {
    console.log(Y('  Clearing all configured API keys…'));
    saveEnvFile({});
    console.log(G('  Done. All keys removed from .env.keys\n'));
    process.exit(0);
  }

  // Interactive setup
  console.log(D('  This wizard will guide you through configuring API keys for each'));
  console.log(D('  search engine. Keys are stored in .env.keys (gitignored) and'));
  console.log(D('  loaded into the app via Vite environment variables.\n'));
  console.log(D('  Press Enter to skip an engine. Type "none" for engines that'));
  console.log(D('  don\'t require a key (e.g. arXiv). Type "q" to quit and save.\n'));

  printStatus(env);

  const rl = createInterface({ input: process.stdin, output: process.stdout });

  // Ask which categories to configure
  console.log(B('  Which categories do you want to configure?'));
  console.log(D('  (Enter comma-separated numbers, or "all", or press Enter to configure all)\n'));
  CATEGORIES.forEach((cat, i) => {
    const count = ENGINES.filter(e => e.category === cat).length;
    const configured = ENGINES.filter(e => e.category === cat && env[e.envKey]).length;
    console.log(`    ${D(`[${i+1}]`)} ${cat} ${D(`(${configured}/${count} configured)`)}`);
  });
  console.log('');

  const catChoice = (await prompt(rl, G('  > '))).trim();
  let selectedCategories;

  if (!catChoice || catChoice.toLowerCase() === 'all') {
    selectedCategories = CATEGORIES;
  } else {
    const indices = catChoice.split(',').map(s => parseInt(s.trim()) - 1).filter(i => i >= 0 && i < CATEGORIES.length);
    selectedCategories = indices.map(i => CATEGORIES[i]);
    if (selectedCategories.length === 0) selectedCategories = CATEGORIES;
  }

  console.log('');

  // Walk through each selected engine
  for (const cat of selectedCategories) {
    const catEngines = ENGINES.filter(e => e.category === cat);
    console.log(C(`\n  ── ${cat} ──────────────────────────────────────────────\n`));

    for (const engine of catEngines) {
      const current = env[engine.envKey];
      const currentDisplay = current ? ` ${D(`(current: ${maskKey(current)})`)}` : '';

      console.log(B(`  ${engine.name}`) + currentDisplay);
      console.log(D(`  ${engine.notes}`));
      console.log(D(`  Docs: ${engine.docsUrl}`));

      const answer = (await prompt(rl, `  ${G('API key')} (Enter to skip, "q" to quit): `)).trim();

      if (answer.toLowerCase() === 'q') {
        console.log(Y('\n  Saving and exiting…'));
        break;
      }

      if (answer === '') {
        console.log(D('  Skipped.\n'));
        continue;
      }

      if (answer.toLowerCase() === 'clear' || answer.toLowerCase() === 'remove') {
        delete env[engine.envKey];
        console.log(Y('  Key removed.\n'));
        continue;
      }

      env[engine.envKey] = answer;
      console.log(G('  ✓ Key saved.\n'));
    }
  }

  rl.close();

  // Save .env.keys
  saveEnvFile(env);

  const configured = ENGINES.filter(e => env[e.envKey]).length;
  console.log('');
  console.log(G('╔══════════════════════════════════════════════════════════════╗'));
  console.log(G('║') + `  ${G('✓')} Configuration saved to ${B('.env.keys')}                         ` + G('║'));
  console.log(G('║') + `  ${G(configured + '/' + ENGINES.length)} engines configured                                  ` + G('║'));
  console.log(G('╚══════════════════════════════════════════════════════════════╝'));
  console.log('');
  console.log(D('  Next steps:'));
  console.log(D('    1. Run: ') + G('npm run dev') + D(' to start the development server'));
  console.log(D('    2. Keys are loaded automatically via Vite env variables'));
  console.log(D('    3. Re-run this script anytime: ') + G('node scripts/setup.js'));
  console.log(D('    4. Check status: ') + G('node scripts/setup.js --check'));
  console.log('');
}

main().catch(err => {
  console.error(R('\n  Setup failed: ') + err.message);
  process.exit(1);
});
