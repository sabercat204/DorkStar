import type { EngineId, EngineRegistryEntry } from '../types';
import type { EngineAdapter } from './base';
import { SHODAN_CREDIT_MODEL } from './shodan';

// Web adapters
import { GoogleAdapter } from './google';
import { BingAdapter } from './bing';
import { YandexAdapter } from './yandex';
import { DuckDuckGoAdapter } from './duckduckgo';
import { BaiduAdapter } from './baidu';
import { YahooAdapter } from './yahoo';
import { QwantAdapter } from './qwant';
import { EcosiaAdapter } from './ecosia';
import { SeznamAdapter } from './seznam';
import { SogouAdapter } from './sogou';

// IoT / network adapters
import { ShodanAdapter } from './shodan';
import { CensysAdapter } from './censys';
import { FofaAdapter } from './fofa';
import { ZoomEyeAdapter } from './zoomeye';
import { BinaryEdgeAdapter } from './binaryedge';
import { OnypheAdapter } from './onyphe';
import { LeakIXAdapter } from './leakix';
import { NetlasAdapter } from './netlas';
import { CriminalIPAdapter } from './criminalip';
import { HunterAdapter } from './hunter';
import { FullHuntAdapter } from './fullhunt';

// Code search adapters
import { GitHubAdapter } from './github';
import { GitLabAdapter } from './gitlab';
import { SourcegraphAdapter } from './sourcegraph';
import { GrepAppAdapter } from './grep_app';

// Threat intelligence adapters
import { VirusTotalAdapter } from './virustotal';
import { URLScanAdapter } from './urlscan';
import { AlienVaultAdapter } from './alienvault';
import { ThreatCrowdAdapter } from './threatcrowd';

// Paste / content adapters
import { PastebinAdapter } from './pastebin';
import { GistAdapter } from './gist';
import { PublicWWWAdapter } from './publicwww';
import { GrepIOAdapter } from './grep_io';

// Social adapters
import { TwitterAdapter } from './twitter';
import { RedditAdapter } from './reddit';
import { LinkedInAdapter } from './linkedin';

// Academic adapters
import { ArxivAdapter } from './arxiv';
import { SemanticScholarAdapter } from './semantic_scholar';
import { PubMedAdapter } from './pubmed';

// ─── Instantiate all 39 adapters ────────────────────────────────────────────

const googleAdapter = new GoogleAdapter();
const bingAdapter = new BingAdapter();
const yandexAdapter = new YandexAdapter();
const duckduckgoAdapter = new DuckDuckGoAdapter();
const baiduAdapter = new BaiduAdapter();
const yahooAdapter = new YahooAdapter();
const qwantAdapter = new QwantAdapter();
const ecosiaAdapter = new EcosiaAdapter();
const seznamAdapter = new SeznamAdapter();
const sogouAdapter = new SogouAdapter();

const shodanAdapter = new ShodanAdapter();
const censysAdapter = new CensysAdapter();
const fofaAdapter = new FofaAdapter();
const zoomeyeAdapter = new ZoomEyeAdapter();
const binaryedgeAdapter = new BinaryEdgeAdapter();
const onypheAdapter = new OnypheAdapter();
const leakixAdapter = new LeakIXAdapter();
const netlasAdapter = new NetlasAdapter();
const criminalipAdapter = new CriminalIPAdapter();
const hunterAdapter = new HunterAdapter();
const fullhuntAdapter = new FullHuntAdapter();

const githubAdapter = new GitHubAdapter();
const gitlabAdapter = new GitLabAdapter();
const sourcegraphAdapter = new SourcegraphAdapter();
const grepAppAdapter = new GrepAppAdapter();

const virustotalAdapter = new VirusTotalAdapter();
const urlscanAdapter = new URLScanAdapter();
const alienvaultAdapter = new AlienVaultAdapter();
const threatcrowdAdapter = new ThreatCrowdAdapter();

const pastebinAdapter = new PastebinAdapter();
const gistAdapter = new GistAdapter();
const publicwwwAdapter = new PublicWWWAdapter();
const grepIoAdapter = new GrepIOAdapter();

const twitterAdapter = new TwitterAdapter();
const redditAdapter = new RedditAdapter();
const linkedinAdapter = new LinkedInAdapter();

const arxivAdapter = new ArxivAdapter();
const semanticScholarAdapter = new SemanticScholarAdapter();
const pubmedAdapter = new PubMedAdapter();

