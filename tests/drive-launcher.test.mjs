import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, existsSync, rmSync, utimesSync, symlinkSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync, spawn } from 'node:child_process';
const root = resolve('.');
const quote = s => `'${s.replaceAll("'", "'\\''")}'`;
function fixture(t) {
  const dir = mkdtempSync(join(root, '.drive-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const shared = join(dir, 'AI SHARED'), native = join(dir, 'native space'), mocks = join(dir, 'mock');
  for (const p of [shared, mocks, join(native,'tmp'), join(native, 'bin/linux-x64/codex/bin')]) mkdirSync(p, { recursive: true });
  const env = { ...process.env, PORTABLE_AI_WSL: '0', PATH: `${mocks}:${process.env.PATH}`, MOCK_NATIVE: native, MOCK_FIXTURE: dir, TMPDIR: join(native,'tmp') };
  const run = (body, extra = {}) => spawnSync('bash', ['-c', `. ${quote(join(root, 'launch/lib/drive.sh'))}; . ${quote(join(root, 'launch/lib/session.sh'))}; ${body}`], { env, encoding: 'utf8', ...extra });
  const setup = `drive_environment ${quote(shared)} ${quote(native)} linux-x64 || exit;`;
  const mock = (name, body) => writeFileSync(join(mocks, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  // Resolution must never fall through to real host-installed AI CLIs.
  mock('realpath', 'resolved=$(/usr/bin/realpath "$@") || exit; case $resolved in "$MOCK_FIXTURE"/*) printf "%s\\n" "$resolved";; *) exit 1;; esac');
  // Fail closed: no launcher test may invoke host storage/privilege tools.
  for (const name of ['truncate', 'mkfs.ext4', 'udisksctl', 'sudo', 'mount', 'umount', 'losetup']) {
    mock(name, `echo 'Unexpected storage command: ${name}' >&2; exit 97`);
  }
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

test('WSL detection recognizes environment, kernel and override without redefining detection', t => {
  const f = fixture(t);
  assert.equal(f.run('PORTABLE_AI_WSL=1 drive_is_wsl').status, 0);
  assert.equal(f.run('WSL_DISTRO_NAME=Ubuntu PORTABLE_AI_WSL=0 drive_is_wsl').status, 1);
  assert.equal(f.run('unset PORTABLE_AI_WSL; WSL_DISTRO_NAME=Ubuntu drive_is_wsl').status, 0);
  f.mock('grep', '[ "$*" = "-qi microsoft /proc/version" ] || exit 9; exit 1');
  assert.equal(f.run('unset PORTABLE_AI_WSL WSL_DISTRO_NAME WSL_INTEROP; drive_is_wsl').status, 1);
  f.mock('grep', '[ "$*" = "-qi microsoft /proc/version" ]');
  assert.equal(f.run('unset PORTABLE_AI_WSL WSL_DISTRO_NAME WSL_INTEROP; drive_is_wsl').status, 0);
});

test('WSL CLI resolver rejects symlinked Windows shims, PE files and globbed PATH entries', t => {
  const f = fixture(t);
  f.env.HOME = f.dir;
  const win = join(f.dir, 'windows'), linux = join(f.dir, 'linux');
  mkdirSync(win); mkdirSync(linux);
  writeFileSync(join(win, 'claude.cmd'), '@echo off', { mode: 0o755 });
  symlinkSync(join(win, 'claude.cmd'), join(win, 'claude'));
  writeFileSync(join(linux, 'claude'), '#!/bin/sh\n', { mode: 0o755 });
  f.env.PATH = `${win}:${linux}:${f.env.PATH}`;
  assert.equal(f.run('drive_resolve_wsl_cli claude').stdout.trim(), join(linux, 'claude'));
  rmSync(join(win, 'claude'));
  writeFileSync(join(win, 'claude'), 'MZfake', { mode: 0o755 });
  assert.equal(f.run('drive_resolve_wsl_cli claude').stdout.trim(), join(linux, 'claude'));
  f.env.PATH = `${join(f.dir, 'lin*')}:${f.mocks}:/usr/bin:/bin`;
  assert.equal(f.run('drive_resolve_wsl_cli claude').status, 1);
});

function wslFixture(t, backend = 'udisks') {
  const f = fixture(t);
  cpSync(join(root, 'launch'), join(f.shared, 'launch'), { recursive: true });
  f.env.HOME = join(f.dir, 'user-home');
  mkdirSync(f.env.HOME);
  f.env.PORTABLE_AI_WSL = '1';
  f.env.XDG_RUNTIME_DIR = f.dir;
  f.env.PORTABLE_AI_WSL_IMAGE_SIZE = '128M';
  f.env.WSL_DISTRO_NAME = 'TestDistro';
  f.env.WSL_CALLS = join(f.dir, 'calls');
  f.env.WSL_ATTACHED = join(f.dir, 'attached');
  f.env.WSL_MOUNTED = join(f.dir, 'mounted');
  f.env.WSL_BACKEND = backend;
  const mock = (name, body) => f.mock(name, `printf '%s\\n' '${name}'\" $*\" >> "$WSL_CALLS"\n${body}`);
  mock('uname', 'case $1 in -r) echo 6.6-microsoft-standard-WSL2;; -m) echo x86_64;; esac');
  mock('truncate', 'touch "$3"');
  mock('mkfs.ext4', '[ "$3" = -E ] && [ "$4" = "root_owner=$(id -u):$(id -g)" ]');
  mock('df', "printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\nx 999999999 0 999999999 0%% /\\n'");
  mock('sync', ':');
  mock('findmnt', `
    [ "$3" = /dev/loop42 ] && [ -f "$WSL_MOUNTED" ] || exit 1
    # Emulate findmnt --raw, including paths containing spaces.
    sed 's/ /\\\\x20/g' "$WSL_MOUNTED"
  `);
  mock('losetup', `case $1 in
    -j) [ ! -f "$WSL_ATTACHED" ] || printf '/dev/loop42: []: (%s)\\n' "$2";;
    --find) touch "$WSL_ATTACHED"; echo /dev/loop42;;
    -d) rm -f "$WSL_ATTACHED";;
    *) exit 97;; esac`);
  mock('udisksctl', `case $1 in
    loop-setup) [ "$WSL_BACKEND" = udisks ] || exit 1; touch "$WSL_ATTACHED"; printf 'Mapped file as /dev/loop42.\\n';;
    mount) printf '%s\\n' "$MOCK_NATIVE" > "$WSL_MOUNTED";;
    unmount) rm -f "$WSL_MOUNTED";;
    loop-delete) rm -f "$WSL_ATTACHED";;
    *) exit 97;; esac`);
  mock('sudo', '[ \"$1\" != -v ] || exit 0; [ \"$1\" != -n ] || shift; \"$@\"');
  mock('mount', 'printf "%s\\n" "$6" > "$WSL_MOUNTED"');
  // Simulated state files must disappear before rmdir, just as unmount reveals
  // the empty underlying directory. Never invoke the real mount or umount.
  mock('umount', 'rm -rf -- "$1/state" "$1/tmp"; rm -f "$WSL_MOUNTED"');
  mock('claude', 'test -d "$CLAUDE_CONFIG_DIR" && test -d "$CODEX_HOME"; printf "claude-run:%s\\n" "$*"');
  mock('codex', 'printf refreshed > "$CODEX_HOME/auth.json"');
  f.main = (action = 'exit', extra = {}, prelude = '') => f.run(`drive_wsl_consent() { IFS= read -r answer; [ "$answer" = y ]; }; ${prelude}\ndrive_main linux ${quote(join(f.shared, 'launch/linux.sh'))} ${action}`, extra);
  f.calls = () => existsSync(f.env.WSL_CALLS) ? readFileSync(f.env.WSL_CALLS, 'utf8').trim().split('\n') : [];
  f.lock = join(f.shared, 'state/wsl-state.lock');
  f.image = join(f.shared, 'state/wsl-state.ext4');
  f.storageMock = mock;
  return f;
}
function assertClean(f, backend = 'udisks') {
  const events = f.calls();
  const unmount = backend === 'udisks' ? 'udisksctl unmount -b /dev/loop42' : events.find(e => e.startsWith('umount '));
  const detach = backend === 'udisks' ? 'udisksctl loop-delete -b /dev/loop42' : 'losetup -d /dev/loop42';
  assert.equal(events.filter(e => e === unmount).length, 1, events.join('\n'));
  assert.equal(events.filter(e => e === detach).length, 1, events.join('\n'));
  assert.ok(events.indexOf('sync ') < events.indexOf(unmount));
  assert.ok(events.indexOf(unmount) < events.indexOf(detach));
  assert.ok(!existsSync(f.lock));
  assert.ok(!existsSync(f.env.WSL_ATTACHED));
  assert.ok(!existsSync(f.env.WSL_MOUNTED));
}
for (const [action, input, status, prelude] of [
  ['claude one "two words"', '', 0, ''],
  ['codex', '', 0, ''],
  ['exit', '', 0, ''],
  ['menu', '6\n', 0, ''],
  ['menu', '', 0, ''],
  ['dashboard', '', 1, ''],
  ['claude', '', 1, 'drive_resolve_wsl_cli() { return 1; };'],
  ['exit', '', 1, 'drive_environment() { return 1; };'],
]) {
  test(`WSL drive_main cleanup: ${action}, input=${JSON.stringify(input)}, prelude=${prelude}`, t => {
    const f = wslFixture(t);
    const r = f.main(action, { input }, prelude);
    assert.equal(r.status, status, r.stderr);
    assertClean(f);
    assert.ok(existsSync(f.image));
    assert.ok(f.calls().some(e => /mkfs.ext4 -F -q -E root_owner=\d+:\d+/.test(e)));
    if (action.startsWith('claude one')) assert.match(r.stdout, /claude-run:one two words/);
    if (action === 'codex') assert.equal(readFileSync(join(f.shared, 'credentials/codex-auth.json'), 'utf8'), 'refreshed');
  });
}

test('WSL sudo path uses owned mktemp directory, mount protections and removes mountpoint', t => {
  const f = wslFixture(t, 'sudo');
  const r = f.main('claude', { input: 'y\n' });
  assert.equal(r.status, 0, r.stderr);
  assertClean(f, 'sudo');
  const mount = f.calls().find(e => e.startsWith('mount '));
  assert.match(mount, /mount -t ext4 -o nosuid,nodev \/dev\/loop42 .*\/ai-drive-wsl\.[A-Za-z0-9]+$/);
  const target = mount.split('/dev/loop42 ')[1];
  assert.ok(!existsSync(target));
});

for (const failure of ['unmount', 'loop-delete']) {
  test(`WSL ${failure} failure warns, returns failure and retains lock`, t => {
    const f = wslFixture(t);
    const original = readFileSync(join(f.mocks, 'udisksctl'), 'utf8');
    writeFileSync(join(f.mocks, 'udisksctl'), original.replace('case $1 in', `[ "$1" != ${failure} ] || exit 1\ncase $1 in`));
    const r = f.main();
    assert.equal(r.status, 1, r.stderr);
    assert.match(r.stderr, /do NOT unplug the drive/);
    assert.ok(existsSync(f.lock));
    assert.ok(existsSync(f.env.WSL_ATTACHED));
    if (failure === 'unmount') assert.ok(!f.calls().some(e => e.startsWith('udisksctl loop-delete')));
  });
}

for (const state of ['active', 'stale', 'foreign', 'incomplete', 'attached']) {
  test(`WSL refuses ${state} image ownership through drive_main`, t => {
    const f = wslFixture(t);
    if (state === 'attached') writeFileSync(f.env.WSL_ATTACHED, '');
    else {
      mkdirSync(f.lock, { recursive: true });
      if (state !== 'incomplete') writeFileSync(join(f.lock, 'owner'), `host=test distro=${state === 'foreign' ? 'OtherDistro' : 'TestDistro'} pid=${state === 'active' ? process.pid : 99999999}`);
    }
    const r = f.main();
    assert.equal(r.status, 1, r.stderr);
    assert.match(r.stderr, state === 'attached' ? /already attached/ : /locked.*\nAfter a crash, this may be a stale lock/s);
    assert.ok(!f.calls().some(e => e.startsWith('truncate ') || e.startsWith('udisksctl loop-setup')));
    assert.equal(existsSync(f.lock), state !== 'attached');
  });
}

for (const failure of ['mkfs.ext4', 'truncate']) {
  test(`WSL atomic creation removes partial after ${failure} failure and can retry`, t => {
    const f = wslFixture(t);
    f.storageMock(failure, 'exit 1');
    let r = f.main();
    assert.equal(r.status, 1, r.stderr);
    assert.ok(!existsSync(f.image));
    assert.deepEqual(readdirSync(join(f.shared, 'state')), []);
    f.storageMock(failure, ':');
    r = f.main();
    assert.equal(r.status, 0, r.stderr);
    assertClean(f);
  });
}

for (const [size, fs, free, message] of [
  ['4G', 'vfat', '999999999', /FAT32/],
  ['4G', 'exfat', '1', /Not enough free space/],
  ['oops', 'exfat', '999999999', /must be an integer/],
]) {
  test(`WSL image allocation rejects size=${size}, fs=${fs}, free=${free}`, t => {
    const f = wslFixture(t);
    f.env.PORTABLE_AI_WSL_IMAGE_SIZE = size;
    f.mock('stat', `echo ${fs}`);
    f.mock('df', `printf 'header\\nx 9 0 ${free} 0%% /\\n'`);
    const r = f.main();
    assert.equal(r.status, 1, r.stderr);
    assert.match(r.stderr, message);
    assert.ok(!existsSync(f.image));
    assert.ok(!existsSync(f.lock));
  });
}

test('WSL1 gets a clear refusal before image creation', t => {
  const f = wslFixture(t);
  f.mock('uname', 'echo 4.4.0-Microsoft');
  const r = f.main();
  assert.equal(r.status, 1);
  assert.match(r.stderr, /WSL1 is unsupported/);
  assert.ok(!existsSync(f.image));
});

test('WSL menu resolves CLIs once and teardown is idempotent', t => {
  const f = wslFixture(t);
  const r = f.main('menu', { input: '1\n1\n6\n' }, `
    original_resolver=$(declare -f drive_resolve_wsl_cli)
    eval "\${original_resolver/drive_resolve_wsl_cli/original_resolve}"
    drive_resolve_wsl_cli() { echo resolve >> "$WSL_CALLS"; original_resolve "$@"; }
    original_unmount=$(declare -f drive_wsl_unmount)
    eval "\${original_unmount/drive_wsl_unmount/original_unmount}"
    drive_wsl_unmount() { original_unmount && original_unmount; }
  `);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(f.calls().filter(e => e === 'resolve').length, 2);
  assertClean(f);
});

for (const signal of ['INT', 'TERM']) {
  for (const phase of ['mkfs.ext4', 'loop-setup', 'mount', 'sudo', 'claude']) {
    test(`WSL ${signal} during ${phase} cleans acquired state through drive_main`, t => {
      const f = wslFixture(t, phase === 'sudo' ? 'sudo' : 'udisks');
      // Signals target the launcher while the mocked external operation runs.
      // For setup/mount, signal AFTER simulated kernel acquisition, exercising
      // cleanup recovery when command substitution never assigns its output.
      const name = ['loop-setup', 'mount'].includes(phase) ? 'udisksctl' : phase;
      const path = join(f.mocks, name);
      let script = readFileSync(path, 'utf8');
      const trigger = `kill -${signal} "$LAUNCHER_PID"; sleep 0.05`;
      if (phase === 'loop-setup') script = script.replace('touch "$WSL_ATTACHED";', `touch "$WSL_ATTACHED"; ${trigger};`);
      else if (phase === 'mount') script = script.replace('> "$WSL_MOUNTED";;', `> "$WSL_MOUNTED"; ${trigger};;`);
      else script += `\n${trigger}\n`;
      writeFileSync(path, script);
      const r = f.main(phase === 'claude' ? 'claude' : 'exit', { input: 'y\n', timeout: 10000 }, 'export LAUNCHER_PID=$$;');
      assert.equal(r.status, signal === 'INT' ? 130 : 143, r.stderr);
      assert.ok(!existsSync(f.lock), r.stderr);
      assert.ok(!existsSync(f.env.WSL_ATTACHED), r.stderr);
      assert.ok(!existsSync(f.env.WSL_MOUNTED), r.stderr);
      assert.ok(!readdirSync(join(f.shared, 'state')).some(n => n.startsWith('wsl-state.partial.')));
      if (phase === 'mount' || phase === 'claude') assertClean(f);
    });
  }
}

for (const backend of ['udisks', 'sudo']) {
  test(`WSL ${backend} formats for invoking non-root identity and creates state directories`, t => {
    const f = wslFixture(t, backend);
    f.mock('id', 'case $1 in -u) echo 1234;; -g) echo 5678;; *) exit 97;; esac');
    f.mock('stat', '[ "$1" != -c ] || { echo 1234; exit; }; exec /usr/bin/stat "$@"');
    const r = f.main('claude', { input: 'y\n' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /claude-run/);
    assert.ok(f.calls().some(e => e.includes('-E root_owner=1234:5678')));
    assertClean(f, backend);
  });
}

for (const failure of ['mount', 'sync', 'deferred-detach', 'sudo-mount', 'sudo-unmount', 'sudo-detach', 'unsafe-owner', 'consent']) {
  test(`WSL handles ${failure} through discovery and exit cleanup`, t => {
    const backend = failure.startsWith('sudo-') || ['unsafe-owner', 'consent'].includes(failure) ? 'sudo' : 'udisks';
    const f = wslFixture(t, backend);
    if (failure === 'mount' || failure === 'deferred-detach') {
      const path = join(f.mocks, 'udisksctl');
      let script = readFileSync(path, 'utf8');
      if (failure === 'mount') script = script.replace('case $1 in', '[ "$1" != mount ] || exit 1\ncase $1 in');
      else script = script.replace('rm -f "$WSL_ATTACHED"', ':');
      writeFileSync(path, script);
    } else if (failure === 'unsafe-owner') f.mock('stat', '[ "$1" != -c ] || { echo wrong-owner; exit; }; exec /usr/bin/stat "$@"');
    else if (failure === 'sudo-detach') {
      const path = join(f.mocks, 'losetup');
      writeFileSync(path, readFileSync(path, 'utf8').replace('-d) rm', '-d) exit 1; rm'));
    } else if (failure !== 'consent') f.storageMock(failure.replace('sudo-', '').replace('unmount', 'umount'), 'exit 1');
    const r = f.main('exit', { input: failure === 'consent' ? 'n\n' : 'y\n' });
    assert.equal(r.status, 1, r.stderr);
    const retained = ['sync', 'deferred-detach', 'sudo-unmount', 'sudo-detach'].includes(failure);
    assert.equal(existsSync(f.lock), retained, r.stderr);
    if (retained) assert.match(r.stderr, /do NOT unplug the drive/);
    else assert.ok(!existsSync(f.env.WSL_ATTACHED));
    if (failure === 'unsafe-owner' || failure === 'consent') assert.ok(!f.calls().some(e => e.startsWith('sudo ')));
  });
}

test('WSL concurrent drive_main sessions cannot acquire the same image', async t => {
  const f = wslFixture(t), ready = join(f.dir, 'ready');
  f.storageMock('claude', `touch ${quote(ready)}; sleep 30`);
  const proc = spawn('bash', ['-c', `. ${quote(join(root, 'launch/lib/drive.sh'))}; . ${quote(join(root, 'launch/lib/session.sh'))}; drive_main linux ${quote(join(f.shared, 'launch/linux.sh'))} claude`], { env: f.env, stdio: 'ignore' });
  t.after(() => { try { proc.kill('SIGKILL'); } catch {} });
  const done = new Promise(resolve => proc.on('exit', (code, signal) => resolve({ code, signal })));
  for (let i = 0; i < 200 && !existsSync(ready); i++) await new Promise(resolve => setTimeout(resolve, 10));
  assert.ok(existsSync(ready));
  const second = f.main();
  assert.equal(second.status, 1, second.stderr);
  assert.match(second.stderr, /WSL image locked/);
  assert.ok(existsSync(f.lock));
  proc.kill('SIGTERM');
  assert.deepEqual(await done, { code: 143, signal: null });
  assertClean(f);
  assert.equal(f.calls().filter(e => e.startsWith('udisksctl loop-setup')).length, 1);
});

for (const location of ['.local/bin', '.npm-global/bin', '.claude/local', '.bun/bin', '.nvm/versions/node/v22.5.0/bin']) {
  test(`WSL non-interactive discovery searches original HOME/${location}`, t => {
    const f = wslFixture(t);
    rmSync(join(f.mocks, 'claude'));
    const bin = join(f.env.HOME, location);
    mkdirSync(bin, { recursive: true });
    writeFileSync(join(bin, 'claude'), '#!/bin/sh\necho user-cli\n', { mode: 0o755 });
    const r = f.main('claude');
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /user-cli/);
    assertClean(f);
  });
}

test('WSL nvm default alias wins over newest version, active NVM_BIN wins over default', t => {
  const f = wslFixture(t);
  rmSync(join(f.mocks, 'claude'));
  for (const v of ['v20.19.0', 'v22.3.0', 'v22.10.0', 'v24.1.0']) {
    const bin = join(f.env.HOME, '.nvm/versions/node', v, 'bin');
    mkdirSync(bin, { recursive: true });
    writeFileSync(join(bin, 'claude'), `#!/bin/sh\necho ${v}\n`, { mode: 0o755 });
  }
  mkdirSync(join(f.env.HOME, '.nvm/alias/lts'), { recursive: true });
  writeFileSync(join(f.env.HOME, '.nvm/alias/default'), 'lts/jod\n');
  writeFileSync(join(f.env.HOME, '.nvm/alias/lts/jod'), '22\n');
  let r = f.main('claude');
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /v22.10.0/);
  f.env.NVM_BIN = join(f.env.HOME, '.nvm/versions/node/v20.19.0/bin');
  r = f.main('claude');
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /v20.19.0/);
});

for (const fs of ['v9fs', '9p', 'virtiofs', 'drvfs']) {
  test(`WSL rejects ${fs} CLIs outside the default /mnt automount`, t => {
    const f = wslFixture(t);
    f.mock('stat', `echo ${fs}`);
    assert.equal(f.run('drive_resolve_wsl_cli claude').status, 1);
  });
}

test('WSL fallback locations still reject resolved Windows shims', t => {
  const f = wslFixture(t);
  rmSync(join(f.mocks, 'claude'));
  const bin = join(f.env.HOME, '.local/bin');
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, 'claude.cmd'), '@echo off', { mode: 0o755 });
  symlinkSync(join(bin, 'claude.cmd'), join(bin, 'claude'));
  const r = f.main('claude');
  assert.equal(r.status, 1);
  assert.match(r.stderr, /Linux 'claude' CLI not found/);
  assertClean(f);
});

test('drive_main resets all inherited WSL state before early-exit cleanup', t => {
  const f = wslFixture(t), victim = join(f.dir, 'victim'), partial = join(f.dir, 'partial');
  mkdirSync(victim); writeFileSync(join(victim, 'owner'), 'injected'); writeFileSync(partial, 'keep');
  Object.assign(f.env, { DRIVE_WSL_LOCK_HELD: '1', DRIVE_WSL_LOCK: victim, DRIVE_WSL_TOKEN: 'injected', DRIVE_WSL_PARTIAL: partial,
    DRIVE_WSL_ATTACH_ATTEMPT: '1', DRIVE_WSL_LOOP_DEV: '/dev/loop42', DRIVE_WSL_BACKEND: 'sudo', DRIVE_WSL_TMP_MOUNT: victim,
    DRIVE_WSL_WATCHDOG: '1', DRIVE_WSL_FUTURE_VAR: 'injected' });
  const r = f.main('exit', {}, 'drive_discover() { [ -z "${!DRIVE_WSL_@}" ] || exit 99; return 1; };');
  assert.equal(r.status, 1, r.stderr);
  assert.equal(readFileSync(join(victim, 'owner'), 'utf8'), 'injected');
  assert.equal(readFileSync(partial, 'utf8'), 'keep');
  assert.deepEqual(f.calls(), []);
});

for (const phase of ['mkdir', 'partial']) {
  test(`WSL signal immediately after ${phase} creation cannot leak token-owned state`, t => {
    const f = wslFixture(t);
    if (phase === 'mkdir') {
      f.mock('mkdir', '/usr/bin/mkdir "$@" || exit; case $1 in */wsl-state.lock) kill -TERM "$LAUNCHER_PID";; esac');
    }
    if (phase === 'partial') f.storageMock('truncate', '[ -f "$3" ] || exit 98; kill -TERM "$LAUNCHER_PID"');
    const prelude = 'export LAUNCHER_PID=$$;';
    const r = f.main('exit', {}, prelude);
    assert.equal(r.status, 143, r.stderr);
    assert.ok(!existsSync(f.lock), r.stderr);
    assert.ok(!existsSync(f.image));
  });
}

test('WSL cleanup refuses to remove a replaced lock token or its partial', t => {
  const f = wslFixture(t);
  const r = f.main('exit', {}, 'drive_environment() { printf foreign > "$DRIVE_WSL_LOCK/owner"; printf keep > "$DRIVE_WSL_LOCK/image.partial"; return 1; };');
  assert.equal(r.status, 1);
  assert.equal(readFileSync(join(f.lock, 'owner'), 'utf8'), 'foreign');
  assert.equal(readFileSync(join(f.lock, 'image.partial'), 'utf8'), 'keep');
  assert.ok(!f.calls().some(e => e.startsWith('udisksctl unmount')));
});

test('WSL sudo consent fails clearly without a tty and does not consume piped input', t => {
  const f = wslFixture(t, 'sudo');
  const r = f.run(`drive_main linux ${quote(join(f.shared, 'launch/linux.sh'))} claude`, { input: 'y\nprompt\n' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /requires a controlling terminal/);
  assert.ok(!f.calls().some(e => e.startsWith('sudo ')));
  assert.ok(!existsSync(f.lock));
});

test('WSL non-writable image root prints ownership repair guidance', t => {
  const f = wslFixture(t);
  const r = f.main('exit', {}, `
    [() { if test "$1" = ! && test "$2" = -w && test "$3" = "$MOCK_NATIVE"; then return 0; fi; builtin [ "$@"; }
  `);
  assert.equal(r.status, 1, r.stderr);
  assert.match(r.stderr, /sudo chown "\d+:\d+" ".*native space"/);
  assertClean(f);
});

test('WSL empty mountpoint removal failure warns but releases the lock', t => {
  const f = wslFixture(t, 'sudo');
  f.mock('rmdir', 'case $* in *ai-drive-wsl.*) exit 1;; *) exec /usr/bin/rmdir "$@";; esac');
  const r = f.main('exit', { input: 'y\n' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /Warning: empty WSL mountpoint remains/);
  assertClean(f, 'sudo');
});

async function waitFor(check, message) {
  for (let i = 0; i < 250; i++) {
    if (check()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.fail(message);
}
function processRunning(pid) {
  const r = spawnSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' });
  return r.status === 0 && !r.stdout.trim().startsWith('Z');
}
for (const scenario of ['normal-expired', 'HUP', 'TERM', 'expired-no-tty']) {
  test(`WSL privileged watchdog: ${scenario}, no tty or real storage operations`, async t => {
    const f = wslFixture(t, 'sudo'), watcherPid = join(f.dir, 'watcher-pid');
    f.storageMock('setsid', `echo $$ > ${quote(watcherPid)}; exec /usr/bin/setsid "$@"`);
    f.storageMock('sudo', `
      case $1 in
        -v) ${scenario === 'expired-no-tty' ? 'exit 1' : 'touch "$WSL_CALLS.refreshed"; exit 0'};;
        -n) ${scenario === 'normal-expired' ? '[ -f "$WSL_CALLS.refreshed" ] || exit 1; shift; "$@"' : 'exit 1'};;
        *) "$@";;
      esac
    `);
    const signal = ['HUP', 'TERM'].includes(scenario) ? scenario : null;
    f.storageMock('claude', signal ? `kill -${signal} "$LAUNCHER_PID"; sleep 0.1` : ':');
    const r = f.main('claude', { input: 'y\n' }, 'export LAUNCHER_PID=$$;');
    assert.equal(r.status, signal === 'HUP' ? 1 : signal === 'TERM' ? 1 : scenario === 'expired-no-tty' ? 1 : 0, r.stderr);
    await waitFor(() => !existsSync(f.lock), 'watchdog failed to release lock after verified teardown');
    await waitFor(() => existsSync(watcherPid), 'watchdog did not start');
    const pid = Number(readFileSync(watcherPid, 'utf8'));
    await waitFor(() => !processRunning(pid), 'watchdog process survived teardown');
    assertClean(f, 'sudo');
    if (signal) assert.ok(!f.calls().includes('sudo -v'));
    else assert.ok(f.calls().includes('sudo -v'));
    if (scenario !== 'normal-expired') assert.match(r.stderr, /watchdog will retry teardown/);
  });
}

test('WSL tty consent preserves piped CLI input through drive_main', t => {
  const f = wslFixture(t, 'sudo'), input = join(f.dir, 'piped-input');
  writeFileSync(input, 'my actual prompt\n');
  f.storageMock('claude', 'IFS= read -r prompt; printf "PRESERVED:%s\\n" "$prompt"');
  const python = `
import os, pty, select, signal, time
pid, fd = pty.fork()
if pid == 0:
    source = os.open(${JSON.stringify(input)}, os.O_RDONLY)
    os.dup2(source, 0)
    os.execvp('bash', ['bash', ${JSON.stringify(join(f.shared, 'launch/linux.sh'))}, 'claude'])
output = b''
status = None
try:
    os.write(fd, b'y\\n')
    end = time.time() + 8
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try: chunk = os.read(fd, 4096)
            except OSError: break
            if not chunk: break
            output += chunk
        done, value = os.waitpid(pid, os.WNOHANG)
        if done:
            status = value
            break
    if status is None: _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 0, repr(output)
    assert b'PRESERVED:my actual prompt' in output, repr(output)
finally:
    try: os.kill(pid, signal.SIGKILL)
    except ProcessLookupError: pass
    os.close(fd)
`;
  const r = spawnSync('python3', ['-c', python], { env: f.env, encoding: 'utf8', timeout: 10000 });
  assert.equal(r.status, 0, r.stderr);
  assertClean(f, 'sudo');
});

for (const failure of ['sync', 'umount', 'detach', 'foreign-token']) {
  test(`WSL watchdog ${failure} failure retains the lock and exits`, async t => {
    const f = wslFixture(t, 'sudo'), watcherPid = join(f.dir, 'watcher-pid');
    f.storageMock('setsid', `echo $$ > ${quote(watcherPid)}; exec /usr/bin/setsid "$@"`);
    f.storageMock('sudo', `case $1 in
      -v) exit 1;;
      -n) ${failure === 'foreign-token' ? `printf foreign > ${quote(join(f.lock, 'owner'))};` : ''} exit 1;;
      *) "$@";; esac`);
    if (failure === 'sync' || failure === 'umount') f.storageMock(failure, 'exit 1');
    if (failure === 'detach') {
      const path = join(f.mocks, 'losetup');
      writeFileSync(path, readFileSync(path, 'utf8').replace('-d) rm', '-d) exit 1; rm'));
    }
    const r = f.main('exit', { input: 'y\n' });
    assert.equal(r.status, 1, r.stderr);
    await waitFor(() => existsSync(watcherPid), 'watchdog did not start');
    const pid = Number(readFileSync(watcherPid, 'utf8'));
    await waitFor(() => !processRunning(pid), 'failed watchdog should exit, retaining lock for manual recovery');
    assert.ok(existsSync(f.lock));
    assert.ok(existsSync(f.env.WSL_ATTACHED));
    if (failure === 'foreign-token') {
      assert.equal(readFileSync(join(f.lock, 'owner'), 'utf8'), 'foreign');
      assert.ok(!f.calls().some(e => e.startsWith('umount ')));
    }
  });
}
