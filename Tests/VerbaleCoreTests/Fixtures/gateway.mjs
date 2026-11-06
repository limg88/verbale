import http from 'node:http';
import { writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { once } from 'node:events';
const [project, output] = process.argv.slice(2);
const { validateConfig } = await import(pathToFileURL(join(project, 'src/config.js')));
const { createGateway } = await import(pathToFileURL(join(project, 'src/server.js')));
let reports = 0, leaks = 0, groqCalls = 0;
const growthBudgets = [];
const timers = new Set();
const model = http.createServer(async (req, res) => {
  if (req.url === '/leak') { leaks++; res.end('{}'); return; }
  let body = ''; for await (const chunk of req) body += chunk;
  const request = JSON.parse(body);
  if (req.headers.authorization || request.temperature !== undefined || !Number.isInteger(request.max_tokens)) {
    res.writeHead(400, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: { message: 'Unexpected forwarded credentials or parameters' } })); return;
  }
  if (request.model === 'quota') { res.writeHead(429); res.end(JSON.stringify({ error: { message: 'quota limit' } })); return; }
  if (request.model === 'slow') {
    const timer = setTimeout(() => { res.end('{}'); timers.delete(timer); }, 10000); timers.add(timer);
    res.on('close', () => { clearTimeout(timer); timers.delete(timer); }); return;
  }
  reports++;
  if (request.model === 'grow') growthBudgets.push(request.max_tokens);
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify({ choices: [{ message: { content: request.model === 'operational' ? JSON.stringify({facts:[{kind:'action',text:'Verificare il capitolato',refs:['S1'],owner:'Marco',commitment:'agreed'}],overview:[{kind:'summary',text:'Verifica pianificata',refs:['S1']}]}) : 'Decisione [[S1]]. Nota personale [[N]].' }, finish_reason: request.model === 'length' || (request.model === 'grow' && request.max_tokens < 8000) ? 'length' : 'stop' }], usage: { prompt_tokens: 15, completion_tokens: 10, total_tokens: 25 } }));
});
model.listen(0, '127.0.0.1'); await once(model, 'listening');
await mkdir(output, { recursive: true });
const token = 'integration-test-token-no-secrets';
const config = validateConfig({ port: 0, backends: { fixture: { type: 'local', baseURL: `http://127.0.0.1:${model.address().port}/v1` }, groq: { type: 'groq', tokenEnv: 'VERBALE_FIXTURE_GROQ_KEY' } }, models: { ...Object.fromEntries(['test', 'quota', 'length', 'slow', 'grow', 'operational'].map(name => [`local/${name}`, { backend: 'fixture', model: name }])), 'groq/test': { backend: 'groq', model: 'openai/gpt-oss-20b' } } }, { LLM_GATEWAY_TOKEN: token });
config.workRoot = join(output, 'requests');
process.env.VERBALE_FIXTURE_GROQ_KEY = 'fake-key-for-groq-integration';
config.groqFetch = async (url, init) => {
  const body = JSON.parse(init.body);
  if (url !== 'https://api.groq.com/openai/v1/chat/completions' || init.headers.Authorization !== 'Bearer fake-key-for-groq-integration' || body.max_completion_tokens !== 6000 || body.reasoning_effort !== 'low') throw new Error('Groq contract mismatch');
  groqCalls++;
  return new Response(JSON.stringify({ choices: [{ message: { content: 'Decisione [[S1]]. Nota [[N]].' }, finish_reason: 'stop' }], usage: { prompt_tokens: 15, completion_tokens: 10, total_tokens: 25 } }), { status: 200 });
};
const gateway = createGateway(config); const address = await gateway.listen();
const redirect = http.createServer((req, res) => {
  if (req.url === '/health') { res.setHeader('Content-Type', 'application/json'); res.end('{"status":"ok"}'); }
  else { res.writeHead(302, { Location: `http://127.0.0.1:${model.address().port}/leak` }); res.end(); }
});
redirect.listen(0, '127.0.0.1'); await once(redirect, 'listening');
await writeFile(join(output, 'metadata.json'), JSON.stringify({ endpoint: `http://127.0.0.1:${address.port}/v1`, redirect: `http://127.0.0.1:${redirect.address().port}/v1` }));
let closing = false;
async function close() {
  if (closing) return; closing = true;
  await gateway.close();
  for (const timer of timers) clearTimeout(timer);
  model.closeAllConnections(); redirect.closeAllConnections();
  await Promise.all([new Promise(resolve => model.close(resolve)), new Promise(resolve => redirect.close(resolve))]);
  await writeFile(join(output, 'audit.json'), JSON.stringify({ reports, groqCalls, growthBudgets, redirectLeaks: leaks }));
}
process.on('SIGTERM', close); process.on('SIGINT', close);
