import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const helper = readFileSync(new URL('../launch/lib/wsl.ps1', import.meta.url), 'utf8');
const launcher = readFileSync(new URL('../launch/windows.ps1', import.meta.url), 'utf8');
const cmd = readFileSync(new URL('../launch/windows.cmd', import.meta.url), 'utf8');

test('Windows menu and direct WSL action bypass native initialization', () => {
  assert.match(launcher, /7 WSL mode/);
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
  assert.match(helper, /if \(\$List\) \{ \[Text.Encoding\]::Unicode \} else \{ \[Text.Encoding\]::UTF8 \}/);
  assert.match(helper, /\$info.EnvironmentVariables.Remove\('WSL_UTF8'\)/);
  assert.match(helper, /\$info.StandardOutputEncoding = \$encoding/);
  assert.match(helper, /ReadToEndAsync\(\)/);
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
  assert.match(finalCall, /'--cd', \$workingDirectory, '--exec', 'bash', \$linuxPath\) \+ \$CliArgs/);
  assert.doesNotMatch(finalCall, /-Capture/);
  assert.match(helper, /return \$process.ExitCode/);
  assert.match(helper, /\$info.UseShellExecute = \$false/);
  assert.match(helper, /ConvertTo-WslArgument \$_/);
});

test('WSL helper contains no installer, host writes, compiler or native-drive dependency', () => {
  assert.doesNotMatch(helper, /--install|--set-default|Set-Content|Out-File|WriteAll|CreateDirectory|New-Item|Set-ItemProperty|Add-Type|Find-DriveNative|Get-DriveEnvironment|Invoke-Expression/i);
  assert.doesNotMatch(helper, /bash['"],\s*['"]-c|\/mnt\/[a-z]\//);
});

const available = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()'], { encoding: 'utf8' }).status === 0;
test('PowerShell WSL parsing, selection, quoting, paths and dispatch mocks', { skip: !available && 'pwsh is not installed' }, () => {
  const result = spawnSync('pwsh', ['-NoProfile', '-File', 'tests/drive-wsl.ps1'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stdout + result.stderr);
});
