import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const helper = readFileSync(new URL('../launch/lib/wsl.ps1', import.meta.url), 'utf8');
const launcher = readFileSync(new URL('../launch/windows.ps1', import.meta.url), 'utf8');
const cmd = readFileSync(new URL('../launch/windows.cmd', import.meta.url), 'utf8');

test('Windows menu and direct WSL action bypass native initialization', () => {
  assert.match(launcher, /7 WSL mode`n6 Exit/);
  assert.match(launcher, /'7','wsl'.*Invoke-DriveWsl \$PSScriptRoot \$CliArgs/);
  const nativeGuard = launcher.match(/if \(\$selected -in ([^)]+)\) \{\s+if \(!\$nativeReady\)/);
  assert.ok(nativeGuard);
  assert.doesNotMatch(nativeGuard[1], /wsl|'7'/);
  assert.ok(launcher.indexOf('$selected = $Action') < launcher.indexOf('Find-DriveNative'));
  assert.match(launcher, /if \(\$Action -ne 'menu'\) \{ exit \$result \}/);
  assert.match(cmd, /windows\.ps1" %\*/);
  assert.match(cmd, /exit \/b %ERRORLEVEL%/);
});

test('WSL detection captures lists with explicit UTF-16LE decoding', () => {
  assert.match(helper, /Get-Command wsl\.exe -CommandType Application/);
  assert.match(helper, /@\('-l', '-q'\) -Capture -List/);
  assert.match(helper, /@\('-l', '-v'\) -Capture -List/);
  assert.match(helper, /if \(\$unicode\) \{ \[Text.Encoding\]::Unicode \} else \{ \[Text.Encoding\]::UTF8 \}/);
  assert.match(helper, /\$info.EnvironmentVariables.Remove\('WSL_UTF8'\)/);
  assert.match(helper, /ConvertFrom-WslBytes \$outBuffer.ToArray\(\) -List:\$List/);
  assert.match(helper, /ConvertFrom-WslBytes \$errBuffer.ToArray\(\)/);
  assert.match(helper, /listing.Code -ne 0/);
  assert.match(helper, /No WSL distro is installed/);
});

test('Distro selection validates override and prompts only after default and sole-distro checks', () => {
  assert.match(helper, /Select-WslDistro \$names \$verbose.Output \$env:PORTABLE_AI_WSL_DISTRO/);
  assert.match(helper, /\$Names -notcontains \$Override/);
  assert.match(helper, /\[regex\]::Escape\(\$name\)/);
  assert.ok(helper.indexOf('return $Override') < helper.indexOf('return $name }'));
  assert.ok(helper.indexOf('return $name }') < helper.indexOf('$Names.Count -eq 1'));
  assert.ok(helper.indexOf('$Names.Count -eq 1') < helper.indexOf("$choice = Read-Host"));
  assert.match(helper, /\$index -lt 1 -or \$index -gt \$Names.Count/);
});

test('WSL paths and argument arrays bypass shell evaluation and inherit the console', () => {
  assert.match(helper, /Join-Path \$LauncherDirectory 'linux.sh'/);
  assert.match(helper, /Test-Path -LiteralPath \$linux -PathType Leaf/);
  assert.match(helper, /@\('-d', \$Distro, '--exec', 'wslpath', '-a', \$WindowsPath\) -Capture/);
  assert.match(helper, /ConvertTo-WslPath \$executable \$distro \(Get-Location\).ProviderPath/);
  assert.match(helper, /translated.Code -ne 0/);
  const finalCall = helper.split('\n').find(line => line.includes('return Invoke-WslProcess $executable'));
  assert.match(finalCall, /'--cd', \$workingDirectory, '--exec', 'bash', \$linuxPath\) \+ \$forwarded/);
  assert.doesNotMatch(finalCall, /-Capture/);
  assert.match(helper, /return \$process.ExitCode/);
  assert.match(helper, /\$info.UseShellExecute = \$false/);
  assert.match(helper, /ConvertTo-WslArgument \$_/);
});

test('WSL helper contains no installer, host writes, compiler or native-drive dependency', () => {
  assert.doesNotMatch(helper, /--install|--set-default|Set-Content|Out-File|WriteAll|CreateDirectory|New-Item|Set-ItemProperty|Add-Type|Find-DriveNative|Get-DriveEnvironment|Invoke-Expression/i);
  assert.doesNotMatch(helper, /bash['"],\s*['"]-c|\/mnt\/[a-z]\//);
});

test('Captured helpers close stdin, bound waits and surface diagnostics without changing session stdin', () => {
  assert.match(helper, /if \(\$Capture\) \{\s*\$info.RedirectStandardInput = \$true/);
  assert.ok(helper.indexOf('$process.Start()') < helper.indexOf('$process.StandardInput.Close()'));
  assert.ok(helper.indexOf('$process.StandardInput.Close()') < helper.indexOf('BaseStream.CopyToAsync'));
  assert.match(helper, /WaitForExit\(\$TimeoutMilliseconds\)/);
  assert.match(helper, /\$process.Kill\(\)/);
  assert.match(helper, /WaitAll\([^\n]+, 5000\)/);
  for (const name of ['listing', 'verbose', 'translated', 'reachable']) {
    assert.ok(helper.includes(`Format-WslFailure $${name}`), `missing diagnostics: ${name}`);
  }
  assert.match(helper, /Write-Host 'Starting WSL/);
});

test('Preflight rejects WSL1, supports Sysnative, checks reachability and filters only null arguments', () => {
  assert.match(helper, /Assert-Wsl2Distro \$names \$verbose.Output \$distro/);
  assert.match(helper, /\$Matches\[1\] -ne '2'/);
  assert.match(helper, /Sysnative\/wsl.exe/);
  assert.match(helper, /'--exec', 'test', '-f', \$linuxPath\) -Capture/);
  assert.match(helper, /stops ALL running distros/);
  assert.match(helper, /\$forwarded = @\(\$CliArgs \| Where-Object \{ \$null -ne \$_ \}\)/);
});

// Exercise the actual regex/replacement literals from PowerShell under JS's
// compatible regex subset. These fixture checks do not execute PowerShell.
test('Production quoting expressions match adversarial Windows argv fixtures', () => {
  const expression = helper.match(/return '"' \+ \[regex\]::Replace\(\[regex\]::Replace\(\$Value, '([^']+)', '([^']+)'\), '([^']+)', '([^']+)'\)/);
  assert.ok(expression);
  const quote = value => '"' + value.replace(new RegExp(expression[1], 'g'), expression[2]).replace(new RegExp(expression[3], 'g'), expression[4]) + '"';
  const fixtures = [
    ['', '""'],
    ['S:\\Drive space\\launch\\linux.sh', '"S:\\Drive space\\launch\\linux.sh"'],
    ['C:\\project space\\', '"C:\\project space\\\\"'],
    ['say "hello"', '"say \\"hello\\""'],
    ['é &;$()', '"é &;$()"'],
  ];
  for (const [input, expected] of fixtures) assert.equal(quote(input), expected);
});

test('Production distro version expression matches localized rows and rejects unknown versions', () => {
  const pattern = helper.match(/\('([^']+)' \+ \[regex\]::Escape\(\$name\) \+ '([^']*\(\[12\]\)[^']*)'\)/);
  assert.ok(pattern);
  // Distro name fixtures include regex metacharacters and spaces.
  for (const [name, row, expected] of [
    ['Ubuntu', '* Ubuntu    Running    1', '1'],
    ['Ubuntu Custom', 'Ubuntu Custom    Arrêté    2', '2'],
    ['Distro.test', '* Distro.test    Stopped    2', '2'],
    ['Ubuntu', '* Ubuntu    Running    3', undefined],
    ['Ubuntu', 'Ubuntu    Running    unknown', undefined],
  ]) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.equal(new RegExp(pattern[1] + escaped + pattern[2]).exec(row)?.[1], expected);
  }
});

for (const executable of ['pwsh', 'powershell.exe']) {
  const available = spawnSync(executable, ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()'], { encoding: 'utf8' }).status === 0;
  test(`${executable}: real process boundary and mocked WSL dispatch`, { skip: !available && `${executable} is not installed` }, () => {
    const result = spawnSync(executable, ['-NoProfile', '-File', 'tests/drive-wsl.ps1'], {
      encoding: 'utf8', timeout: 45000, env: { ...process.env, PORTABLE_AI_TEST_NODE: process.execPath },
    });
    assert.equal(result.status, 0, String(result.error ?? '') + result.stdout + result.stderr);
  });
}
