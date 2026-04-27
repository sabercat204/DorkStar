/**
 * DORKSTAR canonical query parser.
 *
 * Exports:
 *   parseQuery(input)    — parse a canonical query string into an ASTNode tree
 *   validateQuery(input) — thin wrapper returning only the errors array
 *   prettyPrint(node)    — serialize any ASTNode back to a canonical query string
 *
 * Implementation note:
 * The Ohm grammar uses syntactic (uppercase) rules throughout, which causes Ohm
 * to auto-skip whitespace between tokens. This means the grammar cannot correctly
 * parse multi-token constructs like BooleanExpr or ProximityExpr via Ohm semantics
 * alone. We therefore implement a custom tokenizer + recursive-descent parser that
 * respects whitespace boundaries, and use the Ohm grammar only for single-token
 * validation.
 */

import type {
	ASTNode,
	BooleanExpr,
	OperatorExpr,
	ExcludeTerm,
	IncludeTerm,
	ExactPhrase,
	ProximityExpr,
	RangeExpr,
	WildcardPhrase,
	BareWord,
	CanonicalOperator,
	ParseError,
	ParseResult,
	RangeValue,
	WildcardValue
} from './types';

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

type TokenKind =
	| 'QUOTED'       // "..."
	| 'OPERATOR'     // name:value or name:min..max
	| 'RANGE'        // name:min..max
	| 'EXCLUDE'      // -term
	| 'INCLUDE'      // +term
	| 'PROXIMITY'    // word AROUND(n) word
	| 'WILDCARD'     // word containing * or ?
	| 'BOOLEAN_OP'   // AND | OR | NOT
	| 'WORD';        // bare word

interface Token {
	kind: TokenKind;
	raw: string;
	position: number;
}

/**
 * All canonical operator names, sorted longest-first to prevent prefix ambiguity.
 */
const OPERATOR_NAMES: string[] = [
	'services.http.response.html_title',
	'services.port',
	'http.favicon.hash',
	'http.title',
	'http.body',
	'ssl.jarm',
	'ssl.ja3s',
	'allintitle',
	'allinurl',
	'allintext',
	'allinanchor',
	'intitle',
	'inurl',
	'intext',
	'inbody',
	'inanchor',
	'inpage',
	'has_screenshot',
	'is_vulnerability',
	'min_retweets',
	'min_faves',
	'min_replies',
	'minCitationCount',
	'matchType',
	'fieldsOfStudy',
	'hasfeed',
	'hostname',
	'language',
	'location',
	'selftext',
	'subreddit',
	'daterange',
	'protocol',
	'product',
	'version',
	'filetype',
	'filter',
	'flair',
	'classification',
	'collapse',
	'contains',
	'content',
	'country',
	'related',
	'rhost',
	'repo',
	'author',
	'actor',
	'after',
	'before',
	'banner',
	'prefer',
	'labels',
	'limit',
	'source',
	'symbol',
	'since',
	'site',
	'service',
	'cache',
	'city',
	'cidr',
	'cve',
	'define',
	'device',
	'domain',
	'feed',
	'path',
	'port',
	'tags',
	'tag',
	'tech',
	'title',
	'until',
	'venue',
	'vuln',
	'user',
	'url',
	'ver',
	'to',
	'from',
	'fl',
	'ext',
	'app',
	'asn',
	'date',
	'lang',
	'loc',
	'mime',
	'net',
	'org',
	'os',
	'output',
	'ip',
	'jarm',
	'host',
	'self',
];

const OPERATOR_SET = new Set(OPERATOR_NAMES);
const BOOLEAN_KEYWORDS = new Set(['AND', 'OR', 'NOT']);

/**
 * Tokenize a canonical query string into a flat list of tokens.
 * Respects whitespace boundaries — tokens are separated by whitespace.
 */
