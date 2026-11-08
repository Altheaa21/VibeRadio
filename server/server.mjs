import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import api from '@neteasecloudmusicapienhanced/api';

// NetEase may return an HTTP CDN address; Apple media loading requires HTTPS.
// Keep the signed path/query byte-for-byte, changing only the transport scheme.
export function secureAudioURL(address) {
  if (typeof address !== 'string') return address;
  try {
    const url = new URL(address);
    if (url.protocol === 'http:' && (url.hostname.endsWith('.music.126.net') || url.hostname.endsWith('.music.163.com'))) {
      return address.replace(/^http:/i, 'https:');
    }
  } catch {}
  return address;
}

// Keep credentials on the device. This bridge never persists upstream cookies.
const routes = {
  '/qr/key': ['login_qr_key', () => ({})],
  '/qr/create': ['login_qr_create', p => ({ key: p.key, qrimg: true })],
  '/qr/check': ['login_qr_check', p => ({ key: p.key })],
  '/account': ['user_account', () => ({})],
  '/playlists': ['user_playlist', p => ({ uid: p.uid, limit: 100, offset: p.offset || 0 })],
  '/tracks': ['playlist_track_all', p => ({ id: p.id, limit: 100, offset: p.offset || 0 })],
  '/playlist/detail': ['playlist_detail', p => ({ id: p.id })],
  '/search': ['cloudsearch', p => ({ keywords: String(p.keywords || '').slice(0, 80), type: 1, limit: Math.min(Math.max(Number(p.limit) || 10, 1), 30), offset: Math.min(Math.max(Number(p.offset) || 0, 0), 300) })],
  '/lyric': ['lyric', p => ({ id: Number(p.id) || 0 })],
  // Writes to the user's own NetEase "liked songs"; the app only calls it after the user turns sync on.
  '/like': ['like', p => ({ id: Number(p.id) || 0, like: p.like === false ? 'false' : 'true' })],
  '/likelist': ['likelist', p => ({ uid: Number(p.uid) || 0 })],
  '/song/detail': ['song_detail', p => ({ ids: (Array.isArray(p.ids) ? p.ids : []).slice(0, 50).map(Number).filter(Boolean).join(',') })],
  '/stream': ['song_url_v1', p => ({ id: p.id, level: 'standard', unblock: 'false', crypto: 'weapi', timeout: 15000 })],
};
// Constant-time token check so the bridge token cannot be guessed byte by byte over the network.
function tokenMatches(header, token) {
  const given = Buffer.from(String(header || ''));
  const expected = Buffer.from(`Bearer ${token}`);
  return given.length === expected.length && timingSafeEqual(given, expected);
}
// Now-playing handoff between the user's devices. Memory only, newest per account, never written to disk.
const MAX_SYNC_ACCOUNTS = 20;
export function createBridge(provider = api, token = process.env.BRIDGE_TOKEN || '') {
  const syncState = new Map();
  return http.createServer(async (req, res) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    const send = (status, body) => { res.writeHead(status); res.end(JSON.stringify(body)); };
    // Liveness probe for hosting platforms (Render health check). Reveals nothing and needs no token.
    if (req.method === 'GET' && req.url === '/healthz') return send(200, { ok: true });
    if (req.method !== 'POST') return send(405, { error: 'POST required' });
    if (token && !tokenMatches(req.headers.authorization, token)) return send(401, { error: 'Bridge token required' });
    if (req.url === '/health') return send(200, { ok: true });
    if (req.url === '/sync/publish' || req.url === '/sync/latest') {
      let raw = '';
      for await (const chunk of req) { raw += chunk; if (raw.length > 4096) return send(413, { error: 'Request too large' }); }
      let p; try { p = JSON.parse(raw || '{}'); } catch { return send(400, { error: 'Bad JSON' }); }
      const account = String(Number(p.account) || '');
      if (!account || !req.headers['x-ncm-cookie']) return send(401, { error: '请先扫码登录' });
      if (req.url === '/sync/latest') return send(200, { state: syncState.get(account) || null });
      const t = p.track || {};
      const state = { device: String(p.device || '').slice(0, 40), playing: p.playing === true, elapsed: Math.max(0, Number(p.elapsed) || 0),
        track: { id: Number(t.id) || 0, name: String(t.name || '').slice(0, 120), artist: String(t.artist || '').slice(0, 120), milliseconds: Number(t.milliseconds) || 0 }, at: Date.now() };
      syncState.delete(account); syncState.set(account, state);
      while (syncState.size > MAX_SYNC_ACCOUNTS) syncState.delete(syncState.keys().next().value);
      return send(200, { ok: true });
    }
    const route = routes[req.url];
    if (!route) return send(404, { error: 'Unknown endpoint' });
    try {
      let raw = '';
      for await (const chunk of req) { raw += chunk; if (raw.length > 8192) return send(413, { error: 'Request too large' }); }
      const params = JSON.parse(raw || '{}');
      const cookie = req.headers['x-ncm-cookie'] || '';
      if (!['/qr/key', '/qr/create', '/qr/check'].includes(req.url) && !cookie) return send(401, { error: '请先扫码登录' });
      const result = await provider[route[0]]({ ...route[1](params), cookie, timestamp: Date.now() });
      if (req.url === '/playlist/detail' && result.body?.playlist) {
        const { id, name, tags, description, trackCount } = result.body.playlist;
        return send(200, { code: result.body.code, playlist: { id, name, tags, description, trackCount } });
      }
      if (req.url === '/lyric') {
        return send(200, { code: result.body?.code ?? 200, lrc: String(result.body?.lrc?.lyric || ''), translation: String(result.body?.tlyric?.lyric || ''), pure: result.body?.pureMusic === true || result.body?.nolyric === true });
      }
      if (req.url === '/stream' && Array.isArray(result.body?.data)) {
        return send(200, { ...result.body, data: result.body.data.map(track => ({ ...track, url: secureAudioURL(track.url) })) });
      }
      return send(200, result.body);
    } catch (e) {
      const code = Number(e?.body?.code) || null;
      const message = code === -460 ? '网易云暂时拒绝了当前网络的请求，请稍后重试（-460）' : code === 301 ? '登录已失效，请重新扫码' : '网易云请求失败，请稍后重试';
      // Never log upstream errors: they can contain authentication headers.
      return send(502, { error: message, upstreamCode: code });
    }
  });
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const host = process.env.HOST || '127.0.0.1';
  // Anything reachable beyond this Mac (LAN or cloud, e.g. Render with HOST=0.0.0.0) must use a long random token.
  if (host !== '127.0.0.1' && host !== 'localhost' && (process.env.BRIDGE_TOKEN || '').length < 32) {
    throw new Error('Network access requires BRIDGE_TOKEN of at least 32 characters');
  }
  createBridge().listen(Number(process.env.PORT || 3300), host, () => console.log(`VibeRadio bridge listening on ${host}:${process.env.PORT || 3300}`));
}
