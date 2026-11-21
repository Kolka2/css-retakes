#!/usr/bin/env node
// Builds the spawn radar site into _site/ at the repository root.
//   _site/index.html                  - copy of radar/index.html
//   _site/data/<map>/spawns.cfg       - copy of configs/retakes/<map>.cfg
//   _site/data/<map>/radar.<ext>      - copy of radar/maps/<map>/radar.<ext>, if present
//   _site/data/<map>/overview.txt     - copy of radar/maps/<map>/overview.txt, if present
//   _site/maps.json                   - list of the maps for the page
// The configs are only copied, never parsed or checked. A missing radar or overview is
// a warning (an annotation in GitHub Actions), not an error.
// No dependencies: plain Node.js. Run: node radar/build-site.mjs
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PAGE = path.join(ROOT, 'radar', 'index.html');
const CFG_DIR = 'configs/retakes';
const ASSET_DIR = 'radar/maps';
const OUT = path.join(ROOT, '_site');
// The first one found wins.
const RADAR_EXTS = ['png', 'webp', 'jpg', 'jpeg', 'vtf', 'dds'];

const warn = text => console.log('::warning title=radar::' + text);

function git(...args) {
    try {
        return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    } catch (e) {
        return '';
    }
}

// owner/name from https://github.com/owner/name(.git) or git@github.com:owner/name(.git)
function repoFromRemote(url) {
    const m = /github\.com[:/]+([^/]+\/[^/]+?)(?:\.git)?\/?$/i.exec(url || '');
    return m ? m[1] : '';
}

const repo = process.env.GITHUB_REPOSITORY || repoFromRemote(git('remote', 'get-url', 'origin'));
let branch = process.env.GITHUB_REF_NAME || git('rev-parse', '--abbrev-ref', 'HEAD');
if (branch === 'HEAD') branch = ''; // detached HEAD

function copy(srcRel, dstRel) {
    const dst = path.join(OUT, dstRel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(path.join(ROOT, srcRel), dst);
    return dstRel;
}

const isFile = rel => fs.statSync(path.join(ROOT, rel), { throwIfNoEntry: false })?.isFile() === true;

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });
fs.copyFileSync(PAGE, path.join(OUT, 'index.html'));

const cfgFiles = fs.readdirSync(path.join(ROOT, CFG_DIR), { withFileTypes: true })
    .filter(e => e.isFile() && e.name.toLowerCase().endsWith('.cfg'))
    .map(e => e.name)
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

const maps = [];
for (const file of cfgFiles) {
    const map = file.slice(0, -'.cfg'.length);
    const cfgPath = CFG_DIR + '/' + file;
    const entry = { map, cfg: copy(cfgPath, 'data/' + map + '/spawns.cfg'), cfgPath, radar: null, overview: null };

    const ext = RADAR_EXTS.find(x => isFile(ASSET_DIR + '/' + map + '/radar.' + x));
    if (ext) entry.radar = copy(ASSET_DIR + '/' + map + '/radar.' + ext, 'data/' + map + '/radar.' + ext);
    else warn(map + ': no radar image (' + ASSET_DIR + '/' + map + '/radar.{' + RADAR_EXTS.join(',') + '})');

    const ov = ASSET_DIR + '/' + map + '/overview.txt';
    if (isFile(ov)) entry.overview = copy(ov, 'data/' + map + '/overview.txt');
    else warn(map + ': no overview (' + ov + ')');

    maps.push(entry);
}

// Asset folders without a config are not published: most likely a typo in the folder name.
const assetRoot = path.join(ROOT, ASSET_DIR);
if (fs.existsSync(assetRoot)) {
    for (const e of fs.readdirSync(assetRoot, { withFileTypes: true })) {
        if (e.isDirectory() && !maps.some(m => m.map === e.name)) {
            warn(ASSET_DIR + '/' + e.name + ': no ' + CFG_DIR + '/' + e.name + '.cfg, the folder is skipped');
        }
    }
}

const json = { repo, branch, maps };
fs.writeFileSync(path.join(OUT, 'maps.json'), JSON.stringify(json, null, 2) + '\n');
console.log('Built ' + path.relative(ROOT, OUT) + '/ with ' + maps.length + ' map(s)'
    + (repo ? ' for ' + repo + (branch ? '@' + branch : '') : '') + ': '
    + (maps.map(m => m.map).join(', ') || 'none'));
