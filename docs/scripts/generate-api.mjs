import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, extname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const docsDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const packageDir = resolve(docsDir, '..');
const sourceFile = join(packageDir, 'src', 'nimgent.nim');
const sourceDir = join(packageDir, 'src');
const outputDir = join(docsDir, 'src', 'content', 'docs', 'reference', 'api');
const extraModules = [
	'src/nimgent/agent.nim',
	'src/nimgent/session.nim',
	'src/nimgent/testing.nim',
	'src/nimgent/providers/google.nim',
	'src/nimgent/providers/mistral.nim',
];

const sectionNames = {
	skConst: 'Constants',
	skIterator: 'Iterators',
	skMacro: 'Macros',
	skMethod: 'Methods',
	skProc: 'Procedures',
	skTemplate: 'Templates',
	skType: 'Types',
	skVar: 'Variables',
};

function walkJsonFiles(directory) {
	const files = [];
	for (const entry of readdirSync(directory, { withFileTypes: true })) {
		const path = join(directory, entry.name);
		if (entry.isDirectory()) files.push(...walkJsonFiles(path));
		else if (extname(entry.name) === '.json' && entry.name !== 'theindex.json') files.push(path);
	}
	return files;
}

function markdownTableCell(value) {
	return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function decodeEntities(value) {
	return String(value ?? '')
		.replaceAll('&amp;', '&')
		.replaceAll('&lt;', '<')
		.replaceAll('&gt;', '>')
		.replaceAll('&quot;', '"')
		.replaceAll('&#39;', "'")
		.replaceAll('&apos;', "'")
		.replaceAll('—', '-');
}

function codeFence(code) {
	const runs = [...String(code ?? '').matchAll(/`+/g)].map((match) => match[0].length);
	const fence = '`'.repeat(Math.max(3, ...(runs.length ? runs.map((run) => run + 1) : [3])));
	return `${fence}nim\n${code}\n${fence}`;
}

function sourceLink(module, line) {
	if (!line) return '';
	const sourcePath = module.orig.startsWith(packageDir)
		? relative(packageDir, module.orig).split(sep).join('/')
		: '';
	if (!sourcePath) return '';
	return `\n[View source](https://github.com/martineastwood/nimgent/blob/main/${sourcePath}#L${line})`;
}

function renderArguments(signature) {
	if (!signature?.arguments?.length) return '';
	const rows = signature.arguments.map((argument) => {
		const type = argument.type || 'inferred';
		const defaultValue = argument.default ? `\`${argument.default}\`` : '';
		return `| \`${markdownTableCell(argument.name)}\` | \`${markdownTableCell(type)}\` | ${defaultValue} |`;
	});
	return [
		'',
		'#### Arguments',
		'',
		'| Name | Type | Default |',
		'| --- | --- | --- |',
		...rows,
	].join('\n');
}

function renderEntry(entry, duplicateNumber, duplicateCount, module) {
	const heading = duplicateCount > 1 ? `${entry.name} (overload ${duplicateNumber})` : entry.name;
	const entryDescription = decodeEntities(entry.description).trim();
	const description = entryDescription ? `\n${entryDescription}\n` : '';
	const genericParams = entry.signature?.genericParams?.length
		? `\nType parameters: ${entry.signature.genericParams.map((param) => `\`${param.name}\``).join(', ')}.\n`
		: '';
	const returnType = entry.signature?.return
		? `\nReturns: \`${entry.signature.return}\`.\n`
		: '';
	return [
		`### ${heading}`,
		description,
		codeFence(decodeEntities(entry.code)),
		genericParams,
		returnType,
		renderArguments(entry.signature),
		sourceLink(module, entry.line),
		'',
	].join('\n');
}

function renderModule(module, moduleName) {
	const sections = new Map();
	for (const entry of module.entries ?? []) {
		const section = sectionNames[entry.type] ?? 'Other';
		if (!sections.has(section)) sections.set(section, []);
		sections.get(section).push(entry);
	}

	const counts = new Map();
	for (const entry of module.entries ?? []) counts.set(entry.name, (counts.get(entry.name) ?? 0) + 1);

	const output = [
		'---',
		`title: ${JSON.stringify(moduleName)}`,
		`description: ${JSON.stringify(`Generated API reference for the ${moduleName} module.`)}`,
		'sidebar:',
		`  label: ${JSON.stringify(basename(moduleName))}`,
		'---',
		'',
		'This page is generated from the module’s exported API and `##` documentation comments.',
	];
	const moduleDescription = decodeEntities(module.moduleDescription).trim();
	if (moduleDescription) output.push('', moduleDescription);

	for (const [section, entries] of sections) {
		output.push('', `## ${section}`, '');
		const seen = new Map();
		for (const entry of entries) {
			const number = (seen.get(entry.name) ?? 0) + 1;
			seen.set(entry.name, number);
			output.push(renderEntry(entry, number, counts.get(entry.name), module));
		}
	}
	return `${output.join('\n').trim()}\n`;
}

function main() {
	const jsonDir = mkdtempSync(join(tmpdir(), 'nimgent-jsondoc-'));
	try {
		execFileSync('nim', [
			'jsondoc',
			'--raw',
			'--project',
			`--outdir:${jsonDir}`,
			sourceFile,
		], { cwd: packageDir, stdio: 'inherit' });
		for (const modulePath of extraModules) {
			const source = join(packageDir, modulePath);
			const moduleDir = mkdtempSync(join(jsonDir, 'module-'));
			execFileSync('nim', [
				'jsondoc',
				'--raw',
				`--outdir:${moduleDir}`,
				source,
			], { cwd: packageDir, stdio: 'inherit' });
			const generatedFile = join(moduleDir, `${basename(source, '.nim')}.json`);
			const targetFile = join(jsonDir, relative(sourceDir, source).replace(/\.nim$/, '.json'));
			mkdirSync(dirname(targetFile), { recursive: true });
			renameSync(generatedFile, targetFile);
		}

		rmSync(outputDir, { recursive: true, force: true });
		mkdirSync(outputDir, { recursive: true });

		for (const jsonFile of walkJsonFiles(jsonDir)) {
			const module = JSON.parse(readFileSync(jsonFile, 'utf8'));
			const moduleName = relative(jsonDir, jsonFile).replace(/\.json$/, '').split(sep).join('/');
			const outputFile = join(outputDir, `${moduleName}.md`);
			mkdirSync(dirname(outputFile), { recursive: true });
			writeFileSync(outputFile, renderModule(module, moduleName));
		}
	} catch (error) {
		if (error.code === 'ENOENT') {
			throw new Error('Could not generate API documentation because Nim is not installed or is not on PATH.');
		}
		if (error.status !== undefined) {
			throw new Error(`Could not generate API documentation with Nim (exit ${error.status}).`);
		}
		throw error;
	} finally {
		rmSync(jsonDir, { recursive: true, force: true });
	}
}

main();
