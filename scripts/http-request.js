// scripts/http-request.js — minimal OpenAI-compatible POST helper for the
// offline sandbox, where in-Lisp TLS is unavailable but node's OpenSSL works.
// Reads the request JSON from a file, writes the response body to a file, and
// the HTTP status to a meta file. Prints nothing to stdout/stderr so it can be
// spawned without capturing piped output (sandbox constraint).
//
// Usage: node http-request.js --url <url> --in <req.json> --out <res.json> --meta <meta.txt>
'use strict';
const fs = require('fs');
const path = require('path');

function arg(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : null;
}

(async () => {
  const url = arg('--url');
  const inFile = arg('--in');
  const outFile = arg('--out');
  const metaFile = arg('--meta');
  const body = fs.readFileSync(inFile, 'utf8');
  const key = process.env.AGENT_CL_API_KEY || process.env.DEEPSEEK_API_KEY;
  let status = 0;
  let text = '';
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(key ? { Authorization: 'Bearer ' + key } : {}),
      },
      body,
    });
    status = res.status;
    text = await res.text();
  } catch (e) {
    status = -1;
    text = String(e && e.message ? e.message : e);
  }
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(outFile, text, 'utf8');
  if (metaFile) {
    fs.mkdirSync(path.dirname(metaFile), { recursive: true });
    fs.writeFileSync(metaFile, String(status), 'utf8');
  }
})().catch((e) => {
  fs.writeFileSync(arg('--meta'), '-2', 'utf8');
  process.exit(1);
});
