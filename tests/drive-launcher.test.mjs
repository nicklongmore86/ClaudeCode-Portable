import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, existsSync, rmSync, utimesSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync, spawn } from 'node:child_process';
const root = resolve('.');
const quote = s => `'${s.replaceAll("'", "'\\''")}'`;
function fixture(t) {
  const dir = mkdtempSync(join(root, '.drive-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const shared = join(dir, 'AI SHARED'), native = join(dir, 'native space'), mocks = join(dir, 'mock');
  for (const p of [shared, mocks, join(native,'tmp'), join(native, 'bin/linux-x64/codex/bin')]) mkdirSync(p, { recursive: true });
  const env = { ...process.env, PATH: `${mocks}:${process.env.PATH}`, MOCK_NATIVE: native, TMPDIR: join(native,'tmp') };
  const run = (body, extra = {}) => spawnSync('bash', ['-c', `. ${quote(join(root, 'launch/lib/drive.sh'))}; . ${quote(join(root, 'launch/lib/session.sh'))}; ${body}`], { env, encoding: 'utf8', ...extra });
  const setup = `drive_environment ${quote(shared)} ${quote(native)} linux-x64 || exit;`;
  const mock = (name, body) => writeFileSync(join(mocks, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return { dir, shared, native, mocks, env, run, setup, mock };
}
test('environment is local to subshell, credentials cleared, paths and cwd preserved', t => {
  const f = fixture(t);
  f.env.ANTHROPIC_API_KEY = 'host-secret'; f.env.OPENAI_BASE_URL = 'host-url';
  mkdirSync(join(f.shared, 'credentials'));
  writeFileSync(join(f.shared, 'credentials/claude-oauth-token'), 'fake-token\n');
  const r = f.run(`(${f.setup} [ -z "\${ANTHROPIC_API_KEY+x}" ] && [ -z "\${OPENAI_BASE_URL+x}" ] || exit 2; [ "$CLAUDE_CODE_OAUTH_TOKEN" = fake-token ] || exit 3; printf '%s\\n' "$CODEX_HOME" "$CODEX_SQLITE_HOME" "$HOME" "$PWD" "$DISABLE_UPDATES"); [ "$ANTHROPIC_API_KEY" = host-secret ] || exit 4;`, { cwd: f.dir });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.stdout.trim().split('\n'), [join(f.native,'state/codex'),join(f.native,'state/codex'),join(f.native,'state/home'),f.dir,'1']);
  assert.ok(!r.stdout.includes('fake-token'));
});
test('discovery uses label, handles spaces, mounts with udisks and refuses missing/ambiguous mounts', t => {
  const f = fixture(t);
  f.mock('findmnt', '[ "$3" = /dev/disk/by-label/AI-LINUX ] || exit 8; printf "%s\\n" "$MOCK_NATIVE"');
  assert.equal(f.run('drive_discover linux').stdout.trim(), f.native);
  f.mock('findmnt', `[ -f ${quote(join(f.dir,'mounted'))} ] && printf '%s\\n' "$MOCK_NATIVE"`);
  f.mock('udisksctl', `touch ${quote(join(f.dir,'mounted'))}`);
  assert.equal(f.run('drive_discover linux').stdout.trim(), f.native);
  f.mock('findmnt', 'exit 1'); f.mock('udisksctl', 'exit 1');
  let r = f.run('drive_discover linux'); assert.notEqual(r.status,0); assert.match(r.stderr,/udisksctl mount -b/);
  f.mock('findmnt', 'printf "/one\\n/two\\n"');
  r = f.run('drive_discover linux'); assert.notEqual(r.status,0); assert.match(r.stderr,/Multiple/);
});
test('auth sync is authoritative, only copies newer auth back, lock excludes sessions', t => {
  const f = fixture(t), auth = join(f.shared,'credentials/codex-auth.json');
  mkdirSync(join(f.shared,'credentials')); writeFileSync(auth,'shared');
  let r = f.run(`${f.setup} drive_lock && drive_auth_in && drive_codex_config`);
  assert.equal(r.status,0,r.stderr);
  assert.equal(readFileSync(join(f.native,'state/codex/auth.json'),'utf8'),'shared');
  r=f.run(`${f.setup} drive_lock`); assert.notEqual(r.status,0); assert.match(r.stderr,/locked/);
  const local=join(f.native,'state/codex/auth.json'); writeFileSync(local,'old'); utimesSync(local,1,1);
  r=f.run(`${f.setup} drive_lock_path=${quote(join(f.shared,'credentials/codex-auth.lock'))}; drive_auth_out`);
  assert.equal(r.status,0,r.stderr); assert.equal(readFileSync(auth,'utf8'),'shared');
  writeFileSync(local,'refreshed'); const future=Date.now()/1000+3;utimesSync(local,future,future);
  r=f.run(`${f.setup} drive_lock_path=${quote(join(f.shared,'credentials/codex-auth.lock'))}; drive_auth_out && drive_unlock`);
  assert.equal(r.status,0,r.stderr);assert.equal(readFileSync(auth,'utf8'),'refreshed');
  assert.ok(!existsSync(join(f.shared,'credentials/codex-auth.lock')));
  rmSync(auth); r=f.run(`${f.setup} drive_auth_in`); assert.equal(r.status,0);assert.ok(!existsSync(local));
  const config=readFileSync(join(f.native,'state/codex/config.toml'),'utf8');
  assert.match(config,/cli_auth_credentials_store = "file"/);assert.match(config,/check_for_update_on_startup = false/);assert.match(config,/\[analytics\]\nenabled = false/);assert.match(config,/\[feedback\]\nenabled = false/);
});
test('Codex gets no-daemon, extra args, child exit status, sync and unlock', t => {
  const f=fixture(t);
  writeFileSync(join(f.native,'bin/linux-x64/codex/bin/codex'), '#!/bin/sh\nprintf "%s\\n" "$@"\nprintf refreshed > "$CODEX_HOME/auth.json"\nexit 7\n',{mode:0o755});
  const r=f.run(`${f.setup} drive_codex exec 'space argument'`);
  assert.equal(r.status,7,r.stderr); assert.deepEqual(r.stdout.trim().split('\n'),['--no-daemon','exec','space argument']);
  assert.equal(readFileSync(join(f.shared,'credentials/codex-auth.json'),'utf8'),'refreshed');
  assert.ok(!existsSync(join(f.shared,'credentials/codex-auth.lock')));
});
test('session cleanup kills a background descendant after command exits', async t => {
  const f=fixture(t), pidFile=join(f.dir,'pid');
  const script=join(f.dir,'child'); writeFileSync(script,`#!/bin/sh\nsleep 60 &\nprintf '%s' "$!" > ${quote(pidFile)}\n`,{mode:0o755});
  const r=f.run(`drive_run ${quote(script)}`); assert.equal(r.status,0,r.stderr);
  const pid=Number(readFileSync(pidFile,'utf8'));
  const ps=spawnSync('ps',['-o','stat=','-p',String(pid)],{encoding:'utf8'});
  assert.ok(ps.status!==0 || ps.stdout.trim().startsWith('Z'),`descendant ${pid} still running: ${ps.stdout}`);
});
test('macOS discovery uses diskutil label fallback and architecture selection rejects unknown CPU',t=>{
  const f=fixture(t);
  f.mock('diskutil',`[ "$1 $2" = 'info AI-MAC' ] || exit 7; printf '   Mount Point: %s\\n' "$MOCK_NATIVE"`);
  // The fallback is exercised on Linux where /Volumes/AI-MAC does not exist.
  assert.equal(f.run('drive_discover darwin').stdout.trim(),f.native);
  f.mock('uname','printf aarch64');assert.equal(f.run('drive_arch').stdout.trim(),'arm64');
  f.mock('uname','printf riscv64');assert.notEqual(f.run('drive_arch').status,0);
});
test('failed auth import does not copy stale native credentials back',t=>{
  const f=fixture(t);mkdirSync(join(f.shared,'credentials'));writeFileSync(join(f.shared,'credentials/codex-auth.json'),'authoritative');
  const r=f.run(`${f.setup} printf stale > "$CODEX_HOME/auth.json"; drive_auth_in() { return 1; }; drive_codex`);
  assert.equal(r.status,1,r.stderr);
  assert.equal(readFileSync(join(f.shared,'credentials/codex-auth.json'),'utf8'),'authoritative');
  assert.ok(!existsSync(join(f.shared,'credentials/codex-auth.lock')));
});
test('SIGTERM to session supervisor cleans child process group',async t=>{
  const f=fixture(t), pidFile=join(f.dir,'signal-pid');
  const script=join(f.dir,'long-child');writeFileSync(script,`#!/bin/sh\nprintf '%s' "$$" > ${quote(pidFile)}\nsleep 60\n`,{mode:0o755});
  const proc=spawn('bash',['-c',`. ${quote(join(root,'launch/lib/session.sh'))}; drive_run ${quote(script)}`],{stdio:'ignore',env:f.env});
  t.after(()=>{try{proc.kill('SIGKILL');}catch{}});
  for(let i=0;i<100&&!existsSync(pidFile);i++)await new Promise(r=>setTimeout(r,10));
  assert.ok(existsSync(pidFile),'child started');
  const childPid=Number(readFileSync(pidFile,'utf8'));
  t.after(()=>{try{process.kill(-childPid,'SIGKILL');}catch{}});
  proc.kill('SIGTERM');
  await new Promise(r=>setTimeout(r,1500));
  const ps=spawnSync('ps',['-o','stat=','-p',String(childPid)],{encoding:'utf8'});
  assert.ok(ps.status!==0||ps.stdout.trim().startsWith('Z'),`child survived SIGTERM: ${ps.stdout}`);
});

test('Linux mount discovery decodes findmnt hex-escaped spaces',t=>{
  const f=fixture(t);
  f.mock('findmnt',"printf '%s\\n' '/media/AI\\x20LINUX'");
  assert.equal(f.run('drive_discover linux').stdout.trim(),'/media/AI LINUX');
});
test('interactive child can read its terminal under the process supervisor',t=>{
  const f=fixture(t), child=join(f.dir,'interactive-child');
  writeFileSync(child,'#!/bin/sh\nread -r value\nprintf "RECEIVED:%s\\n" "$value"\n',{mode:0o755});
  const python=`
import os, pty, select, time, signal
pid, fd = pty.fork()
if pid == 0:
    os.execvp('bash', ['bash', '-c', '. "$1"; drive_run "$2"', 'test', ${JSON.stringify(join(root,'launch/lib/session.sh'))}, ${JSON.stringify(child)}])
output=b''
try:
    os.write(fd,b'hello-terminal\\n')
    end=time.time()+8
    while time.time()<end:
        ready,_,_=select.select([fd],[],[],0.1)
        if ready:
            try: chunk=os.read(fd,4096)
            except OSError: break
            if not chunk: break
            output+=chunk
        done,status=os.waitpid(pid,os.WNOHANG)
        if done: break
    assert b'RECEIVED:hello-terminal' in output, repr(output)
finally:
    try: os.kill(pid,signal.SIGKILL)
    except ProcessLookupError: pass
    os.close(fd)
`;
  const r=spawnSync('python3',['-c',python],{encoding:'utf8',env:f.env,timeout:10000});
  assert.equal(r.status,0,r.stdout+r.stderr);
});

test('Linux entrypoint resolves shared volume from itself and preserves project cwd/args',t=>{
  const f=fixture(t);
  cpSync(join(root,'launch'),join(f.shared,'launch'),{recursive:true});
  f.mock('findmnt','printf "%s\\n" "$MOCK_NATIVE"');f.mock('uname','printf x86_64');
  writeFileSync(join(f.native,'bin/linux-x64/claude'),'#!/bin/sh\n[ -z "${OPENAI_API_KEY+x}" ] || exit 8\npwd\nprintf "%s\\n" "$@" "$CLAUDE_CONFIG_DIR"\n',{mode:0o755});
  const r=spawnSync('bash',[join(f.shared,'launch/linux.sh'),'claude','--resume','space argument'],{cwd:f.dir,env:{...f.env,OPENAI_API_KEY:'fake-host-key'},encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);
  assert.deepEqual(r.stdout.trim().split('\n'),[f.dir,'--resume','space argument',join(f.native,'state/claude')]);
});

for (const entry of ['linux.sh','macos.command']) {
  test(`${entry} removes CR/LF from stored token without printing it`,t=>{
    const f=fixture(t), token='fake-private-token';
    cpSync(join(root,'launch'),join(f.shared,'launch'),{recursive:true});
    mkdirSync(join(f.shared,'credentials'));
    writeFileSync(join(f.shared,'credentials/claude-oauth-token'),`${token}\r\n\r\n`);
    f.mock('findmnt','printf "%s\\n" "$MOCK_NATIVE"');f.mock('uname','printf x86_64');
    f.mock('diskutil','printf "   Mount Point: %s\\n" "$MOCK_NATIVE"');
    const target=entry==='linux.sh'?'linux-x64':'darwin-x64';
    mkdirSync(join(f.native,`bin/${target}`),{recursive:true});
    writeFileSync(join(f.native,`bin/${target}/claude`),`#!/bin/sh\n[ "$CLAUDE_CODE_OAUTH_TOKEN" = '${token}' ]\n`,{mode:0o755});
    const r=spawnSync('bash',[join(f.shared,'launch',entry),'claude'],{env:f.env,encoding:'utf8'});
    assert.equal(r.status,0,r.stderr);assert.ok(!(r.stdout+r.stderr).includes(token));
  });
}
test('Claude paste strips CR/LF before saving and rejects newline-only input',t=>{
  const f=fixture(t);
  let r=f.run(`${f.setup} drive_run() { :; }; drive_login`,{input:'1\nfake-private-token\r\n'});
  assert.equal(r.status,0,r.stderr);
  const path=join(f.shared,'credentials/claude-oauth-token');
  assert.equal(readFileSync(path,'utf8'),'fake-private-token');
  assert.ok(!(r.stdout+r.stderr).includes('fake-private-token'));
  r=f.run(`${f.setup} drive_run() { :; }; drive_login`,{input:'1\n\r\n'});
  assert.equal(r.status,1);assert.equal(readFileSync(path,'utf8'),'fake-private-token');
});
for (const aliveSteps of [0,2,100]) {
  test(`cleanup polls process group and escalates only at deadline (${aliveSteps})`,t=>{
    const f=fixture(t), calls=join(f.dir,'calls'), group=join(f.dir,'group');
    writeFileSync(group,'999999');
    const r=f.run(`drive_group_file=${quote(group)}; probes=0;
      kill() { printf '%s\\n' "$1" >> ${quote(calls)}; if [ "$1" = -0 ]; then probes=$((probes + 1)); [ "$probes" -le ${aliveSteps} ]; fi; };
      sleep() { printf 'sleep:%s\\n' "$1" >> ${quote(calls)}; };
      drive_cleanup`);
    assert.equal(r.status,0,r.stderr);
    const events=readFileSync(calls,'utf8').trim().split('\n');
    assert.equal(events.filter(e=>e==='sleep:0.1').length,Math.min(aliveSteps,20));
    assert.equal(events.includes('-KILL'),aliveSteps>20);
    assert.ok(!existsSync(group));
  });
}

test('WSL detection recognizes WSL environment and respects override', t => {
  const f = fixture(t);
  let r = f.run('PORTABLE_AI_WSL=1 drive_is_wsl');
  assert.equal(r.status, 0);
  r = f.run('PORTABLE_AI_WSL=0 drive_is_wsl');
  assert.notEqual(r.status, 0);
  r = f.run('unset PORTABLE_AI_WSL; WSL_DISTRO_NAME=Ubuntu drive_is_wsl');
  assert.equal(r.status, 0);
  r = f.run('unset PORTABLE_AI_WSL; unset WSL_DISTRO_NAME; unset WSL_INTEROP; drive_is_wsl() { [ "$PORTABLE_AI_WSL" = 1 ]; }; drive_is_wsl');
  assert.notEqual(r.status, 0);
});

test('WSL CLI resolution finds Linux binaries and rejects Windows shims and /mnt paths', t => {
  const f = fixture(t);
  const wslBin = join(f.dir, 'wsl-bin'), winBin = join(f.dir, 'win-bin'), mntBin = join(f.dir, 'mnt-bin');
  mkdirSync(wslBin); mkdirSync(winBin); mkdirSync(mntBin);
  writeFileSync(join(wslBin, 'claude'), '#!/bin/sh\n', { mode: 0o755 });
  writeFileSync(join(winBin, 'claude.cmd'), '@echo off\n', { mode: 0o755 });
  writeFileSync(join(winBin, 'claude.exe'), 'MZ\n', { mode: 0o755 });
  writeFileSync(join(mntBin, 'codex'), '#!/bin/sh\n', { mode: 0o755 });
  f.env.PATH = `${winBin}:${wslBin}:${process.env.PATH}`;
  let r = f.run('drive_resolve_wsl_cli claude');
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), join(wslBin, 'claude'));

  f.env.PATH = `/mnt/c/some/path:${winBin}`;
  r = f.run('drive_resolve_wsl_cli codex');
  assert.notEqual(r.status, 0);
});

test('WSL discovery creates sparse ext4 image, uses existing mount or mounts loopback', t => {
  const f = fixture(t);
  const shared = f.shared;
  f.mock('truncate', 'touch "$3"');
  f.mock('mkfs.ext4', ':');
  f.mock('findmnt', 'exit 1');
  f.mock('udisksctl', `
    case $1 in
      loop-setup) printf "Mapped file %s as /dev/loop42.\\n" "$3";;
      mount) printf "Mounted /dev/loop42 at %s.\\n" "$MOCK_NATIVE";;
    esac
  `);
  let r = f.run(`PORTABLE_AI_WSL=1 drive_wsl_discover ${quote(shared)}`);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), f.native);
  assert.ok(existsSync(join(shared, 'state/wsl-state.ext4')));

  f.mock('findmnt', `printf '%s\\n' "${f.native}"`);
  r = f.run(`PORTABLE_AI_WSL=1 drive_wsl_discover ${quote(shared)}`);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), f.native);
});

