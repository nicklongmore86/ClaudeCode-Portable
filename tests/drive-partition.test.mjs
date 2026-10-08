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

for (const key of ['model','serial']) {
  for (const [label,value] of [['null',null],['blank',' \t\r\n'],['missing',undefined]]) {
    test(`partition helper cleanly refuses ${label} ${key}`,t=>{
      const r=fixture(t,d=>d[key]=value)(['--device','/dev/mockdrive','--dry-run']);
      assert.equal(r.status,1);
      assert.equal(r.stderr.trim(),'Refusing device without both model and serial identity');
      assert.equal(r.stdout,'');
    });
  }
}


test('dry-run prints exact native GPT GUIDs and sets only bit 63 on partitions 3 and 4',t=>{
  const r=fixture(t)(['--device','/dev/mockdrive','--dry-run']);
  assert.equal(r.status,0,r.stderr);
  const commands=r.stdout.split('\n').filter(line=>line.startsWith('sgdisk '));
  assert.deepEqual(commands,[
    'sgdisk --zap-all /dev/mockdrive',
    'sgdisk -n 1:1MiB:+8GiB -t 1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 -c 1:AI-SHARED '+
    '-n 2:0:+39GiB -t 2:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 -c 2:AI-WIN '+
    '-n 3:0:+39GiB -t 3:7C3457EF-0000-11AA-AA11-00306543ECAC -c 3:AI-MAC '+
    '-n 4:0:0 -t 4:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 4:AI-LINUX '+
    '--attributes=3:set:63 --attributes=4:set:63 /dev/mockdrive'
  ]);
  const args=commands[1].split(' ');
  const types=args.flatMap((arg,index)=>arg==='-t'?[args[index+1]]:[]);
  assert.deepEqual(types,[
    '1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7',
    '2:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7',
    '3:7C3457EF-0000-11AA-AA11-00306543ECAC',
    '4:0FC63DAF-8483-4772-8E79-3D69D8477DE4'
  ]);
  assert.deepEqual(args.filter(arg=>arg.startsWith('--attributes=')),['--attributes=3:set:63','--attributes=4:set:63']);
  assert.doesNotMatch(r.stderr,/DESTRUCTIVE-COMMAND/);
});
