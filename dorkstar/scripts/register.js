#!/usr/bin/env node
/**
 * DORKSTAR Playwright Registration Assistant
 * ─────────────────────────────────────────────────────────────────────────────
 * Launches a headed Chromium browser for each engine that requires API signup.
 * The user completes registration manually in the browser; the script then
 * prompts them to paste the API key back into the terminal and saves it.
 *
 * Called automatically by setup.js when the user chooses "Register" mode.
 * Can also be run standalone:
 *   node scripts/register.js              — register all unconfigured engines
 *   node scripts/register.js --engine shodan  — register a specific engine
 *   node scripts/register.js --list       — list all registerable engines
 */

import { chromium } from 'playwright';
import { createInterface } from 'readline';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

// ── Detect system Chrome path ─────────────────────────────────────────────────
function findSystemChrome() {
  const candidates = {
    darwin: [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
    ],
    linux: [
      '/usr/bin/google-chrome',
      '/usr/bin/google-chrome-stable',
      '/usr/bin/chromium-browser',
      '/usr/bin/chromium',
      '/snap/bin/chromium',
    ],
    win32: [
      'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    ],
  };
  for (const p of (candidates[process.platform] || [])) {
    if (existsSync(p)) return p;
  }
  return null;
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const ENV_FILE = resolve(ROOT, '.env.keys');

// ── ANSI colours ──────────────────────────────────────────────────────────────
const G  = (s) => `\x1b[32m${s}\x1b[0m`;
const Y  = (s) => `\x1b[33m${s}\x1b[0m`;
const R  = (s) => `\x1b[31m${s}\x1b[0m`;
const B  = (s) => `\x1b[1m${s}\x1b[0m`;
const D  = (s) => `\x1b[2m${s}\x1b[0m`;
const C  = (s) => `\x1b[36m${s}\x1b[0m`;

// ── Engine registration catalogue ─────────────────────────────────────────────
// Each entry defines where to navigate and what to look for after signup.
const REGISTERABLE_ENGINES = [
  {
    id: 'google',
    name: 'Google Custom Search',
    envKey: 'VITE_KEY_GOOGLE',
    signupUrl: 'https://programmablesearchengine.google.com/controlpanel/create',
    apiKeyUrl: 'https://console.cloud.google.com/apis/credentials',
    instructions: [
      '1. Create a Custom Search Engine at the signup page',
      '2. Note your Search Engine ID (cx parameter)',
      '3. Go to the API key page and create a new API key',
      '4. Restrict the key to "Custom Search API"',
      '5. Paste your key as: <search_engine_id>:<api_key>',
    ],
    keyFormat: 'cx_id:api_key',
  },
  {
    id: 'bing',
    name: 'Bing Search API',
    envKey: 'VITE_KEY_BING',
    signupUrl: 'https://portal.azure.com/#create/Microsoft.CognitiveServicesBingSearch-v7',
    apiKeyUrl: 'https://portal.azure.com/#view/Microsoft_Azure_ProjectOxford/CognitiveServicesHub/~/BingSearch',
    instructions: [
      '1. Create a Bing Search resource in Azure',
      '2. Choose the free F1 tier (1,000 transactions/month)',
      '3. After creation, go to "Keys and Endpoint"',
      '4. Copy KEY 1',
    ],
    keyFormat: 'api_key',
  },
  {
    id: 'shodan',
    name: 'Shodan',
    envKey: 'VITE_KEY_SHODAN',
    signupUrl: 'https://account.shodan.io/register',
    apiKeyUrl: 'https://account.shodan.io/',
    instructions: [
      '1. Create a Shodan account',
      '2. After login, your API key is shown on the account page',
      '3. Note: Shodan charges 1 credit per 100 result pages',
      '4. DORKSTAR will show a confirmation dialog before each query',
    ],
    keyFormat: 'api_key',
  },
  {
    id: 'censys',
    name: 'Censys',
    envKey: 'VITE_KEY_CENSYS',
    signupUrl: 'https://accounts.censys.io/register',
    apiKeyUrl: 'https://search.censys.io/account/api',
    instructions: [
      '1. Create a Censys account (free tier available)',
      '2. Go to the API page after login',
      '3. Copy your API ID and Secret',
      '4. Paste as: api_id:api_secret',
    ],
    keyFormat: 'api_id:api_secret',
  },
  {
    id: 'fofa',
    name: 'FOFA',
    envKey: 'VITE_KEY_FOFA',
    signupUrl: 'https://en.fofa.info/toLogin',
    apiKeyUrl: 'https://en.fofa.info/userInfo',
    instructions: [
      '1. Register a FOFA account',
      '2. Go to User Info after login',
      '3. Find your email and API key',
      '4. Paste as: email:api_key',
    ],
    keyFormat: 'email:api_key',
  },
  {
    id: 'zoomeye',
    name: 'ZoomEye',
    envKey: 'VITE_KEY_ZOOMEYE',
    signupUrl: 'https://www.zoomeye.org/signup',
    apiKeyUrl: 'https://www.zoomeye.org/profile',
    instructions: [
      '1. Register a ZoomEye account',
      '2. Go to your profile after login',
      '3. Find your API key in the API section',
    ],
    keyFormat: 'api_key',
  },
  {
    id: 'github',
    name: 'GitHub',
    envKey: 'VITE_KEY_GITHUB',
    signupUrl: 'https://github.com/signup',
    apiKeyUrl: 'https://github.com/settings/tokens/new?scopes=public_repo&description=DORKSTAR',
    instructions: [
      '1. Sign in to GitHub (or create an account)',
      '2. The token creation page will open automatically',
      '3. Set expiration as desired',
      '4. Click "Generate token" and copy it immediately',
      '5. Token is shown only once — save it now',
    ],
    keyFormat: 'ghp_token',
  },
  {
    id: 'gitlab',
    name: 'GitLab',
    envKey: 'VITE_KEY_GITLAB',
    signupUrl: 'https://gitlab.com/users/sign_up',
    apiKeyUrl: 'https://gitlab.com/-/profile/personal_access_tokens',
    instructions: [
      '1. Sign in to GitLab (or create an account)',
      '2. Create a Personal Access Token with "read_api" scope',
      '3. Copy the token — shown only once',
    ],
    keyFormat: 'glpat_token',
  },
  {
    id: 'virustotal',
    name: 'VirusTotal',
    envKey: 'VITE_KEY_VIRUSTOTAL',
    signupUrl: 'https://www.virustotal.com/gui/join-us',
    apiKeyUrl: 'https://www.virustotal.com/gui/my-apikey',
    instructions: [
      '1. Create a VirusTotal account (free)',
      '2. Go to your API key page after login',
      '3. Copy your API key',
      '4. Free tier: 4 lookups/min, 500/day',
    ],
    keyFormat: 'api_key',
  },
  {
    id: 'urlscan',
    name: 'urlscan.io',
    envKey: 'VITE_KEY_URLSCAN',
    signupUrl: 'https://urlscan.io/user/signup',
    apiKeyUrl: 'https://urlscan.io/user/profile/',
    instructions: [
      '1. Create a urlscan.io account (free)',
      '2. Go to your profile after login',
      '3. Find your API key in the API section',
    ],
    keyFormat: 'api_key',
  },
  {
    id: 'alienvault',
    name: 'AlienVault OTX',
    envKey: 'VITE_KEY_ALIENVAULT',
    signupUrl: 'https://otx.alienvault.com/accounts/register',
    apiKeyUrl: 'https://otx.alienvault.com/api',
    instructions: [
      '1. Create an AlienVault OTX account (free)',
      '2. Go to the API page after login',
      '3. Copy your OTX Key',
    ],
    keyFormat: 'api_key',
  },
  {
    id: 'twitter',
    name: 'Twitter/X Developer',
    envKey: 'VITE_KEY_TWITTER',
    signupUrl: 'https://developer.twitter.com/en/portal/petition/essential/basic-info',
    apiKeyUrl: 'https://developer.twitter.com/en/portal/dashboard',
    instructions: [
      '1. Apply for Twitter Developer access',
      '2. Create a new App in the Developer Portal',
      '3. Go to "Keys and Tokens"',
      '4. Generate a Bearer Token',
      '5. Copy the Bearer Token',
    ],
    keyFormat: 'bearer_token',
  },
  {
    id: 'reddit',
    name: 'Reddit API',
    envKey: 'VITE_KEY_REDDIT',
    signupUrl: 'https://www.reddit.com/register',
    apiKeyUrl: 'https://www.reddit.com/prefs/apps',
    instructions: [
      '1. Sign in to Reddit (or create an account)',
      '2. Go to App Preferences',
      '3. Click "create another app..." at the bottom',
      '4. Choose "script" type, fill in name and redirect URI (http://localhost)',
      '5. Copy the client_id (under app name) and secret',
      '6. Paste as: client_id:client_secret',
    ],
    keyFormat: 'client_id:client_secret',
  },
  {
    id: 'arxiv',
    name: 'arXiv (no key needed)',
    envKey: 'VITE_KEY_ARXIV',
    signupUrl: null,
    apiKeyUrl: 'https://info.arxiv.org/help/api/user-manual.html',
    instructions: [
      '1. arXiv does not require an API key',
      '2. Enter "none" to enable arXiv without a key',
      '3. Rate limit: 3 requests/second without key',
    ],
    keyFormat: 'none',
    noSignup: true,
  },
  {
    id: 'semantic_scholar',
    name: 'Semantic Scholar',
    envKey: 'VITE_KEY_SEMANTIC_SCHOLAR',
    signupUrl: 'https://api.semanticscholar.org/api-docs/#tag/API-Key',
    apiKeyUrl: 'https://www.semanticscholar.org/product/api#api-key',
    instructions: [
      '1. Request an API key from Semantic Scholar',
      '2. Fill in the request form (academic use)',
      '3. Key is emailed within a few days',
      '4. Free tier works without a key at lower rate limits',
    ],
    keyFormat: 'api_key',
  },
  {
    id: 'pubmed',
    name: 'PubMed / NCBI',
    envKey: 'VITE_KEY_PUBMED',
    signupUrl: 'https://www.ncbi.nlm.nih.gov/account/register/',
    apiKeyUrl: 'https://www.ncbi.nlm.nih.gov/account/settings/',
    instructions: [
      '1. Create an NCBI account (free)',
      '2. Go to Account Settings after login',
      '3. Find "API Key Management" section',
      '4. Generate a new API key',
      '5. With key: 10 req/sec; without: 3 req/sec',
    ],
    keyFormat: 'api_key',
  },
];

// ── Env file helpers ──────────────────────────────────────────────────────────

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
    '# Generated by: node scripts/register.js',
    `# Updated: ${new Date().toISOString()}`,
    '# DO NOT COMMIT THIS FILE',
    '',
  ];
  for (const [key, val] of Object.entries(env)) {
    if (val) lines.push(`${key}="${val}"`);
  }
  writeFileSync(ENV_FILE, lines.join('\n') + '\n', 'utf8');
}

