/**
 * AST node kind discriminant union.
 */
export type NodeKind =
  | 'BooleanExpr'
  | 'OperatorExpr'
  | 'ExcludeTerm'
  | 'IncludeTerm'
  | 'ExactPhrase'
  | 'ProximityExpr'
  | 'RangeExpr'
  | 'WildcardPhrase'
  | 'BareWord';

/**
 * Base interface for all AST nodes.
 */
export interface ASTNode {
  kind: NodeKind;
}

/**
 * Boolean expression node (AND / OR / NOT).
 */
export interface BooleanExpr extends ASTNode {
  kind: 'BooleanExpr';
  op: 'AND' | 'OR' | 'NOT';
  left: ASTNode;
  right: ASTNode;
}

/**
 * Operator expression node, e.g. `site:example.com` or `port:443`.
 */
export interface OperatorExpr extends ASTNode {
  kind: 'OperatorExpr';
  operator: CanonicalOperator;
  value: string | RangeValue | WildcardValue;
}

/**
 * Exclude term node, e.g. `-keyword` or `-site:example.com`.
 */
export interface ExcludeTerm extends ASTNode {
  kind: 'ExcludeTerm';
  term: ASTNode;
}

/**
 * Include term node, e.g. `+keyword`.
 */
export interface IncludeTerm extends ASTNode {
  kind: 'IncludeTerm';
  term: ASTNode;
}

/**
 * Exact phrase node, e.g. `"hello world"`.
 */
export interface ExactPhrase extends ASTNode {
  kind: 'ExactPhrase';
  phrase: string;
}

/**
 * Proximity expression node, e.g. `"foo bar"~5` (NEAR/n).
 * `distance` must be a positive integer.
 */
export interface ProximityExpr extends ASTNode {
  kind: 'ProximityExpr';
  left: ASTNode;
  right: ASTNode;
  distance: number;
}

/**
 * Range expression node, e.g. `port:80..443`.
 * `min` must be ≤ `max` when both are numeric.
 */
export interface RangeExpr extends ASTNode {
  kind: 'RangeExpr';
  operator: CanonicalOperator;
  min: number | string;
  max: number | string;
}

/**
 * Wildcard phrase node, e.g. `admin*` or `pass?ord`.
 * `pattern` must contain at least one `*` or `?` character.
 */
export interface WildcardPhrase extends ASTNode {
  kind: 'WildcardPhrase';
  pattern: string;
}

/**
 * Bare word node — an unquoted, undecorated keyword token.
 */
export interface BareWord extends ASTNode {
  kind: 'BareWord';
  value: string;
}

/**
 * Mapping from each NodeKind to its concrete interface.
 */
export type ASTNodeMap = {
  BooleanExpr: BooleanExpr;
  OperatorExpr: OperatorExpr;
  ExcludeTerm: ExcludeTerm;
  IncludeTerm: IncludeTerm;
  ExactPhrase: ExactPhrase;
  ProximityExpr: ProximityExpr;
  RangeExpr: RangeExpr;
  WildcardPhrase: WildcardPhrase;
  BareWord: BareWord;
};

/**
 * All canonical search operators supported by the DORKSTAR query language.
 */