function tokenize(input: string): Token[] {
	const tokens: Token[] = [];
	let i = 0;

	while (i < input.length) {
		// Skip whitespace
		if (/\s/.test(input[i])) {
			i++;
			continue;
		}

		const start = i;

		// Quoted string: "..."
		if (input[i] === '"') {
			let j = i + 1;
			while (j < input.length && input[j] !== '"') j++;
			const raw = input.slice(i, j + 1); // include closing quote
			tokens.push({ kind: 'QUOTED', raw, position: start });
			i = j + 1;
			continue;
		}

		// Exclude term: -...
		if (input[i] === '-') {
			// Collect the rest of the token (until whitespace)
			let j = i + 1;
			if (j < input.length && input[j] === '"') {
				// -"quoted"
				j++;
				while (j < input.length && input[j] !== '"') j++;
				j++; // include closing quote
			} else {
				while (j < input.length && !/\s/.test(input[j])) j++;
			}
			const raw = input.slice(i, j);
			tokens.push({ kind: 'EXCLUDE', raw, position: start });
			i = j;
			continue;
		}

		// Include term: +...
		if (input[i] === '+') {
			let j = i + 1;
			if (j < input.length && input[j] === '"') {
				j++;
				while (j < input.length && input[j] !== '"') j++;
				j++;
			} else {
				while (j < input.length && !/\s/.test(input[j])) j++;
			}
			const raw = input.slice(i, j);
			tokens.push({ kind: 'INCLUDE', raw, position: start });
			i = j;
			continue;
		}

		// Collect a non-whitespace token
		let j = i;
		if (input[j] === '"') {
			j++;
			while (j < input.length && input[j] !== '"') j++;
			j++;
		} else {
			while (j < input.length && !/\s/.test(input[j])) j++;
		}
		const raw = input.slice(i, j);

		// Classify the token
		if (BOOLEAN_KEYWORDS.has(raw)) {
			tokens.push({ kind: 'BOOLEAN_OP', raw, position: start });
		} else if (/^AROUND\(\d+\)$/.test(raw)) {
			// AROUND(n) — part of proximity, handled at parse level
			tokens.push({ kind: 'WORD', raw, position: start });
		} else if (raw.includes(':')) {
			// Operator expression or range expression
			const colonIdx = raw.indexOf(':');
			const opName = raw.slice(0, colonIdx);
			if (OPERATOR_SET.has(opName)) {
				const valueStr = raw.slice(colonIdx + 1);
				// Check if it's a range: digits..digits
				if (/^\d+\.\.\d+$/.test(valueStr)) {
					tokens.push({ kind: 'RANGE', raw, position: start });
				} else {
					tokens.push({ kind: 'OPERATOR', raw, position: start });
				}
			} else {
				// Not a known operator — treat as bare word
				tokens.push({ kind: 'WORD', raw, position: start });
			}
		} else if (raw.includes('*') || raw.includes('?')) {
			tokens.push({ kind: 'WILDCARD', raw, position: start });
		} else {
			tokens.push({ kind: 'WORD', raw, position: start });
		}

		i = j;
	}

	return tokens;
}

// ---------------------------------------------------------------------------
// Token-based parser
// ---------------------------------------------------------------------------

interface ParseState {
	tokens: Token[];
	pos: number;
	input: string;
}

function peek(state: ParseState): Token | null {
	return state.pos < state.tokens.length ? state.tokens[state.pos] : null;
}

function consume(state: ParseState): Token {
	return state.tokens[state.pos++];
}

/**
 * Parse a single term from the token stream.
 */
