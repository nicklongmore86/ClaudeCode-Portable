import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';

const scriptPath = resolve('tools/audit/audit.ps1');
const script = readFileSync(scriptPath, 'utf8');

test('Windows audit explicitly handles local, UNC, and already extended paths', () => {
  const extend = script.slice(script.indexOf('function ConvertTo-ExtendedPath'), script.indexOf('function ConvertTo-NormalPath'));
  const normalize = script.slice(script.indexOf('function ConvertTo-NormalPath'), script.indexOf('function Add-UnreadablePath'));
  assert.ok(extend.includes(String.raw`if ($Path.StartsWith('\\?\')) { return $Path }`));
  assert.ok(extend.includes(String.raw`if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }`));
  assert.ok(extend.includes(String.raw`return '\\?\' + $Path`));
  assert.ok(normalize.includes(String.raw`$Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)`));
  assert.ok(normalize.includes(String.raw`return '\\' + $Path.Substring(8)`));
  assert.ok(normalize.includes(String.raw`if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }`));
  assert.match(normalize, /return \$Path\s*}/);
});

test('Windows audit traverses prefixed paths, normalizes rows, and reports failures without scratch writes', () => {
  assert.match(script, /\$pending\.Push\(\(ConvertTo-ExtendedPath \$Root\)\)/);
  assert.match(script, /Get-AuditChildren \(ConvertTo-ExtendedPath \$env:USERPROFILE\)/);
  assert.match(script, /\[System.IO.DirectoryInfo\]::new\(\$Path\)/);
  assert.match(script, /\$directory\.GetFileSystemInfos\(\)/);
  assert.match(script, /\$pending\.Push\(\$entry.FullName\)/);
  assert.match(script, /'\{0\}\|\{1\}\|\{2\}' -f \(ConvertTo-NormalPath \$path\), \$file.Length, \$file.LastWriteTimeUtc.Ticks/);
  assert.equal((script.match(/Add-UnreadablePath \$path/gi) ?? []).length, 2);
  assert.match(script, /Write-Warning .*Unreadable paths skipped:.*\$script:unreadable.Count/);
  assert.doesNotMatch(script, /SilentlyContinue|Add-Type|New-Item|Out-File|WriteAll|GetTempFileName/);
  assert.equal((script.match(/Set-Content/g) ?? []).length, 1);
  assert.match(script, /Set-Content -LiteralPath \$Before -Encoding UTF8/);
});

const quote = value => `'${value.replaceAll("'", "''")}'`;
for (const shell of ['pwsh', 'powershell']) {
  const available = process.platform === 'win32' && spawnSync(shell, ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']).status === 0;
  test(`${shell}: snapshot/diff includes paths over MAX_PATH and warns about missing roots`, {skip: !available && 'requires Windows and an installed PowerShell'}, t => {
    const dir = mkdtempSync(join(resolve('.'), '.drive-test-audit-windows-'));
    t.after(() => rmSync(dir, {recursive: true, force: true}));
    const profile = join(dir, 'profile');
    const temp = join(dir, 'temp');
    const local = join(dir, 'local');
    const system = join(dir, 'system');
    for (const path of [profile, temp, local, join(system, 'Temp')]) mkdirSync(path, {recursive: true});
    const deep = join(profile, '.audit', ...Array(7).fill('long-directory-component-1234567890'));
    mkdirSync(deep, {recursive: true});
    const file = join(deep, 'changed.txt');
    assert.ok(file.length > 260);
    writeFileSync(file, 'before');
    const env = {...process.env, APPDATA: join(dir, 'missing'), LOCALAPPDATA: local, TEMP: temp, SystemRoot: system, USERPROFILE: profile};
    const run = args => {
      const result = spawnSync(shell, ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...args], {encoding: 'utf8', env});
      assert.equal(result.status, 0, result.stderr || result.stdout);
      return result.stdout;
    };
    // Run the actual helpers too: static tests alone cannot establish PS semantics.
    const helpers = script.slice(script.indexOf('function ConvertTo-ExtendedPath'), script.indexOf('function Add-UnreadablePath'));
    const paths = [String.raw`C:\short`, String.raw`\\server\share\deep`, String.raw`\\?\C:\deep`, String.raw`\\?\UNC\server\share\deep`, String.raw`\\?\unc\server\share\deep`];
    const command = `${helpers}\n@(${paths.map(quote).join(',')}) | ForEach-Object { $extended = ConvertTo-ExtendedPath $_; [pscustomobject]@{ extended = $extended; normal = ConvertTo-NormalPath $extended } } | ConvertTo-Json -Compress`;
    const pairs = JSON.parse(run(['-EncodedCommand', Buffer.from(command, 'utf16le').toString('base64')]));
    assert.deepEqual(pairs.map(p => p.extended), [String.raw`\\?\C:\short`, String.raw`\\?\UNC\server\share\deep`, ...paths.slice(2)]);
    assert.deepEqual(pairs.map(p => p.normal), [String.raw`C:\short`, String.raw`\\server\share\deep`, String.raw`C:\deep`, String.raw`\\server\share\deep`, String.raw`\\server\share\deep`]);
    const before = join(dir, 'before.txt'), after = join(dir, 'after.txt');
    const snapshot = output => run(['-File', scriptPath, 'snapshot', output]);
    assert.match(snapshot(before), /Unreadable paths skipped: 1/);
    const beforeRow = readFileSync(before, 'utf8').replace(/^\uFEFF/, '').trim();
    assert.ok(beforeRow.startsWith(`${file}|6|`), beforeRow);
    assert.match(beforeRow, /\|\d+$/);
    const diff = (a, b) => run(['-Command', `& ${quote(scriptPath)} diff ${quote(a)} ${quote(b)} | ConvertTo-Json -Compress`]);
    snapshot(after);
    assert.equal(diff(before, after).trim(), '');
    writeFileSync(file, 'after with a different length');
    snapshot(after);
    const changes = JSON.parse(diff(before, after));
    assert.equal(changes.length, 2);
    assert.deepEqual(changes.map(change => change.SideIndicator).sort(), ['<=', '=>']);
    for (const change of changes) assert.ok(change.InputObject.startsWith(`${file}|`));
    assert.deepEqual(readdirSync(dir).sort(), ['after.txt', 'before.txt', 'local', 'profile', 'system', 'temp']);
    for (const path of [temp, local, join(system, 'Temp')]) assert.deepEqual(readdirSync(path), []);
  });
}
