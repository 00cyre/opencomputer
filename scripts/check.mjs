import {readFile,readdir,access} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {resolve,dirname,join} from 'node:path';
const root=resolve('.');
async function walk(dir){let all=[];for(const entry of await readdir(dir,{withFileTypes:true})){if(['.git','build','dist','work','node_modules'].includes(entry.name))continue;const path=join(dir,entry.name);if(entry.isDirectory())all.push(...await walk(path));else all.push(path);}return all;}
const files=await walk(root);
for(const file of files){
  if(file.endsWith('.mjs')){const result=spawnSync(process.execPath,['--check',file],{encoding:'utf8'});if(result.status!==0)throw Error(result.stderr);}
  if(file.endsWith('.md')){
    const source=await readFile(file,'utf8');
    for(const match of source.matchAll(/\]\(([^)\s]+)\)/g)){
      const url=match[1];if(/^(https?:|#|mailto:)/.test(url))continue;
      await access(resolve(dirname(file),url.split('#')[0]));
    }
  }
}
const pkg=JSON.parse(await readFile('package.json','utf8'));
for(const path of ['native/main.swift','src/protocol.mjs','bin/opencomputer.mjs']){
  if(!(await readFile(path,'utf8')).includes(pkg.version))throw Error(`Version mismatch: ${path}`);
}
for(const path of ['LICENSE','SECURITY.md','PRIVACY.md','docs/INSTALL.md','docs/DEVELOPMENT.md','docs/TESTING.md','docs/BENCHMARKS.md','docs/assets/hero.svg','docs/assets/download.svg'])await access(path);
console.log(`Checked ${files.length} source files: JavaScript syntax, local Markdown links, release metadata and required docs.`);
