import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
test('provisioner verification and archive layout (six Python test functions)',()=>{
  const result=spawnSync('python3',['-m','unittest','discover','-s','tests','-p','drive_provision_test.py','-v'],{encoding:'utf8',env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'}});
  assert.equal(result.status,0,result.stdout+result.stderr);
});