// ─── Adapter registry map ───────────────────────────────────────────────────

/**
 * Map from EngineId to its instantiated adapter.
 * Used by TranslationManager to look up adapters at runtime.
 */
export const adapterRegistry: Map<EngineId, EngineAdapter> = new Map<EngineId, EngineAdapter>([
  ['google', googleAdapter],
  ['bing', bingAdapter],
  ['yandex', yandexAdapter],
  ['duckduckgo', duckduckgoAdapter],
  ['baidu', baiduAdapter],
  ['yahoo', yahooAdapter],
  ['qwant', qwantAdapter],
  ['ecosia', ecosiaAdapter],
  ['seznam', seznamAdapter],
  ['sogou', sogouAdapter],
  ['shodan', shodanAdapter],
  ['censys', censysAdapter],
  ['fofa', fofaAdapter],
  ['zoomeye', zoomeyeAdapter],
  ['binaryedge', binaryedgeAdapter],
  ['onyphe', onypheAdapter],
  ['leakix', leakixAdapter],
  ['netlas', netlasAdapter],
  ['criminalip', criminalipAdapter],
  ['hunter', hunterAdapter],
  ['fullhunt', fullhuntAdapter],
  ['github', githubAdapter],
  ['gitlab', gitlabAdapter],
  ['sourcegraph', sourcegraphAdapter],
  ['grep_app', grepAppAdapter],
  ['virustotal', virustotalAdapter],
  ['urlscan', urlscanAdapter],
  ['alienvault', alienvaultAdapter],
  ['threatcrowd', threatcrowdAdapter],
  ['pastebin', pastebinAdapter],
  ['gist', gistAdapter],
  ['publicwww', publicwwwAdapter],
  ['grep_io', grepIoAdapter],
  ['twitter', twitterAdapter],
  ['reddit', redditAdapter],
  ['linkedin', linkedinAdapter],
  ['arxiv', arxivAdapter],
  ['semantic_scholar', semanticScholarAdapter],
  ['pubmed', pubmedAdapter],
]);

// ─── Full engine registry metadata ──────────────────────────────────────────

/**
 * Full metadata for all 39 registered search engines.
 * Used by the /docs page, engine selector, and budget footer.
 */
