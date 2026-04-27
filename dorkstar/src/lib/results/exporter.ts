import type { NormalizedResult } from './types';
import Papa from 'papaparse';
import pdfMakeLib from 'pdfmake/build/pdfmake';
import pdfFontsLib from 'pdfmake/build/vfs_fonts';

// Initialize pdfMake with embedded fonts
pdfMakeLib.vfs = pdfFontsLib.vfs ?? pdfFontsLib.pdfMake?.vfs ?? {};

/**
 * Export results to the specified format.
 * Returns a Promise<Blob> for all formats for consistency.
 * All exports are generated client-side — no server transmission.
 */
export async function exportResults(
	results: NormalizedResult[],
	format: 'json' | 'csv' | 'pdf'
): Promise<Blob> {
	switch (format) {
		case 'json':
			return exportJSON(results);
		case 'csv':
			return exportCSV(results);
		case 'pdf':
			return exportPDF(results);
	}
}

function exportJSON(results: NormalizedResult[]): Blob {
	const json = JSON.stringify(results, null, 2);
	return new Blob([json], { type: 'application/json' });
}

function exportCSV(results: NormalizedResult[]): Blob {
	// Flatten results for CSV: one row per result
	// Columns: id, canonicalIdentifier, title, snippet, score, engines (comma-joined engine IDs), firstSeen
	const rows = results.map((r) => ({
		id: r.id,
		canonicalIdentifier: r.canonicalIdentifier,
		title: r.title,
		snippet: r.snippet,
		score: r.score,
		engines: r.engines.map((e) => e.engineId).join(','),
		firstSeen: r.firstSeen
	}));
	const csv = Papa.unparse(rows);
	return new Blob([csv], { type: 'text/csv' });
}

async function exportPDF(results: NormalizedResult[]): Promise<Blob> {
	// Build table body: header row + one row per result
	const tableBody = [
		// Header row
		[
			{ text: '#', bold: true },
			{ text: 'URL / Identifier', bold: true },
			{ text: 'Title', bold: true },
			{ text: 'Engines', bold: true },
			{ text: 'Score', bold: true }
		],
		// Data rows
		...results.map((r, i) => [
			String(i + 1),
			r.canonicalIdentifier,
			r.title || '(no title)',
			r.engines.map((e) => e.engineId).join(', '),
			r.score.toFixed(2)
		])
	];

	const docDefinition = {
		content: [
			{ text: 'DORKSTAR — Search Results', style: 'header' },
			{
				table: {
					headerRows: 1,
					widths: ['auto', '*', '*', 'auto', 'auto'],
					body: tableBody
				},
				layout: 'lightHorizontalLines'
			}
		],
		styles: {
			header: {
				fontSize: 16,
				bold: true,
				margin: [0, 0, 0, 12]
			}
		},
		defaultStyle: {
			fontSize: 9
		}
	};

	return new Promise<Blob>((resolve, reject) => {
		try {
			pdfMakeLib.createPdf(docDefinition).getBuffer((buffer: ArrayBuffer) => {
				resolve(new Blob([buffer], { type: 'application/pdf' }));
			});
		} catch (err) {
			reject(err);
		}
	});
}