function parseTerm(state: ParseState): ASTNode | ParseError {
	const tok = peek(state);
	if (!tok) {
		return { message: 'Unexpected end of input', position: state.input.length, length: 1 };
	}

	// Check for ProximityExpr: WORD AROUND(n) WORD
	if (tok.kind === 'WORD') {
		const next1 = state.tokens[state.pos + 1];
		const next2 = state.tokens[state.pos + 2];
		if (
			next1 &&
			next1.kind === 'WORD' &&
			/^AROUND\(\d+\)$/.test(next1.raw) &&
			next2 &&
			next2.kind === 'WORD'
		) {
			const leftTok = consume(state);
			const aroundTok = consume(state);
			const rightTok = consume(state);
			const distanceMatch = aroundTok.raw.match(/^AROUND\((\d+)\)$/);
			const distance = distanceMatch ? parseInt(distanceMatch[1], 10) : 0;
			return {
				kind: 'ProximityExpr',
				left: { kind: 'BareWord', value: leftTok.raw } as BareWord,
				right: { kind: 'BareWord', value: rightTok.raw } as BareWord,
				distance
			} as ProximityExpr;
		}
	}

	consume(state);

	switch (tok.kind) {
		case 'QUOTED': {
			const phrase = tok.raw.slice(1, tok.raw.length - 1);
			return { kind: 'ExactPhrase', phrase } as ExactPhrase;
		}

		case 'RANGE': {
			const colonIdx = tok.raw.indexOf(':');
			const opName = tok.raw.slice(0, colonIdx) as CanonicalOperator;
			const valueStr = tok.raw.slice(colonIdx + 1);
			const dotdotIdx = valueStr.indexOf('..');
			const minStr = valueStr.slice(0, dotdotIdx);
			const maxStr = valueStr.slice(dotdotIdx + 2);
			const minVal = /^\d+$/.test(minStr) ? parseInt(minStr, 10) : minStr;
			const maxVal = /^\d+$/.test(maxStr) ? parseInt(maxStr, 10) : maxStr;
			return { kind: 'RangeExpr', operator: opName, min: minVal, max: maxVal } as RangeExpr;
		}

		case 'OPERATOR': {
			const colonIdx = tok.raw.indexOf(':');
			const opName = tok.raw.slice(0, colonIdx) as CanonicalOperator;
			let valueStr = tok.raw.slice(colonIdx + 1);
			// Strip surrounding quotes if present
			if (valueStr.startsWith('"') && valueStr.endsWith('"')) {
				valueStr = valueStr.slice(1, valueStr.length - 1);
			}
			// Check if value is a wildcard
			let value: string | RangeValue | WildcardValue;
			if (valueStr.includes('*') || valueStr.includes('?')) {
				value = { pattern: valueStr } as WildcardValue;
			} else {
				value = valueStr;
			}
			return { kind: 'OperatorExpr', operator: opName, value } as OperatorExpr;
		}

		case 'EXCLUDE': {
			const inner = tok.raw.slice(1); // remove leading '-'
			const innerNode = parseTokenString(inner, tok.position + 1);
			if ('message' in innerNode) return innerNode;
			return { kind: 'ExcludeTerm', term: innerNode } as ExcludeTerm;
		}

		case 'INCLUDE': {
			const inner = tok.raw.slice(1); // remove leading '+'
			const innerNode = parseTokenString(inner, tok.position + 1);
			if ('message' in innerNode) return innerNode;
			return { kind: 'IncludeTerm', term: innerNode } as IncludeTerm;
		}

		case 'WILDCARD': {
			return { kind: 'WildcardPhrase', pattern: tok.raw } as WildcardPhrase;
		}

		case 'WORD': {
			return { kind: 'BareWord', value: tok.raw } as BareWord;
		}

		case 'BOOLEAN_OP': {
			// Boolean op appearing as a term — treat as bare word
			return { kind: 'BareWord', value: tok.raw } as BareWord;
		}

		default:
			return { message: `Unexpected token: ${tok.raw}`, position: tok.position, length: tok.raw.length };
	}
}

/**
 * Parse a single token string (used for ExcludeTerm/IncludeTerm inner content).
 */
