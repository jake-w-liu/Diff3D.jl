import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {buildSync, version as esbuildVersion} from 'esbuild';

if (process.argv.length !== 4) throw new Error('usage: browser_build.mjs FIXTURE_JSON OUTPUT_DIRECTORY');
const [fixturePath, output] = process.argv.slice(2);
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
if (fixture.schema !== 1 || !fixture.cases?.length) throw new Error('invalid browser fixture');
const directory = path.dirname(fileURLToPath(import.meta.url));
const result = buildSync({entryPoints: [path.join(directory, 'browser_app.mjs')], bundle: true,
    format: 'iife', minify: true, legalComments: 'inline', write: false, metafile: true});
const script = result.outputFiles[0].text.replaceAll('</script', '<\\/script');
fs.mkdirSync(output, {recursive: true});
for (const scene of fixture.cases) {
    if (!['static', 'instanced', 'dynamic'].includes(scene.mode) || !Number.isInteger(scene.count) || scene.count < 1 ||
        scene.id !== `${scene.mode}-${scene.count}` || scene.centers.length !== 3 * scene.count)
        throw new Error('invalid browser scene');
    const input = JSON.stringify({fixture: {...fixture, cases: undefined}, scene}).replaceAll('<', '\\u003c');
    fs.writeFileSync(path.join(output, `three-${scene.id}.html`),
        `<!doctype html><html><head><meta charset="utf-8"><title>Matched triangles</title></head><body>` +
        `<script>window.__benchmarkInput=${input};</script><script>${script}</script></body></html>\n`);
    console.log(`BROWSER_FIXTURE_OK three ${scene.id}`);
}
const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'node_modules/three/package.json'), 'utf8'));
fs.writeFileSync(path.join(output, 'three-build.json'), JSON.stringify({node: process.version,
    three: pkg.version, esbuild: esbuildVersion, fixture_sha256: createHash('sha256').update(fs.readFileSync(fixturePath)).digest('hex'),
    bundle_bytes: result.outputFiles[0].contents.length, inputs: result.metafile.inputs}, null, 2) + '\n');
