import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createBridge, secureAudioURL } from './server.mjs';
async function withServer(provider, token, run) {
  const server = createBridge(provider, token);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const post = (path, body = {}, headers = {}) => fetch(`http://127.0.0.1:${server.address().port}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });
  try { await run(post); } finally { await new Promise(resolve => server.close(resolve)); }
}
test('bridge token and account authentication are required', async () => {
  await withServer({}, 'test-secret', async post => {
    assert.equal((await post('/health')).status, 401);
    assert.equal((await post('/health', {}, { Authorization: 'Bearer test-secret' })).status, 200);
    assert.equal((await post('/account', {}, { Authorization: 'Bearer test-secret' })).status, 401);
  });
});
test('stream requests use supplied session and never enable unlocking', async () => {
  let options;
  await withServer({ song_url_v1: async input => { options = input; return { body: { code: 200, data: [] } }; } }, '', async post => {
    const response = await post('/stream', { id: 123, unblock: 'true', cookie: 'injected' }, { 'X-NCM-Cookie': 'session-test' });
    assert.equal(response.status, 200);
    assert.equal(options.cookie, 'session-test');
    assert.equal(options.unblock, 'false');
    assert.equal(options.level, 'standard');
    // Native xeapi defaults require a missing bootstrap key. Use web protocol.
    assert.equal(options.crypto, 'weapi');
    assert.equal(options.timeout, 15000);
    assert.equal(response.headers.get('cache-control'), 'no-store');
  });
});
test('upstream errors are redacted and arbitrary API calls are rejected', async () => {
  await withServer({ user_account: async () => { throw { body: { code: 301 }, secret: 'never expose' }; } }, '', async post => {
    const response = await post('/account', {}, { 'X-NCM-Cookie': 'session-test' });
    assert.equal(response.status, 502);
    assert.equal((await response.text()).includes('never expose'), false);
    assert.equal((await post('/send/text')).status, 404);
  });
});


test('NetEase audio transport upgrade preserves signed paths and queries', () => {
  const path = '/signed/path/song.mp3?token=a+b/c==&x=%2F';
  assert.equal(secureAudioURL('http://m801.music.126.net' + path), 'https://m801.music.126.net' + path);
  assert.equal(secureAudioURL('https://m801.music.126.net' + path), 'https://m801.music.126.net' + path);
  assert.equal(secureAudioURL('http://music.126.net.evil.test/a'), 'http://music.126.net.evil.test/a');
  assert.equal(secureAudioURL(null), null);
});

test('stream responses upgrade CDN transport without changing trial metadata', async () => {
  await withServer({ song_url_v1: async () => ({ body: { code: 200, data: [{ url: 'http://m801.music.126.net/a.mp3?q=+/', freeTrialInfo: { start: 0, end: 30 } }] } }) }, '', async post => {
    const response = await post('/stream', { id: 1 }, { 'X-NCM-Cookie': 'test' });
    const body = await response.json();
    assert.equal(body.data[0].url, 'https://m801.music.126.net/a.mp3?q=+/');
    assert.deepEqual(body.data[0].freeTrialInfo, { start: 0, end: 30 });
  });
});

test('playlist metadata strips full track lists and retains actual tags', async () => {
  await withServer({playlist_detail: async () => ({body:{code:200,playlist:{id:1,name:'Pool',tags:['夜晚'],description:'Original',trackCount:1000,tracks:[{secret:'not metadata'}],creator:{nickname:'private'}}}})},'',async post=>{
    assert.equal((await post('/playlist/detail',{id:1})).status,401);
    const result=await (await post('/playlist/detail',{id:1},{'X-NCM-Cookie':'test'})).json();
    assert.deepEqual(result.playlist.tags,['夜晚']);
    assert.equal('tracks' in result.playlist,false);assert.equal('creator' in result.playlist,false);
  });
});
test('catalog search is read-only, bounded and ignores injected options',async()=>{
  let options;
  await withServer({cloudsearch:async input=>{options=input;return {body:{code:200,result:{songs:[]}}}}},'',async post=>{
    await post('/search',{keywords:'a'.repeat(200),limit:100000,type:1000,cookie:'bad'},{'X-NCM-Cookie':'test'});
    assert.equal(options.keywords.length,80);assert.equal(options.limit,30);assert.equal(options.type,1);assert.equal(options.cookie,'test');
  });
});

test('lyrics return only lyric text', async () => {
  await withServer({ lyric: async input => ({ body: { code: 200, lrc: { lyric: '[00:01.00]你好' }, tlyric: { lyric: '' }, klyric: { secret: 1 } } }) }, '', async post => {
    const body = await (await post('/lyric', { id: '5' }, { 'X-NCM-Cookie': 't' })).json();
    assert.deepEqual(body, { code: 200, lrc: '[00:01.00]你好', translation: '', pure: false });
  });
});
test('like only passes id and boolean', async () => {
  let options;
  await withServer({ like: async input => { options = input; return { body: { code: 200 } }; } }, '', async post => {
    await post('/like', { id: 9, like: false, cookie: 'bad', extra: 1 }, { 'X-NCM-Cookie': 't' });
    assert.equal(options.id, 9); assert.equal(options.like, 'false'); assert.equal(options.cookie, 't'); assert.equal('extra' in options, false);
  });
});
test('song detail bounds ids', async () => {
  let options;
  await withServer({ song_detail: async input => { options = input; return { body: { code: 200, songs: [] } }; } }, '', async post => {
    await post('/song/detail', { ids: Array.from({ length: 80 }, (_, i) => i + 1) }, { 'X-NCM-Cookie': 't' });
    assert.equal(options.ids.split(',').length, 50);
  });
});
test('sync keeps newest state per account in memory and needs a session', async () => {
  await withServer({}, '', async post => {
    assert.equal((await post('/sync/publish', { account: 1 })).status, 401);
    await post('/sync/publish', { account: 1, device: 'Mac', playing: true, elapsed: 12, track: { id: 3, name: '夜晚', artist: 'A', secret: 'x' } }, { 'X-NCM-Cookie': 't' });
    const state = (await (await post('/sync/latest', { account: 1 }, { 'X-NCM-Cookie': 't' })).json()).state;
    assert.equal(state.track.name, '夜晚'); assert.equal(state.device, 'Mac'); assert.equal('secret' in state.track, false);
    assert.equal((await (await post('/sync/latest', { account: 2 }, { 'X-NCM-Cookie': 't' })).json()).state, null);
  });
});

test('health probe answers GET without a token and leaks nothing', async () => {
  await withServer({}, 'test-secret', async () => {});
  const server = createBridge({}, 'test-secret');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const base = `http://127.0.0.1:${server.address().port}`;
    const probe = await fetch(`${base}/healthz`);
    assert.equal(probe.status, 200);
    assert.deepEqual(await probe.json(), { ok: true });
    assert.equal((await fetch(`${base}/account`)).status, 405);
    assert.equal((await fetch(`${base}/health`, { method: 'POST', headers: { Authorization: 'Bearer test-secreX' } })).status, 401);
    assert.equal((await fetch(`${base}/health`, { method: 'POST', headers: { Authorization: 'Bearer test-secret-longer' } })).status, 401);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