export type CanonicalOperator =
  // Web / content operators
  | 'site'
  | 'filetype'
  | 'ext'
  | 'intitle'
  | 'allintitle'
  | 'inurl'
  | 'allinurl'
  | 'intext'
  | 'allintext'
  | 'inbody'
  | 'inanchor'
  | 'allinanchor'
  | 'inpage'
  // Network / IoT operators
  | 'ip'
  | 'port'
  | 'hostname'
  | 'org'
  | 'asn'
  | 'net'
  | 'country'
  | 'city'
  | 'os'
  | 'product'
  | 'version'
  | 'vuln'
  | 'ssl.jarm'
  | 'ssl.ja3s'
  | 'http.favicon.hash'
  | 'has_screenshot'
  | 'mime'
  | 'url'
  | 'rhost'
  | 'host'
  | 'domain'
  // Language / locale operators
  | 'lang'
  | 'language'
  | 'loc'
  | 'location'
  // Web graph operators
  | 'related'
  | 'cache'
  | 'define'
  // Content / feed operators
  | 'source'
  | 'feed'
  | 'hasfeed'
  | 'contains'
  | 'prefer'
  // Code search operators
  | 'repo'
  | 'user'
  | 'path'
  | 'content'
  | 'symbol'
  // Social operators
  | 'author'
  | 'subreddit'
  | 'flair'
  | 'self'
  | 'selftext'
  | 'title'
  | 'from'
  | 'to'
  | 'filter'
  | 'since'
  | 'until'
  | 'min_retweets'
  | 'min_faves'
  | 'min_replies'
  // Date operators
  | 'before'
  | 'after'
  | 'daterange'
  | 'date'
  // Threat intelligence operators
  | 'classification'
  | 'actor'
  | 'tags'
  | 'cve'
  | 'labels'
  // Censys / services operators
  | 'services.port'
  | 'services.http.response.html_title'
  // IoT / device operators
  | 'app'
  | 'ver'
  | 'device'
  | 'cidr'
  | 'banner'
  | 'service'
  | 'protocol'
  | 'jarm'
  | 'http.title'
  | 'http.body'
  | 'is_vulnerability'
  | 'tag'
  | 'tech'
  // Academic operators
  | 'fieldsOfStudy'
  | 'venue'
  | 'minCitationCount'
  | 'matchType'
  // Solr / search API operators
  | 'output'
  | 'fl'
  | 'limit'
  | 'collapse';

/**
 * Runtime-accessible array of all canonical operator values.
 * Useful for validation, autocomplete, and coverage checks.
 */
export const ALL_CANONICAL_OPERATORS: readonly CanonicalOperator[] = [
  'site',
  'filetype',
  'ext',
  'intitle',
  'allintitle',
  'inurl',
  'allinurl',
  'intext',
  'allintext',
  'inbody',
  'inanchor',
  'allinanchor',
  'inpage',
  'ip',
  'port',
  'hostname',
  'org',
  'asn',
  'net',
  'country',
  'city',
  'os',
  'product',
  'version',
  'vuln',
  'ssl.jarm',
  'ssl.ja3s',
  'http.favicon.hash',
  'has_screenshot',
  'mime',
  'url',
  'rhost',
  'host',
  'domain',
  'lang',
  'language',
  'loc',
  'location',
  'related',
  'cache',
  'define',
  'source',
  'feed',
  'hasfeed',
  'contains',
  'prefer',
  'repo',
  'user',
  'path',
  'content',
  'symbol',
  'author',
  'subreddit',
  'flair',
  'self',
  'selftext',
  'title',
  'from',
  'to',
  'filter',
  'since',
  'until',
  'min_retweets',
  'min_faves',
  'min_replies',
  'before',
  'after',
  'daterange',
  'date',
  'classification',
  'actor',
  'tags',
  'cve',
  'labels',
  'services.port',
  'services.http.response.html_title',
  'app',
  'ver',
  'device',
  'cidr',
  'banner',
  'service',
  'protocol',
  'jarm',
  'http.title',
  'http.body',
  'is_vulnerability',
  'tag',
  'tech',
  'fieldsOfStudy',
  'venue',
  'minCitationCount',
  'matchType',
  'output',
  'fl',
  'limit',
  'collapse',
] as const;

/**
 * Range value used in `OperatorExpr` when the operator accepts a numeric or string range.
 */
export interface RangeValue {
  min: number | string;
  max: number | string;
}

/**
 * Wildcard value used in `OperatorExpr` when the operator value contains glob characters.
 */
export interface WildcardValue {
  pattern: string;
}

/**
 * A single parse error with position and length information.
 */
export interface ParseError {
  message: string;
  /** Zero-based character index in the input string where the error begins. */
  position: number;
  /** Number of characters the error spans. */
  length: number;
}

/**
 * The result returned by `parseQuery()`.
 * `ast` is `null` when the input is empty or unparseable.
 * `errors` is empty on a successful parse.
 */
export interface ParseResult {
  ast: ASTNode | null;
  errors: ParseError[];
}