export const ENGINE_REGISTRY: EngineRegistryEntry[] = [
  // ── Web engines ────────────────────────────────────────────────────────────
  {
    id: 'google',
    displayName: 'Google',
    category: 'web',
    tier: 2,
    baseUrl: 'https://www.google.com',
    apiEndpoint: 'https://www.googleapis.com/customsearch/v1',
    docsUrl: 'https://developers.google.com/custom-search/v1/overview',
    supportedOperators: [...googleAdapter.supportedOperators],
    operatorCount: googleAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 1 },
  },
  {
    id: 'bing',
    displayName: 'Bing',
    category: 'web',
    tier: 2,
    baseUrl: 'https://www.bing.com',
    apiEndpoint: 'https://api.bing.microsoft.com/v7.0/search',
    docsUrl: 'https://learn.microsoft.com/en-us/bing/search-apis/bing-web-search/overview',
    supportedOperators: [...bingAdapter.supportedOperators],
    operatorCount: bingAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 10 },
  },
  {
    id: 'yandex',
    displayName: 'Yandex',
    category: 'web',
    tier: 2,
    baseUrl: 'https://yandex.com',
    docsUrl: 'https://yandex.com/support/search/query-language/search-operators.html',
    supportedOperators: [...yandexAdapter.supportedOperators],
    operatorCount: yandexAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 10 },
  },
  {
    id: 'duckduckgo',
    displayName: 'DuckDuckGo',
    category: 'web',
    tier: 2,
    baseUrl: 'https://duckduckgo.com',
    docsUrl: 'https://help.duckduckgo.com/duckduckgo-help-pages/results/syntax/',
    supportedOperators: [...duckduckgoAdapter.supportedOperators],
    operatorCount: duckduckgoAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 10 },
  },
  {
    id: 'baidu',
    displayName: 'Baidu',
    category: 'web',
    tier: 2,
    baseUrl: 'https://www.baidu.com',
    docsUrl: 'https://www.baidu.com/more/',
    supportedOperators: [...baiduAdapter.supportedOperators],
    operatorCount: baiduAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 10 },
  },
  {
    id: 'yahoo',
    displayName: 'Yahoo',
    category: 'web',
    tier: 2,
    baseUrl: 'https://search.yahoo.com',
    docsUrl: 'https://help.yahoo.com/kb/search/SLN2063.html',
    supportedOperators: [...yahooAdapter.supportedOperators],
    operatorCount: yahooAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 10 },
  },
  {
    id: 'qwant',
    displayName: 'Qwant',
    category: 'web',
    tier: 3,
    baseUrl: 'https://www.qwant.com',
    docsUrl: 'https://help.qwant.com/en/docs/qwant-search/searching/how-to-use-qwant-search/',
    supportedOperators: [...qwantAdapter.supportedOperators],
    operatorCount: qwantAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 5 },
  },
  {
    id: 'ecosia',
    displayName: 'Ecosia',
    category: 'web',
    tier: 3,
    baseUrl: 'https://www.ecosia.org',
    docsUrl: 'https://ecosia.helpscoutdocs.com/article/469-search-operators',
    supportedOperators: [...ecosiaAdapter.supportedOperators],
    operatorCount: ecosiaAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 5 },
  },
  {
    id: 'seznam',
    displayName: 'Seznam',
    category: 'web',
    tier: 3,
    baseUrl: 'https://www.seznam.cz',
    docsUrl: 'https://napoveda.seznam.cz/cz/fulltext-hledani-v-internetu/',
    supportedOperators: [...seznamAdapter.supportedOperators],
    operatorCount: seznamAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 5 },
  },
  {
    id: 'sogou',
    displayName: 'Sogou',
    category: 'web',
    tier: 3,
    baseUrl: 'https://www.sogou.com',
    docsUrl: 'https://www.sogou.com/docs/help.htm',
    supportedOperators: [...sogouAdapter.supportedOperators],
    operatorCount: sogouAdapter.operatorCount,
    requiresKey: false,
    rateLimit: { requestsPerMinute: 5 },
  },

  // ── IoT / network engines ──────────────────────────────────────────────────
  {
    id: 'shodan',
    displayName: 'Shodan',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://www.shodan.io',
    apiEndpoint: 'https://api.shodan.io/shodan/host/search',
    docsUrl: 'https://help.shodan.io/the-basics/search-query-fundamentals',
    supportedOperators: [...shodanAdapter.supportedOperators],
    operatorCount: shodanAdapter.operatorCount,
    requiresKey: true,
    creditModel: SHODAN_CREDIT_MODEL,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'censys',
    displayName: 'Censys',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://search.censys.io',
    apiEndpoint: 'https://search.censys.io/api/v2/hosts/search',
    docsUrl: 'https://search.censys.io/search/language',
    supportedOperators: [...censysAdapter.supportedOperators],
    operatorCount: censysAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'fofa',
    displayName: 'FOFA',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://fofa.info',
    apiEndpoint: 'https://fofa.info/api/v1/search/all',
    docsUrl: 'https://en.fofa.info/api',
    supportedOperators: [...fofaAdapter.supportedOperators],
    operatorCount: fofaAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'zoomeye',
    displayName: 'ZoomEye',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://www.zoomeye.org',
    apiEndpoint: 'https://api.zoomeye.org/host/search',
    docsUrl: 'https://www.zoomeye.org/doc',
    supportedOperators: [...zoomeyeAdapter.supportedOperators],
    operatorCount: zoomeyeAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'binaryedge',
    displayName: 'BinaryEdge',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://app.binaryedge.io',
    apiEndpoint: 'https://api.binaryedge.io/v2/query/search',
    docsUrl: 'https://docs.binaryedge.io/api-v2/',
    supportedOperators: [...binaryedgeAdapter.supportedOperators],
    operatorCount: binaryedgeAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'onyphe',
    displayName: 'Onyphe',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://www.onyphe.io',
    apiEndpoint: 'https://www.onyphe.io/api/v2/simple',
    docsUrl: 'https://www.onyphe.io/documentation/api',
    supportedOperators: [...onypheAdapter.supportedOperators],
    operatorCount: onypheAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'leakix',
    displayName: 'LeakIX',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://leakix.net',
    apiEndpoint: 'https://leakix.net/search',
    docsUrl: 'https://leakix.net/docs/api',
    supportedOperators: [...leakixAdapter.supportedOperators],
    operatorCount: leakixAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'netlas',
    displayName: 'Netlas',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://app.netlas.io',
    apiEndpoint: 'https://app.netlas.io/api/responses',
    docsUrl: 'https://docs.netlas.io/api/',
    supportedOperators: [...netlasAdapter.supportedOperators],
    operatorCount: netlasAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'criminalip',
    displayName: 'Criminal IP',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://www.criminalip.io',
    apiEndpoint: 'https://api.criminalip.io/v1/asset/search',
    docsUrl: 'https://www.criminalip.io/developer/api/post-asset-search',
    supportedOperators: [...criminalipAdapter.supportedOperators],
    operatorCount: criminalipAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'hunter',
    displayName: 'Hunter.how',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://hunter.how',
    apiEndpoint: 'https://api.hunter.how/search',
    docsUrl: 'https://hunter.how/search-api',
    supportedOperators: [...hunterAdapter.supportedOperators],
    operatorCount: hunterAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'fullhunt',
    displayName: 'FullHunt',
    category: 'iot',
    tier: 1,
    baseUrl: 'https://fullhunt.io',
    apiEndpoint: 'https://fullhunt.io/api/v1/domain/search',
    docsUrl: 'https://api-docs.fullhunt.io/',
    supportedOperators: [...fullhuntAdapter.supportedOperators],
    operatorCount: fullhuntAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },

  // ── Code search engines ────────────────────────────────────────────────────
  {
    id: 'github',
    displayName: 'GitHub',
    category: 'code',
    tier: 1,
    baseUrl: 'https://github.com',
    apiEndpoint: 'https://api.github.com/search/code',
    docsUrl: 'https://docs.github.com/en/search-github/searching-on-github/searching-code',
    supportedOperators: [...githubAdapter.supportedOperators],
    operatorCount: githubAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'gitlab',
    displayName: 'GitLab',
    category: 'code',
    tier: 1,
    baseUrl: 'https://gitlab.com',
    apiEndpoint: 'https://gitlab.com/api/v4/search',
    docsUrl: 'https://docs.gitlab.com/ee/api/search.html',
    supportedOperators: [...gitlabAdapter.supportedOperators],
    operatorCount: gitlabAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'sourcegraph',
    displayName: 'Sourcegraph',
    category: 'code',
    tier: 1,
    baseUrl: 'https://sourcegraph.com',
    apiEndpoint: 'https://sourcegraph.com/.api/search/stream',
    docsUrl: 'https://docs.sourcegraph.com/code_search/reference/queries',
    supportedOperators: [...sourcegraphAdapter.supportedOperators],
    operatorCount: sourcegraphAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'grep_app',
    displayName: 'grep.app',
    category: 'code',
    tier: 1,
    baseUrl: 'https://grep.app',
    apiEndpoint: 'https://grep.app/api/search',
    docsUrl: 'https://grep.app',
    supportedOperators: [...grepAppAdapter.supportedOperators],
    operatorCount: grepAppAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },

  // ── Threat intelligence engines ────────────────────────────────────────────
  {
    id: 'virustotal',
    displayName: 'VirusTotal',
    category: 'threat',
    tier: 1,
    baseUrl: 'https://www.virustotal.com',
    apiEndpoint: 'https://www.virustotal.com/api/v3/search',
    docsUrl: 'https://developers.virustotal.com/reference/overview',
    supportedOperators: [...virustotalAdapter.supportedOperators],
    operatorCount: virustotalAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'urlscan',
    displayName: 'urlscan.io',
    category: 'threat',
    tier: 1,
    baseUrl: 'https://urlscan.io',
    apiEndpoint: 'https://urlscan.io/api/v1/search',
    docsUrl: 'https://urlscan.io/docs/api/',
    supportedOperators: [...urlscanAdapter.supportedOperators],
    operatorCount: urlscanAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'alienvault',
    displayName: 'AlienVault OTX',
    category: 'threat',
    tier: 1,
    baseUrl: 'https://otx.alienvault.com',
    apiEndpoint: 'https://otx.alienvault.com/api/v1/search',
    docsUrl: 'https://otx.alienvault.com/api',
    supportedOperators: [...alienvaultAdapter.supportedOperators],
    operatorCount: alienvaultAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'threatcrowd',
    displayName: 'ThreatCrowd',
    category: 'threat',
    tier: 1,
    baseUrl: 'https://www.threatcrowd.org',
    apiEndpoint: 'https://www.threatcrowd.org/searchApi/v2',
    docsUrl: 'https://github.com/AlienVault-OTX/ApiV2',
    supportedOperators: [...threatcrowdAdapter.supportedOperators],
    operatorCount: threatcrowdAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },

  // ── Paste / content engines ────────────────────────────────────────────────
  {
    id: 'pastebin',
    displayName: 'Pastebin',
    category: 'paste',
    tier: 1,
    baseUrl: 'https://pastebin.com',
    apiEndpoint: 'https://pastebin.com/api',
    docsUrl: 'https://pastebin.com/doc_api',
    supportedOperators: [...pastebinAdapter.supportedOperators],
    operatorCount: pastebinAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'gist',
    displayName: 'GitHub Gist',
    category: 'paste',
    tier: 1,
    baseUrl: 'https://gist.github.com',
    apiEndpoint: 'https://api.github.com/gists',
    docsUrl: 'https://docs.github.com/en/rest/gists',
    supportedOperators: [...gistAdapter.supportedOperators],
    operatorCount: gistAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'publicwww',
    displayName: 'PublicWWW',
    category: 'paste',
    tier: 1,
    baseUrl: 'https://publicwww.com',
    apiEndpoint: 'https://publicwww.com/websites',
    docsUrl: 'https://publicwww.com/doc/api/',
    supportedOperators: [...publicwwwAdapter.supportedOperators],
    operatorCount: publicwwwAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'grep_io',
    displayName: 'grep.io',
    category: 'paste',
    tier: 1,
    baseUrl: 'https://grep.io',
    docsUrl: 'https://grep.io',
    supportedOperators: [...grepIoAdapter.supportedOperators],
    operatorCount: grepIoAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },

  // ── Social engines ─────────────────────────────────────────────────────────
  {
    id: 'twitter',
    displayName: 'Twitter/X',
    category: 'social',
    tier: 1,
    baseUrl: 'https://twitter.com',
    apiEndpoint: 'https://api.twitter.com/2/tweets/search/recent',
    docsUrl: 'https://developer.twitter.com/en/docs/twitter-api/tweets/search/api-reference',
    supportedOperators: [...twitterAdapter.supportedOperators],
    operatorCount: twitterAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'reddit',
    displayName: 'Reddit',
    category: 'social',
    tier: 1,
    baseUrl: 'https://www.reddit.com',
    apiEndpoint: 'https://www.reddit.com/search.json',
    docsUrl: 'https://www.reddit.com/dev/api/',
    supportedOperators: [...redditAdapter.supportedOperators],
    operatorCount: redditAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'linkedin',
    displayName: 'LinkedIn',
    category: 'social',
    tier: 1,
    baseUrl: 'https://www.linkedin.com',
    docsUrl: 'https://www.linkedin.com/help/linkedin/answer/a524335',
    supportedOperators: [...linkedinAdapter.supportedOperators],
    operatorCount: linkedinAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },

  // ── Academic engines ───────────────────────────────────────────────────────
  {
    id: 'arxiv',
    displayName: 'arXiv',
    category: 'academic',
    tier: 1,
    baseUrl: 'https://arxiv.org',
    apiEndpoint: 'https://export.arxiv.org/api/query',
    docsUrl: 'https://info.arxiv.org/help/api/user-manual.html',
    supportedOperators: [...arxivAdapter.supportedOperators],
    operatorCount: arxivAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'semantic_scholar',
    displayName: 'Semantic Scholar',
    category: 'academic',
    tier: 1,
    baseUrl: 'https://www.semanticscholar.org',
    apiEndpoint: 'https://api.semanticscholar.org/graph/v1/paper/search',
    docsUrl: 'https://api.semanticscholar.org/api-docs/',
    supportedOperators: [...semanticScholarAdapter.supportedOperators],
    operatorCount: semanticScholarAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
  {
    id: 'pubmed',
    displayName: 'PubMed',
    category: 'academic',
    tier: 1,
    baseUrl: 'https://pubmed.ncbi.nlm.nih.gov',
    apiEndpoint: 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi',
    docsUrl: 'https://www.ncbi.nlm.nih.gov/books/NBK25499/',
    supportedOperators: [...pubmedAdapter.supportedOperators],
    operatorCount: pubmedAdapter.operatorCount,
    requiresKey: true,
    rateLimit: { requestsPerMinute: 60 },
  },
];
