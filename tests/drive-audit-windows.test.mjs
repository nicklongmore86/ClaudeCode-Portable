import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';

const scriptPath = resolve('tools/audit/audit.ps1');
const script = readFileSync(scriptPath, 'utf8');

test('Windows audit retains extended paths, canonicalization, and visible read failures', () => {
  assert.match(script, /function ConvertTo-ExtendedPath\b/);
  assert.match(script, /function ConvertTo-NormalPath\b/);
  assert.match(script, /\[System.IO.Path\]::GetFullPath\(/);
  assert.match(script, /GetFileSystemInfos\(/);
  assert.match(script, /catch \[ArgumentException\], \[NotSupportedException\]/);
  assert.match(script, /Write-Warning .*Long paths may be missed/);
  assert.match(script, /Write-Warning .*Unreadable paths skipped/);
  assert.match(script, /'\{0\}\|\{1\}\|\{2\}'/);
});

test('Windows audit has no scratch writes and writes only the requested snapshot', () => {
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
    const roots = {APPDATA: join(dir, 'missing'), LOCALAPPDATA: local, TEMP: temp, SystemRoot: system, USERPROFILE: profile};
    // Keep the host's startup environment intact; its module cache is outside the audited roots.
    const env = {...process.env, PSModuleAnalysisCachePath: join(dir, 'host-module-cache'), POWERSHELL_TELEMETRY_OPTOUT: '1'};
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
    const pathChecks = `${helpers}
      $ErrorActionPreference = 'Stop'
      $relative = 'audit-relative/../audit-relative'
      if ((ConvertTo-NormalPath (ConvertTo-ExtendedPath $relative)) -ne [IO.Path]::GetFullPath($relative)) { throw 'relative path normalization failed' }
      if ((ConvertTo-NormalPath (ConvertTo-ExtendedPath 'C:/audit/../short')) -ne 'C:\\short') { throw 'slash/dot normalization failed' }
      try { ConvertTo-ExtendedPath '\\\\.\\PhysicalDrive0'; throw 'device path accepted' } catch [NotSupportedException] { }
    `;
    run(['-EncodedCommand', Buffer.from(pathChecks, 'utf16le').toString('base64')]);
    const stableFile = join(local, 'stable.txt');
    writeFileSync(stableFile, 'stable');
    const fixturePaths = new Set([file, stableFile]);
    const fixtureRows = output => readFileSync(output, 'utf8').replace(/^\uFEFF/, '').trim().split(/\r?\n/).filter(row => fixturePaths.has(row.split('|')[0]));
    const before = join(dir, 'before.txt'), after = join(dir, 'after.txt');
    const snapshot = output => {
      // Import before changing roots; restore them before host shutdown/cache writes.
      const command = `$ErrorActionPreference = 'Stop'; Import-Module Microsoft.PowerShell.Utility; $saved = @{}; try {
        ${Object.entries(roots).map(([key, value]) => `$saved[${quote(key)}] = $env:${key}; $env:${key} = ${quote(value)}`).join('; ')}
        & ${quote(scriptPath)} snapshot ${quote(output)}
      } finally { ${Object.keys(roots).map(key => `$env:${key} = $saved[${quote(key)}]`).join('; ')} }`;
      return run(['-Command', command]);
    };
    assert.match(snapshot(before), /Unreadable paths skipped: 1/);
    const beforeRow = fixtureRows(before).find(row => row.startsWith(`${file}|6|`));
    assert.ok(beforeRow, 'long-path file must be present');
    assert.equal(fixtureRows(before).length, 2);
    assert.match(beforeRow, /\|\d+$/);
    const diff = (a, b) => run(['-Command', `& ${quote(scriptPath)} diff ${quote(a)} ${quote(b)} | ConvertTo-Json -Compress`]);
    snapshot(after);
    assert.deepEqual(fixtureRows(before), fixtureRows(after));
    const unchanged = JSON.parse(diff(before, after).trim() || '[]');
    assert.deepEqual([unchanged].flat().filter(change => fixturePaths.has(change.InputObject.split('|')[0])), []);
    writeFileSync(file, 'after with a different length');
    snapshot(after);
    const changes = [JSON.parse(diff(before, after))].flat().filter(change => fixturePaths.has(change.InputObject.split('|')[0]));
    assert.equal(changes.length, 2);
    assert.deepEqual(changes.map(change => change.SideIndicator).sort(), ['<=', '=>']);
    for (const change of changes) assert.ok(change.InputObject.startsWith(`${file}|`));

  });
  test(`${shell}: legacy prefix rejection retries normal paths and warns once`, {skip: !available && 'requires Windows and an installed PowerShell'}, () => {
    const helpers = script.slice(script.indexOf('function ConvertTo-ExtendedPath'), script.indexOf("if ($Action -eq 'snapshot'"));
    const command = `${helpers}
      $ErrorActionPreference = 'Stop'
      $script:warnedLegacyPaths = $false
      $script:warnings = @()
      function Write-Warning($Message) { $script:warnings += $Message }
      $script:attempts = @()
      foreach ($kind in @('argument', 'unsupported')) {
        $result = Invoke-AuditPath '\\\\?\\C:\\audit' {
          param($path)
          $script:attempts += $path
          if ($path.StartsWith('\\\\?\\')) {
            if ($kind -eq 'argument') { throw [ArgumentException]::new('legacy path handling') }
            throw [NotSupportedException]::new('legacy path handling')
          }
          $path
        }
        if ($result -ne 'C:\\audit') { throw 'normal fallback failed' }
      }
      if ($script:warnings.Count -ne 1 -or $script:attempts.Count -ne 4) { throw 'retry/warning count incorrect' }
      $script:attempts = @()
      try {
        Invoke-AuditPath '\\\\?\\C:\\audit' { param($path); $script:attempts += $path; throw [IO.IOException]::new('read failed') }
        throw 'I/O failure swallowed'
      } catch [IO.IOException] { }
      if ($script:attempts.Count -ne 1) { throw 'I/O failure must not retry' }
    `;
    const result = spawnSync(shell, ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(command, 'utf16le').toString('base64')], {encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr || result.stdout);
  });
}
