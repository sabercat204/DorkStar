// Type declarations for modules without bundled TypeScript types

declare module 'papaparse' {
	interface UnparseConfig {
		quotes?: boolean | boolean[];
		quoteChar?: string;
		escapeChar?: string;
		delimiter?: string;
		header?: boolean;
		newline?: string;
		skipEmptyLines?: boolean | 'greedy';
		columns?: string[];
	}

	function unparse(data: object[] | string[][], config?: UnparseConfig): string;

	export { unparse };
	export default { unparse };
}

declare module 'pdfmake/build/pdfmake' {
	interface TDocumentDefinitions {
		content: unknown[];
		styles?: Record<string, unknown>;
		defaultStyle?: Record<string, unknown>;
		[key: string]: unknown;
	}

	interface TCreatedPdf {
		getBuffer(cb: (buffer: ArrayBuffer) => void): void;
		getBlob(cb: (blob: Blob) => void): void;
		download(filename?: string): void;
		open(): void;
	}

	interface PdfMakeStatic {
		vfs: Record<string, string>;
		createPdf(documentDefinition: TDocumentDefinitions): TCreatedPdf;
	}

	const pdfMake: PdfMakeStatic;
	export default pdfMake;
}

declare module 'pdfmake/build/vfs_fonts' {
	interface VfsFonts {
		pdfMake: {
			vfs: Record<string, string>;
		};
		vfs?: Record<string, string>;
	}
	const vfsFonts: VfsFonts;
	export default vfsFonts;
}
