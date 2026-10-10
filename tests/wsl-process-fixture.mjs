// Harmless child for the real PowerShell ProcessStartInfo boundary tests.
import { readFileSync } from 'node:fs';
const [outEncoding, errEncoding, mode, ...args] = process.argv.slice(2);
const stdin = readFileSync(0, 'utf8'); // Must get EOF without a console keypress.
process.stdout.write(Buffer.from(JSON.stringify({ args, stdin }), outEncoding));
process.stderr.write(Buffer.from('Kernel update needed; VM platform disabled; no distros. é\n', errEncoding));
if (mode === 'wait') setTimeout(() => { process.exitCode = 23; }, 10000);
else process.exitCode = 23;
