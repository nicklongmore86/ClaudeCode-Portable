import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
const available=spawnSync('pwsh',['-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()'],{encoding:'utf8'}).status===0;
test('PowerShell parse, environment, discovery and C# compile', {skip: !available && 'pwsh is not installed'},()=>{
  const r=spawnSync('pwsh',['-NoProfile','-Command',"& ./tests/drive-windows.ps1"],{encoding:'utf8'});
  assert.equal(r.status,0,r.stdout+r.stderr);
});
