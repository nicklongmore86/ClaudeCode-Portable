import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const temp=mkdtempSync(join(tmpdir(),'portable-native-'));
process.env.PORTABLE_AI_DATA_DIR=join(temp,'data');
const { executableAt, manifest, installRuntime }=await import('../lib/runtime.mjs');
test.after(()=>rmSync(temp,{recursive:true,force:true}));
test('Claude engine is never an npm dependency',()=>{
  assert.equal(manifest.dependencies['@anthropic-ai/claude-code'],undefined);
  assert.ok(manifest.dependencies['@anthropic-ai/claude-agent-sdk']);
});
test('runtime uses explicitly provisioned native executable and rejects missing paths',()=>{
  process.env.PORTABLE_AI_CLAUDE_EXECUTABLE=join(temp,'claude');
  assert.equal(executableAt(),null);
  writeFileSync(process.env.PORTABLE_AI_CLAUDE_EXECUTABLE,'NATIVE');
  assert.equal(executableAt(),process.env.PORTABLE_AI_CLAUDE_EXECUTABLE);
  delete process.env.PORTABLE_AI_CLAUDE_EXECUTABLE;
  assert.equal(executableAt(),null);
});
test('dashboard install rejects incomplete dependencies and preserves prior runtime',async()=>{
  const target=join(temp,'dashboard/current');mkdirSync(target,{recursive:true});writeFileSync(join(target,'keep'),'working');
  await assert.rejects(installRuntime({target,runner:async()=>''}),/dependencies are incomplete/);
  assert.equal(readFileSync(join(target,'keep'),'utf8'),'working');
});