function prompt(rl, question) {
  return new Promise(resolve => rl.question(question, resolve));
}

// ── Registration workflow ─────────────────────────────────────────────────────

async function registerEngine(engine, env, rl) {
  console.log('');
  console.log(G('┌─────────────────────────────────────────────────────────────┐'));
  console.log(G('│') + ` ${B(engine.name.padEnd(61))}` + G('│'));
  console.log(G('└─────────────────────────────────────────────────────────────┘'));
  console.log('');

  // Print instructions
  console.log(C('  Instructions:'));
  for (const step of engine.instructions) {
    console.log(D(`    ${step}`));
  }
  console.log('');

  // No-signup engines (arXiv)
  if (engine.noSignup) {
    console.log(Y('  This engine does not require signup.'));
    const answer = (await prompt(rl, `  Enter "none" to enable, or press Enter to skip: `)).trim();
    if (answer.toLowerCase() === 'none' || answer === '') {
      env[engine.envKey] = 'none';
      console.log(G('  ✓ Enabled without key.\n'));
    }
    return;
  }

  // Launch browser
  console.log(Y(`  Launching browser → ${engine.signupUrl || engine.apiKeyUrl}`));
  console.log(D('  Complete registration in the browser window, then return here.\n'));

  let browser;
  let page;

  try {
    // Use the system Chrome installation so Google auth works.
    // Playwright's bundled Chromium is blocked by Google's bot detection.
    const chromePath = findSystemChrome();

    browser = await chromium.launch({
      headless: false,
      executablePath: chromePath || undefined,
      args: [
        '--start-maximized',
        '--disable-blink-features=AutomationControlled',
        '--no-sandbox',
      ],
      ignoreDefaultArgs: ['--enable-automation'],
    });

    const context = await browser.newContext({
      viewport: null,
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      // Remove webdriver flag that Google detects
      javaScriptEnabled: true,
    });

    // Patch navigator.webdriver to undefined so Google doesn't block login
    await context.addInitScript(() => {
      Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
      Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });
      Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
    });

    page = await context.newPage();

    // Navigate to signup page first, then API key page
    const startUrl = engine.signupUrl || engine.apiKeyUrl;
    await page.goto(startUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });

    console.log(G('  ✓ Browser opened. Complete the registration steps above.'));
    console.log(D('  The browser will stay open until you paste your key below.\n'));

    // Wait for user to paste the key
    const answer = (await prompt(rl,
      `  ${G('Paste your API key')} (format: ${D(engine.keyFormat)}) or Enter to skip: `
    )).trim();

    await browser.close();

    if (!answer) {
      console.log(D('  Skipped.\n'));
      return;
    }

    if (answer.toLowerCase() === 'q') {
      await browser.close();
      throw new Error('quit');
    }

    env[engine.envKey] = answer;
    console.log(G(`  ✓ Key saved for ${engine.name}.\n`));

  } catch (err) {
    if (browser) {
      try { await browser.close(); } catch {}
    }
    if (err.message === 'quit') throw err;
    console.log(Y(`  Browser error: ${err.message}`));
    console.log(D('  You can enter the key manually instead.\n'));

    const manual = (await prompt(rl,
      `  ${G('Enter key manually')} (or press Enter to skip): `
    )).trim();

    if (manual) {
      env[engine.envKey] = manual;
      console.log(G(`  ✓ Key saved for ${engine.name}.\n`));
    } else {
      console.log(D('  Skipped.\n'));
    }
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────

export async function runRegistration(options = {}) {
  const {
    engineIds = null,   // null = all unconfigured; array = specific engines
    env: existingEnv = null,
  } = options;

  const env = existingEnv || loadEnvFile();
  const args = process.argv.slice(2);

  // --list: show all registerable engines
  if (args.includes('--list')) {
    console.log(B('\n  REGISTERABLE ENGINES\n'));
    for (const engine of REGISTERABLE_ENGINES) {
      const configured = env[engine.envKey];
      const status = configured ? G('✓') : D('○');
      console.log(`  ${status}  ${engine.name.padEnd(30)} ${D(engine.keyFormat)}`);
    }
    console.log('');
    return env;
  }

  // Determine which engines to register
  let toRegister = REGISTERABLE_ENGINES;

  if (engineIds) {
    toRegister = REGISTERABLE_ENGINES.filter(e => engineIds.includes(e.id));
  } else if (args.includes('--engine')) {
    const idx = args.indexOf('--engine');
    const id = args[idx + 1];
    toRegister = REGISTERABLE_ENGINES.filter(e => e.id === id);
    if (toRegister.length === 0) {
      console.log(R(`  Unknown engine: ${id}`));
      console.log(D('  Run with --list to see available engines'));
      process.exit(1);
    }
  } else {
    // Default: only unconfigured engines
    toRegister = REGISTERABLE_ENGINES.filter(e => !env[e.envKey]);
  }

  if (toRegister.length === 0) {
    console.log(G('\n  All engines already configured. Run with --engine <id> to re-register.\n'));
    return env;
  }

  console.log('');
  console.log(G('╔══════════════════════════════════════════════════════════════╗'));
  console.log(G('║') + B('  ✦ DORKSTAR  ') + '  Playwright Registration Assistant            ' + G('║'));
  console.log(G('╚══════════════════════════════════════════════════════════════╝'));
  console.log('');
  console.log(D(`  ${toRegister.length} engine(s) to register. A browser window will open for each.`));
  console.log(D('  Complete signup in the browser, then paste your API key here.\n'));
  console.log(D('  Requirements: Playwright must be installed (npm install)'));
  console.log(D('  and Chromium must be available (npx playwright install chromium)\n'));

  const rl = createInterface({ input: process.stdin, output: process.stdout });

  const proceed = (await prompt(rl, G('  Start registration? [Y/n]: '))).trim().toLowerCase();
  if (proceed === 'n' || proceed === 'no') {
    rl.close();
    console.log(D('\n  Registration cancelled.\n'));
    return env;
  }

  let registered = 0;

  for (const engine of toRegister) {
    try {
      await registerEngine(engine, env, rl);
      registered++;
      // Save after each engine in case user quits mid-way
      saveEnvFile(env);
    } catch (err) {
      if (err.message === 'quit') {
        console.log(Y('\n  Saving progress and exiting…\n'));
        break;
      }
      console.log(R(`  Error registering ${engine.name}: ${err.message}\n`));
    }
  }

  rl.close();
  saveEnvFile(env);

  const totalConfigured = REGISTERABLE_ENGINES.filter(e => env[e.envKey]).length;

  console.log('');
  console.log(G('╔══════════════════════════════════════════════════════════════╗'));
  console.log(G('║') + `  ${G('✓')} Registration complete                                       ` + G('║'));
  console.log(G('║') + `  ${G(registered + '')} engine(s) registered this session                       ` + G('║'));
  console.log(G('║') + `  ${G(totalConfigured + '/' + REGISTERABLE_ENGINES.length)} total engines configured                              ` + G('║'));
  console.log(G('╚══════════════════════════════════════════════════════════════╝'));
  console.log('');

  return env;
}

// Run standalone if called directly
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  runRegistration().catch(err => {
    console.error(R('\n  Registration failed: ') + err.message);
    process.exit(1);
  });
}