function parseTokenString(raw: string, basePosition: number): ASTNode | ParseError {
	if (raw.startsWith('"') && raw.endsWith('"')) {
		return { kind: 'ExactPhrase', phrase: raw.slice(1, raw.length - 1) } as ExactPhrase;
	}
	if (raw.includes(':')) {
		const colonIdx = raw.indexOf(':');
		const opName = raw.slice(0, colonIdx);
		if (OPERATOR_SET.has(opName)) {
			const valueStr = raw.slice(colonIdx + 1);
			if (/^\d+\.\.\d+$/.test(valueStr)) {
				const dotdotIdx = valueStr.indexOf('..');
				const minStr = valueStr.slice(0, dotdotIdx);
				const maxStr = valueStr.slice(dotdotIdx + 2);
				const minVal = /^\d+$/.test(minStr) ? parseInt(minStr, 10) : minStr;
				const maxVal = /^\d+$/.test(maxStr) ? parseInt(maxStr, 10) : maxStr;
				return { kind: 'RangeExpr', operator: opName as CanonicalOperator, min: minVal, max: maxVal } as RangeExpr;
			}
			let value: string | RangeValue | WildcardValue;
			const strippedValue = valueStr.startsWith('"') && valueStr.endsWith('"')
				? valueStr.slice(1, valueStr.length - 1)
				: valueStr;
			if (strippedValue.includes('*') || strippedValue.includes('?')) {
				value = { pattern: strippedValue } as WildcardValue;
			} else {
				value = strippedValue;
			}
			return { kind: 'OperatorExpr', operator: opName as CanonicalOperator, value } as OperatorExpr;
		}
	}
	if (raw.includes('*') || raw.includes('?')) {
		return { kind: 'WildcardPhrase', pattern: raw } as WildcardPhrase;
	}
	return { kind: 'BareWord', value: raw } as BareWord;
}

/**
 * Parse a sequence of terms, handling BooleanExpr (AND/OR/NOT).
 * Returns the root ASTNode or a ParseError.
 */
function parseExpression(state: ParseState): ASTNode | ParseError {
	const left = parseTerm(state);
	if ('message' in left) return left;

	const op = peek(state);
	if (op && op.kind === 'BOOLEAN_OP') {
		consume(state); // consume the operator
		const right = parseExpression(state);
		if ('message' in right) return right;
		return {
			kind: 'BooleanExpr',
			op: op.raw as 'AND' | 'OR' | 'NOT',
			left,
			right
		} as BooleanExpr;
	}

	// If there are more terms without a boolean op, chain them with implicit AND
	if (peek(state) && peek(state)!.kind !== 'BOOLEAN_OP') {
		const right = parseExpression(state);
		if ('message' in right) return right;
		return {
			kind: 'BooleanExpr',
			op: 'AND',
			left,
			right
		} as BooleanExpr;
	}

	return left;
}

// ---------------------------------------------------------------------------
// Invariant validation
// ---------------------------------------------------------------------------

function validateInvariants(node: ASTNode, input: string): ParseError[] {
	const errors: ParseError[] = [];
	walkNode(node, errors, input);
	return errors;
}