test('WSL launcher executes resolved Linux CLIs, blocks dashboard, and guides missing CLIs', t => {
  const f = fixture(t);
  cpSync(join(root, 'launch'), join(f.shared, 'launch'), { recursive: true });
  const wslBin = join(f.dir, 'wsl-bin');
  mkdirSync(wslBin);
  writeFileSync(join(wslBin, 'claude'), '#!/bin/sh\nprintf "claude-run:%s\\n" "$*"\n', { mode: 0o755 });
  writeFileSync(join(wslBin, 'codex'), '#!/bin/sh\nprintf "codex-run:%s\\n" "$*"\n', { mode: 0o755 });
  f.env.PATH = `${wslBin}:${process.env.PATH}`;
  f.env.PORTABLE_AI_WSL = '1';
  f.mock('findmnt', `printf '%s\\n' "${f.native}"`);

  let r = f.run(`drive_main linux ${quote(join(f.shared, 'launch/linux.sh'))} claude arg1 'arg 2'`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /claude-run:arg1 arg 2/);

  r = f.run(`drive_main linux ${quote(join(f.shared, 'launch/linux.sh'))} dashboard`);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /Dashboard is not supported in WSL mode/);

  r = f.run(`PATH=/usr/bin:/bin drive_main linux ${quote(join(f.shared, 'launch/linux.sh'))} claude`);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /Linux 'claude' CLI not found.*Install Claude Code inside WSL Ubuntu/);
});

test('WSL session unmounts loop device and cleans up on exit', t => {
  const f = fixture(t);
  const calls = join(f.dir, 'unmount-calls');
  f.mock('udisksctl', `printf '%s\\n' "$*" >> ${quote(calls)}`);
  const r = f.run(`
    DRIVE_WSL_LOOP_DEV=/dev/loop99; DRIVE_WSL_MOUNT_TARGET=/tmp/ai-drive-wsl-1000;
    drive_wsl_unmount
  `);
  assert.equal(r.status, 0, r.stderr);
  const events = readFileSync(calls, 'utf8').trim().split('\n');
  assert.ok(events.includes('unmount -b /dev/loop99'));
  assert.ok(events.includes('loop-delete -b /dev/loop99'));
});
