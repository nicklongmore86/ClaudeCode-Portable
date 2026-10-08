import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,readdirSync,rmSync,symlinkSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
const root=resolve('.');
function fixture(t){
  const dir=mkdtempSync(join(root,'.drive-test-audit-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const actual=join(dir,'private-tmp'), link=join(dir,'tmp'), outputDir=join(dir,'drive'), mocks=join(dir,'mocks');
  for(const p of [actual,outputDir,mocks])mkdirSync(p);
  symlinkSync(actual,link);writeFileSync(join(actual,'changed'),'do not copy this content');
  const output=join(outputDir,'snapshot');
  const env={...process.env,HOME:dir,PATH:`${mocks}:${process.env.PATH}`,TMPDIR:'/not-a-drive',TEMP:'/not-a-drive',TMP:'/not-a-drive'};
  const run=()=>spawnSync('sh',['tools/audit/audit.sh','snapshot',output,link],{encoding:'utf8',env});
  return {dir,actual,link,outputDir,mocks,output,env,run};
}
test('audit follows symlinked roots but not nested symlinks',t=>{
  const f=fixture(t), other=join(f.dir,'elsewhere');mkdirSync(other);writeFileSync(join(other,'excluded'),'x');symlinkSync(other,join(f.actual,'nested'));
  const r=f.run();assert.equal(r.status,0,r.stderr);
  const report=readFileSync(f.output,'utf8');assert.match(report,/\/tmp\/changed\|24\|/);
  assert.doesNotMatch(report,/excluded|do not copy this content/);
  assert.deepEqual(readdirSync(f.outputDir),['snapshot']);
});
for(const outcome of ['success','failure','signal']){
  test(`audit sort scratch is on drive and cleaned after ${outcome}`,t=>{
    const f=fixture(t);
    writeFileSync(join(f.mocks,'sort'),`#!/bin/sh\n[ "$1" = -T ] && [ "$2" = "$TMPDIR" ] && [ "$TEMP" = "$TMPDIR" ] && [ "$TMP" = "$TMPDIR" ] || exit 90\ncase "$TMPDIR" in "$EXPECTED_DIR"/.audit-scratch.*) ;; *) exit 91;; esac\nprintf spill > "$TMPDIR/spill"\n${outcome==='signal'?'kill -TERM "$PPID"; exit 42':outcome==='failure'?'exit 42':'cat "$4"'}\n`,{mode:0o755});
    f.env.EXPECTED_DIR=f.outputDir;
    writeFileSync(f.output,'prior snapshot');
    const r=f.run();assert.equal(r.status,outcome==='signal'?143:outcome==='failure'?42:0,r.stderr);
    assert.deepEqual(readdirSync(f.outputDir),['snapshot']);
    if(outcome!=='success')assert.equal(readFileSync(f.output,'utf8'),'prior snapshot');
  });
}
