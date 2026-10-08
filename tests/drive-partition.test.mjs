import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { resolve,join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root=resolve('.');
function fixture(t, change=()=>{}, swap='') {
  const dir=mkdtempSync(join(root,'.partition-test-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const disk={path:'/dev/mockdrive',type:'disk',size:128*1024**3,model:'Test SSD',serial:'MOCK123',mountpoints:[null],ro:false,children:[]};change(disk);
  const data=JSON.stringify({blockdevices:[disk,{path:'/dev/system',type:'disk',children:[{path:'/dev/system1',type:'part',mountpoints:['/']}]}]});
  const quote=s=>`'${s.replaceAll("'","'\\''")}'`;
  writeFileSync(join(dir,'lsblk'),`#!/bin/sh\nprintf '%s' ${quote(data)}\n`,{mode:0o755});
  writeFileSync(join(dir,'findmnt'), '#!/bin/sh\nprintf /dev/system1\n',{mode:0o755});
  writeFileSync(join(dir,'swapon'),`#!/bin/sh\nprintf '%s' ${quote(swap)}\n`,{mode:0o755});
  // Any accidental destructive command fails and is recorded as a test failure.
  for(const command of ['sgdisk','partprobe','udevadm','mkfs.exfat','mkfs.ntfs','mkfs.ext4'])writeFileSync(join(dir,command),'#!/bin/sh\necho DESTRUCTIVE-COMMAND >&2\nexit 99\n',{mode:0o755});
  return args=>spawnSync('sh',['provision/partition-linux.sh',...args],{cwd:root,env:{...process.env,PATH:`${dir}:${process.env.PATH}`},encoding:'utf8'});
}
test('dry-run shows GPT labels, native filesystems and APFS placeholder without commands',t=>{
  const r=fixture(t)(['--device','/dev/mockdrive','--dry-run']);assert.equal(r.status,0,r.stderr);
  for(const label of ['AI-SHARED','AI-WIN','AI-MAC','AI-LINUX'])assert.ok(r.stdout.includes(label));
  assert.match(r.stdout,/DRY RUN/);assert.doesNotMatch(r.stderr,/DESTRUCTIVE/);assert.doesNotMatch(r.stdout,/mkfs.apfs/);
});
test('partition helper requires an explicit device',t=>{const r=fixture(t)(['--dry-run']);assert.notEqual(r.status,0);assert.match(r.stderr,/--device/);});
for(const [name,change,swap] of [
  ['root mounted',d=>d.children.push({path:'/dev/mockdrive1',type:'part',mountpoints:['/']}),''],
  ['LVM root',d=>d.children.push({path:'/dev/mockdrive1',type:'part',children:[{path:'/dev/mapper/root',type:'lvm',mountpoints:['/']}]}),''],
  ['read-only',d=>d.ro=true,''],['partition',d=>d.type='part',''],
  ['unknown identity',d=>d.serial='',''],['small disk',d=>d.size=10,''],
  ['swap',()=>{},'/dev/mockdrive1']]) {
  test(`partition safety rejects ${name} even in dry-run`,t=>{
    const r=fixture(t,change,swap)(['--device','/dev/mockdrive','--dry-run']);assert.notEqual(r.status,0);assert.doesNotMatch(r.stderr,/DESTRUCTIVE/);
  });
}

test('partition helper refuses the physical ancestor of the system root',t=>{
  const r=fixture(t)(['--device','/dev/system','--dry-run']);
  assert.notEqual(r.status,0);assert.match(r.stderr,/Refusing system disk/);
});