function walkNode(node: ASTNode, errors: ParseError[], input: string): void {
	switch (node.kind) {
		case 'BooleanExpr': {
			const b = node as BooleanExpr;
			walkNode(b.left, errors, input);
			walkNode(b.right, errors, input);
			break;
		}
		case 'RangeExpr': {
			const r = node as RangeExpr;
			if (typeof r.min === 'number' && typeof r.max === 'number') {
				if (r.min > r.max) {
					errors.push({
						message: `RangeExpr: min (${r.min}) must be ≤ max (${r.max})`,
						position: 0,
						length: input.length
					});
				}
			}
			break;
		}
		case 'ProximityExpr': {
			const p = node as ProximityExpr;
			if (p.distance <= 0) {
				errors.push({
					message: `ProximityExpr: distance must be a positive integer, got ${p.distance}`,
					position: 0,
					length: input.length
				});
			}
			walkNode(p.left, errors, input);
			walkNode(p.right, errors, input);
			break;
		}
		case 'WildcardPhrase': {
			const w = node as WildcardPhrase;
			if (!w.pattern.includes('*') && !w.pattern.includes('?')) {
				errors.push({
					message: `WildcardPhrase: pattern "${w.pattern}" must contain at least one '*' or '?'`,
					position: 0,
					length: input.length
				});
			}
			break;
		}
		case 'ExcludeTerm':
			walkNode((node as ExcludeTerm).term, errors, input);
			break;
		case 'IncludeTerm':
			walkNode((node as IncludeTerm).term, errors, input);
			break;
		case 'OperatorExpr':
		case 'ExactPhrase':
		case 'BareWord':
			break;
	}
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Parse a canonical DORKSTAR query string into a typed ASTNode tree.
 *
 * - Returns `{ ast: null, errors: [] }` for empty / whitespace-only input.
 * - Returns `{ ast: ASTNode, errors: [] }` on success.
 * - Returns `{ ast: null, errors: [...] }` on parse failure.
 * - Never throws.
 */
export function parseQuery(input: string): ParseResult {
	// Empty / whitespace-only input
	if (!input || input.trim() === '') {
		return { ast: null, errors: [] };
	}

	// Skip Ohm grammar validation — the custom tokenizer+parser handles all cases
	// correctly including multi-word queries like "cats filetype:jpg".
	// The Ohm grammar is kept for reference but not used at runtime.

	// Build AST using custom tokenizer + parser
	let ast: ASTNode;
	try {
		const tokens = tokenize(input);
		if (tokens.length === 0) {
			return { ast: null, errors: [] };
		}

		const state: ParseState = { tokens, pos: 0, input };
		const result = parseExpression(state);

		if ('message' in result) {
			return { ast: null, errors: [result as ParseError] };
		}

		// Check for unconsumed tokens
		if (state.pos < state.tokens.length) {
			const remaining = state.tokens[state.pos];
			return {
				ast: null,
				errors: [
					{
						message: `Unexpected token: ${remaining.raw}`,
						position: remaining.position,
						length: remaining.raw.length
					}
				]
			};
		}

		ast = result;
	} catch (err) {
		return {
			ast: null,
			errors: [
				{
					message: err instanceof Error ? err.message : String(err),
					position: 0,
					length: input.length
				}
			]
		};
	}

	// Validate invariants
	const invariantErrors = validateInvariants(ast, input);
	if (invariantErrors.length > 0) {
		return { ast: null, errors: invariantErrors };
	}

	return { ast, errors: [] };
}

/**
 * Validate a canonical query string and return any parse errors.
 * Thin wrapper around `parseQuery`.
 */
export function validateQuery(input: string): ParseError[] {
	return parseQuery(input).errors;
}

/**
 * Serialize any ASTNode back to a canonical query string (Pretty_Printer).
 */
export function prettyPrint(node: ASTNode): string {
	switch (node.kind) {
		case 'BooleanExpr': {
			const b = node as BooleanExpr;
			return `${prettyPrint(b.left)} ${b.op} ${prettyPrint(b.right)}`;
		}

		case 'OperatorExpr': {
			const o = node as OperatorExpr;
			const val = o.value;
			if (typeof val === 'string') {
				return `${o.operator}:${val}`;
			}
			if (
				val !== null &&
				typeof val === 'object' &&
				'min' in val &&
				'max' in val &&
				!('pattern' in val)
			) {
				const rv = val as RangeValue;
				return `${o.operator}:${rv.min}..${rv.max}`;
			}
			if (val !== null && typeof val === 'object' && 'pattern' in val) {
				const wv = val as WildcardValue;
				return `${o.operator}:${wv.pattern}`;
			}
			return `${o.operator}:${String(val)}`;
		}

		case 'ExcludeTerm': {
			const e = node as ExcludeTerm;
			return `-${prettyPrint(e.term)}`;
		}

		case 'IncludeTerm': {
			const i = node as IncludeTerm;
			return `+${prettyPrint(i.term)}`;
		}

		case 'ExactPhrase': {
			const ep = node as ExactPhrase;
			return `"${ep.phrase}"`;
		}

		case 'ProximityExpr': {
			const p = node as ProximityExpr;
			return `${prettyPrint(p.left)} AROUND(${p.distance}) ${prettyPrint(p.right)}`;
		}

		case 'RangeExpr': {
			const r = node as RangeExpr;
			return `${r.operator}:${r.min}..${r.max}`;
		}

		case 'WildcardPhrase': {
			const w = node as WildcardPhrase;
			return w.pattern;
		}

		case 'BareWord': {
			const bw = node as BareWord;
			return bw.value;
		}

		default:
			return '';
	}
}
