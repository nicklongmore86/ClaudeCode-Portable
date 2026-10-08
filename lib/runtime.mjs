import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync, renameSync, rmSync, realpathSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { ROOT, DATA, PLATFORM, RUNTIME, LOGS } from './paths.mjs';

export const manifest = JSON.parse(readFileSync(join(ROOT, 'tools/runtime-manifest.json'), 'utf8'));
// Claude is provisioned as a verified native release, independently of Node.
export function executableAt() {
  const executable = process.env.PORTABLE_AI_CLAUDE_EXECUTABLE;
  return executable && existsSync(executable) ? executable : null;
}
export function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore','pipe','pipe'], ...options }); let output = '';
    child.stdout?.on('data', c => { output += c; options.onOutput?.(c.toString()); });
    child.stderr?.on('data', c => { output += c; options.onOutput?.(c.toString()); });
    child.on('error', reject);
    child.on('exit', (code, signal) => code === 0 ? resolve(output.trim()) : reject(new Error(`${command.split(/[\\/]/).pop()} exited ${code ?? signal}: ${output.slice(-1500)}`)));
  });
}
function npmCLI() {
  const base = dirname(process.execPath);
  const candidates = [join(base, 'node_modules/npm/bin/npm-cli.js'), join(base, '../lib/node_modules/npm/bin/npm-cli.js')];
  try { candidates.push(realpathSync(join(base, 'npm'))); } catch {}
  const found = candidates.find(existsSync);
  if (!found) throw new Error('Bundled npm is missing. Reprovision the dashboard Node distribution on the prep machine.');
  return found;
}
export async function runtimeStatus() {
  const executable = executableAt();
  const stub = false;
  let version = null;
  if (executable && !stub) try { version = await run(executable, ['--version'], { timeout: 15000 }); } catch {}
  return { installed: !!version, version, platform: PLATFORM, node: process.version, pinned: '2.1.247', sdk: manifest.dependencies['@anthropic-ai/claude-agent-sdk'], executable, stub };
}
export function stagingComplete(directory) {
  return Object.keys(manifest.dependencies).every(dep => existsSync(join(directory, 'node_modules', dep, 'package.json')));
}
export async function installRuntime({ onOutput = () => {}, target = RUNTIME, runner = run } = {}) {
  if (target === RUNTIME && process.env.PORTABLE_AI_RUNTIME_DIR) throw new Error('Use provision/download.py on the prep machine to repair the pinned drive runtime.');
  const base = dirname(target); const staging = join(base, 'staging'); const backup = join(base, 'previous'); const lock = join(base, 'install.lock');
  mkdirSync(base, { recursive: true }); mkdirSync(LOGS, { recursive: true }); mkdirSync(join(DATA, 'npm-cache'), { recursive: true });
  try { mkdirSync(lock); } catch { throw new Error('An installation is already running. If it was interrupted, remove engine/<platform>/install.lock after checking no installer is active.'); }
  const log = join(LOGS, 'runtime-install.log');
  try {
    const resuming = existsSync(staging);
    mkdirSync(staging, { recursive: true });
    writeFileSync(join(staging, 'package.json'), JSON.stringify(manifest, null, 2));
    appendFileSync(log, `\n=== Runtime installation ${new Date().toISOString()} ===\n`, { mode: 0o600 });
    onOutput('Installing pinned dashboard dependencies (Claude is provisioned separately)...\n');
    if (resuming) onOutput('Resuming the previous incomplete installation; verified files will be reused.\n');
    onOutput('Dashboard dependencies can take several minutes to prepare. Please wait.\n');
    const started = Date.now();
    const heartbeat = setInterval(() => {
      onOutput(`Still installing... ${Math.round((Date.now() - started) / 1000)}s elapsed. Do not close this window.\n`);
    }, 20000);
    if (typeof heartbeat.unref === 'function') heartbeat.unref();
    try {
      await runner(process.execPath, [npmCLI(), 'install', '--prefix', staging, '--ignore-scripts', '--omit=optional', '--no-audit', '--no-fund', '--save=false', '--no-bin-links', '--no-install-links', '--cache', join(DATA, 'npm-cache')], { cwd: staging, env: { ...process.env, npm_config_cache: join(DATA, 'npm-cache') }, onOutput: s => { appendFileSync(log, s); onOutput(s); } });
    } finally {
      clearInterval(heartbeat);
    }
    if (!stagingComplete(staging)) throw new Error('Dashboard dependencies are incomplete; existing runtime was preserved');
    const version = 'Pinned dashboard dependencies installed';
    rmSync(backup, { recursive: true, force: true });
    if (existsSync(target)) renameSync(target, backup);
    try { renameSync(staging, target); } catch (e) { if (existsSync(backup)) renameSync(backup, target); throw e; }
    onOutput(`Ready: ${version}\n`);
    return version;
  } catch (error) {
    const detail=error?.stack||error?.message||String(error);
    try { appendFileSync(log, `\nINSTALL FAILED\n${detail}\n`); } catch {}
    throw new Error(`${error.message}\nIncomplete installation files were preserved for the next attempt. Details: ${log}`, { cause:error });
  } finally { rmSync(lock, { recursive: true, force: true }); }
}
export async function rollbackRuntime({target=RUNTIME}={}) {
  const base = dirname(target), backup = join(base, 'previous'), swap = join(base, 'rollback-swap');
  if (existsSync(join(base, 'install.lock'))) throw new Error('Installation is in progress');
  if (!stagingComplete(backup)) throw new Error('No complete previous dashboard installation is available');
  renameSync(target, swap);
  try { renameSync(backup, target); } catch (e) { renameSync(swap, target); throw e; }
  renameSync(swap, backup);
}
export async function loadSDK() {
  const require = createRequire(join(RUNTIME, 'package.json'));
  return import(pathToFileURL(require.resolve('@anthropic-ai/claude-agent-sdk')).href);
}
export function listLogs() {
  mkdirSync(LOGS, { recursive: true });
  return readdirSync(LOGS).filter(n => /^[\w.-]+\.log$/.test(n));
}
