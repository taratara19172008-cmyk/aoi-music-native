// Harness for the bundled native engine (AoiMusic/engine.html).
// Verifies: (1) every inline script parses (node new Function, full
// script, nothing stripped); (2) the v109.3 relay layer rewrites
// exactly the sw.js rule set; (3) the playback core against a fake
// MusicKit that models what the device logs showed: setQueue ignores
// startIndex (position stays 0), jumps can abort or "settle" without
// landing, and ids can be unresolvable in the storefront.
// The fake's queue.append / playLater model the real musickit.js
// signatures (append takes MediaItem arrays; playLater takes a
// setQueue-style descriptor) - the v109.8 append bug shipped
// because the old fake accepted the wrong shape.
'use strict';
const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync(__dirname + '/../AoiMusic/engine.html', 'utf8');
const scripts = [];
for (const m of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) scripts.push(m[1]);
if (scripts.length !== 3) { console.error('FAIL: expected 3 inline scripts, got ' + scripts.length); process.exit(1); }

for (let i = 0; i < scripts.length; i++) {
  try { new Function(scripts[i]); }
  catch (e) { console.error('FAIL: script ' + i + ' syntax: ' + e.message); process.exit(1); }
}
console.log('ok: all inline scripts parse');

const posts = [];
const rawFetchCalls = [];
const listeners = {};
const RELAY = 'https://aoi-relay.vercel.app/api/relay';

class FakeRequest {
  constructor(url, opts) {
    this.url = url; this.method = (opts && opts.method) || 'GET';
    this.headers = (opts && opts.headers) || {};
    this._body = opts && opts.body;
  }
  clone() { return new FakeRequest(this.url, { method: this.method, headers: this.headers, body: this._body }); }
  async arrayBuffer() { return Buffer.from(String(this._body || '')); }
}
class FakeXHR { open() { this.openArgs = Array.from(arguments); } send() {} addEventListener() {} }

function abortErr() { const e = new Error('The operation was aborted.'); e.name = 'AbortError'; return e; }

const music = {
  isAuthorized: true, isPlaying: false, playbackState: 0, storefrontId: 'cn',
  musicUserToken: 'tok', nowPlayingItem: null,
  currentPlaybackTime: 0, currentPlaybackDuration: 0, shuffleMode: 0, repeatMode: 0,
  queue: { items: [], position: -1,
    // Real MusicKit (musickit.js source): queue.append takes an
    // ARRAY of MediaItems - toQueueItems does e.map(...) on the
    // argument itself, so the {songs} object form v109.8 used
    // throws 'e.map is not a function'. Modelled faithfully.
    async append(items) {
      music.appendCalls++;
      const ids = items.map(x => String(x && x.id !== undefined ? x.id : x));
      const bad = ids.filter(id => music.unresolvable.has(id));
      if (bad.length) throw new Error('could not be resolved: ' + bad.join(', '));
      for (const id of ids) this.items.push({ id });
    } },
  _listeners: {},
  // scripting knobs for the tests
  unresolvable: new Set(), jumpAbortTimes: 0, jumpLie: false,
  jumpHang: false, playHang: false, jumpCalls: 0,
  playCalls: 0, setQueueCalls: [], playLaterCalls: [], appendCalls: 0, playLaterGate: null,
  addEventListener(n, f) { (this._listeners[n] = this._listeners[n] || []).push(f); },
  async authorize() { return 'tok'; },
  async setQueue(opts) {
    this.setQueueCalls.push(opts);
    await sandbox.fetch('https://api.music.apple.com/v1/catalog/cn/songs?ids=' + (opts.songs || []).join(','));
    const bad = (opts.songs || []).map(String).filter(id => this.unresolvable.has(id));
    if (bad.length) throw new Error('could not be resolved: ' + bad.join(', '));
    this.queue.items = (opts.songs || []).map(id => ({ id: String(id) }));
    this.queue.position = 0; // device behaviour: startIndex is ignored
    this.nowPlayingItem = this.queue.items[0] || null;
    if (opts.startPlaying) this.isPlaying = true;
  },
  async changeToMediaAtIndex(i) {
    this.jumpCalls++;
    if (this.jumpHang) return new Promise(() => {}); // never settles
    if (this.jumpAbortTimes > 0) { this.jumpAbortTimes--; throw abortErr(); }
    if (!this.jumpLie) {
      this.queue.position = i;
      this.nowPlayingItem = this.queue.items[i] || null;
    }
  },
  async playLater(opts) {
    this.playLaterCalls.push(opts);
    if (this.playLaterGate) { const g = this.playLaterGate; this.playLaterGate = null; await g; }
    const bad = (opts.songs || []).map(String).filter(id => this.unresolvable.has(id));
    if (bad.length) throw new Error('could not be resolved: ' + bad.join(', '));
    for (const id of opts.songs || []) this.queue.items.push({ id: String(id) });
  },
  async play() { this.playCalls++; if (this.playHang) return new Promise(() => {}); this.isPlaying = true; },
  async pause() {},
  async skipToNextItem() { const q = this.queue; if (q.position < q.items.length - 1) { q.position++; this.nowPlayingItem = q.items[q.position] || null; } },
  async skipToPreviousItem() { const q = this.queue; if (q.position > 0) { q.position--; this.nowPlayingItem = q.items[q.position] || null; } },
  seekToTime() {},
  reset() {
    this.queue.items = []; this.queue.position = -1; this.nowPlayingItem = null;
    this.unresolvable = new Set(); this.jumpAbortTimes = 0; this.jumpLie = false;
    this.jumpHang = false; this.playHang = false; this.jumpCalls = 0;
    this.playCalls = 0; this.setQueueCalls = []; this.isPlaying = false;
    this.playLaterCalls = []; this.appendCalls = 0; this.playLaterGate = null;
    posts.length = 0;
  },
};

const sandbox = {
  console, URL, Promise, JSON, Math, Date, Object, Array, String, Number, Boolean, RegExp, Error,
  encodeURIComponent, decodeURIComponent,
  setInterval: () => 0, clearInterval: () => {}, setTimeout: setTimeout, clearTimeout: clearTimeout,
  location: { href: 'https://music.apple.com/', origin: 'https://music.apple.com' },
  localStorage: { _m: {}, getItem(k) { return k in this._m ? this._m[k] : null; }, setItem(k, v) { this._m[k] = String(v); } },
  performance: { now: () => Date.now() },
  addEventListener: () => {},
  navigator: {},
  document: { addEventListener: (n, f) => { listeners[n] = f; } },
  webkit: { messageHandlers: { aoi: { postMessage: o => posts.push(o) } } },
  Request: FakeRequest,
  XMLHttpRequest: FakeXHR,
  fetch: (input, init) => {
    rawFetchCalls.push({ url: typeof input === 'string' ? input : input.url, init });
    return Promise.resolve({ ok: true, status: 200 });
  },
  MusicKit: { configure: async () => {}, getInstance: () => music },
};
sandbox.window = sandbox;
sandbox.__aoiJumpTimeoutMs = 40;
sandbox.__aoiPlayTimeoutMs = 40;
vm.createContext(sandbox);
for (const code of scripts) vm.runInContext(code, sandbox);

let fails = 0;
function check(name, cond) {
  if (cond) console.log('ok: ' + name);
  else { fails++; console.error('FAIL: ' + name); }
}
const lastRaw = () => rawFetchCalls[rawFetchCalls.length - 1].url;
const errPosts = () => posts.filter(p => p.type === 'error');
const logHas = re => posts.some(p => p.type === 'log' && re.test(p.message || ''));

(async () => {
  // ---- relay rules (v109.10: switchable, default DIRECT) ----
  rawFetchCalls.length = 0;
  await sandbox.fetch('https://api.music.apple.com/v1/catalog/cn/songs/123');
  check('v109.10 default: api fetch goes DIRECT (no relay)', lastRaw() === 'https://api.music.apple.com/v1/catalog/cn/songs/123');
  check('relay layer logged as direct', logHas(/mode=direct/));
  sandbox.AoiEngine.setRelay(true);
  rawFetchCalls.length = 0;
  await sandbox.fetch('https://api.music.apple.com/v1/catalog/cn/songs/123');
  check('relay on: api.music.apple.com fetch goes via relay', lastRaw() === RELAY + '?target=' + encodeURIComponent('https://api.music.apple.com/v1/catalog/cn/songs/123'));
  await sandbox.fetch('https://js-cdn.music.apple.com/musickit/v3/musickit.js');
  check('js-cdn fetch NOT rewritten', lastRaw() === 'https://js-cdn.music.apple.com/musickit/v3/musickit.js');
  await sandbox.fetch('https://example.com/x');
  check('non-Apple fetch NOT rewritten', lastRaw() === 'https://example.com/x');
  await sandbox.fetch(RELAY + '?target=abc');
  check('relay URL NOT double-rewritten', lastRaw() === RELAY + '?target=abc');
  const postReq = new FakeRequest('https://api.music.apple.com/v1/me/library/songs', { method: 'POST', body: 'payload' });
  await sandbox.fetch(postReq);
  check('Request-object POST rewritten to relay URL', lastRaw().startsWith(RELAY + '?target='));
  check('Request object passed through untouched (signal/credentials preserved)', rawFetchCalls[rawFetchCalls.length - 1].init === postReq);
  const xhr = new FakeXHR();
  xhr.open('GET', 'https://amp-api.music.apple.com/v1/catalog/cn/albums/1');
  check('amp-api XHR rewritten', xhr.openArgs[1] === RELAY + '?target=' + encodeURIComponent('https://amp-api.music.apple.com/v1/catalog/cn/albums/1'));
  const xhr2 = new FakeXHR();
  xhr2.open('GET', 'https://itunes.apple.com/lookup?id=1');
  check('non-music.apple.com XHR untouched', xhr2.openArgs[1] === 'https://itunes.apple.com/lookup?id=1');
  // relay stays ON for the playback section (the fake's setQueue
  // resolution fetch is asserted to use it below).

  // ---- boot ----
  await listeners['musickitloaded']();
  check('ready posted after configure', posts.some(p => p.type === 'ready'));
  check('auth posted (cn)', posts.some(p => p.type === 'auth' && p.storefront === 'cn'));

  // ---- playback (v109.6): rotation is the only tap path ----
  music.reset();
  await sandbox.AoiEngine.playQueue(['111', '222', '333'], 0, false, 0);
  check('@0: first setQueue is the tapped song only, startPlaying', music.setQueueCalls.length === 1 && JSON.stringify(music.setQueueCalls[0].songs) === '["111"]' && music.setQueueCalls[0].startPlaying === true);
  check('@0: play() called, no jump used', music.playCalls === 1 && music.jumpCalls === 0);
  await new Promise(r => setTimeout(r, 60));
  check('@0: rest of the list landed via playLater', JSON.stringify(music.queue.items.map(x => x.id)) === '["111","222","333"]' && music.playLaterCalls.length === 1);
  check("@0: MusicKit's resolution fetch went via relay", rawFetchCalls.some(c => c.url.startsWith(RELAY + '?target=') && c.url.includes('songs')));

  music.reset();
  await sandbox.AoiEngine.playQueue(['111', '222', '333'], 2, false, 0);
  check('@2: tapped song alone in first setQueue, startPlaying', JSON.stringify(music.setQueueCalls[0].songs) === '["333"]' && music.setQueueCalls[0].startPlaying === true);
  check('@2: target plays, changeToMediaAtIndex never called', music.nowPlayingItem.id === '333' && music.playCalls === 1 && music.jumpCalls === 0 && errPosts().length === 0);

  // ---- a hanging jump API cannot hurt: it is never called ----
  music.reset(); music.jumpHang = true;
  await sandbox.AoiEngine.playQueue(['111', '222', '333'], 2, false, 0);
  check('jump API hangs: playQueue unaffected, target plays', music.nowPlayingItem.id === '333' && music.jumpCalls === 0 && errPosts().length === 0);

  // ---- tapping the already-loaded song just plays it ----
  music.reset();
  await sandbox.AoiEngine.playQueue(['111', '222'], 0, false, 0);
  const sqLoaded = music.setQueueCalls.length, plLoaded = music.playCalls;
  await sandbox.AoiEngine.playQueue(['111', '222'], 0, false, 0);
  check('already loaded: no reload, play called again', music.setQueueCalls.length === sqLoaded && music.playCalls === plLoaded + 1 && logHas(/same song, same list/));

  // ---- tapped song itself unresolvable: stop, no substitute ----
  music.reset(); music.unresolvable = new Set(['222']);
  await sandbox.AoiEngine.playQueue(['111', '222', '333'], 1, false, 0);
  check('target unresolvable: error posted, play NOT called', music.playCalls === 0 && errPosts().some(p => /target unavailable/.test(p.message || '')));
  check('target unresolvable: logged as unavailable', logHas(/target song 222 unavailable/));

  // ---- non-target song unresolvable: dropped from rotated queue ----
  music.reset(); music.unresolvable = new Set(['111']);
  await sandbox.AoiEngine.playQueue(['111', '222', '333'], 2, false, 0);
  await new Promise(r => setTimeout(r, 60));
  check('non-target dropped: completion rebuilt the queue without it', music.setQueueCalls.length === 1 && JSON.stringify(music.queue.items.map(x => x.id)) === '["333","222"]');
  check('non-target dropped: tapped song plays', music.nowPlayingItem.id === '333' && music.playCalls === 1);

  // ---- jumpTo re-rotates by id ----
  music.reset();
  await sandbox.AoiEngine.playQueue(['111', '222', '333'], 2, false, 0);
  await new Promise(r => setTimeout(r, 60));
  await sandbox.AoiEngine.jumpTo(0);
  check('jumpTo(0): queue re-rotated, song 111 at head and playing', JSON.stringify(music.setQueueCalls[1].songs) === '["111"]' && music.nowPlayingItem.id === '111');
  await new Promise(r => setTimeout(r, 60));
  await sandbox.AoiEngine.jumpTo(2);
  check('jumpTo(2): song 333 at head', music.nowPlayingItem.id === '333' && music.jumpCalls === 0);

  // ---- play() HANGS: op still completes, chain unwedged ----
  music.reset(); music.playHang = true;
  await sandbox.AoiEngine.playQueue(['111', '222'], 0, false, 0);
  check('hanging play: playQueue returned (bounded)', logHas(/play TIMED OUT/));
  music.playHang = false;
  await sandbox.AoiEngine.playQueue(['444', '555'], 1, false, 0);
  check('hanging play: next playQueue still runs and lands', music.setQueueCalls.length === 2 && music.nowPlayingItem.id === '555');

  // ---- shuffle: rotation still applies, no errors ----
  music.reset();
  await sandbox.AoiEngine.playQueue(['111', '222', '333'], 2, true, 0);
  check('shuffle: target at head, plays, no errors', music.nowPlayingItem.id === '333' && music.playCalls === 1 && errPosts().length === 0);

  // ---- v109.9: long list - one song now, playLater completes ----
  music.reset();
  await sandbox.AoiEngine.playQueue(['1', '2', '3', '4', '5', '6'], 4, false, 0);
  check('long list: first setQueue is the tapped song only', music.setQueueCalls.length === 1 && JSON.stringify(music.setQueueCalls[0].songs) === '["5"]');
  check('long list: tapped song playing right away', music.nowPlayingItem.id === '5' && music.playCalls === 1);
  await new Promise(r => setTimeout(r, 60));
  check('long list: playLater completed the rotated queue', JSON.stringify(music.queue.items.map(x => x.id)) === '["5","6","1","2","3","4"]');
  check('long list: queue.append (MediaItem API) never used', music.appendCalls === 0);

  // ---- v109.9: a newer tap supersedes the previous queue ----
  music.reset();
  await sandbox.AoiEngine.playQueue(['1', '2', '3', '4', '5', '6'], 0, false, 0);
  await sandbox.AoiEngine.playQueue(['7', '8', '9'], 0, false, 0);
  await new Promise(r => setTimeout(r, 60));
  check('superseded: queue belongs to the newer tap only', JSON.stringify(music.queue.items.map(x => x.id)) === '["7","8","9"]');

  // ---- v109.9: unresolvable song in the tail is dropped by completion ----
  music.reset(); music.unresolvable = new Set(['3']);
  await sandbox.AoiEngine.playQueue(['1', '2', '3', '4', '5'], 0, false, 0);
  await new Promise(r => setTimeout(r, 60));
  check('tail drop: queue completed without the bad song', JSON.stringify(music.queue.items.map(x => x.id)) === '["1","2","4","5"]' && music.nowPlayingItem.id === '1');

  // ---- v109.9: Next before the completion lands rotates ----
  music.reset();
  let releaseGate;
  music.playLaterGate = new Promise(r => { releaseGate = r; });
  await sandbox.AoiEngine.playQueue(['1', '2', '3', '4', '5', '6'], 0, false, 0);
  check('gated completion: only the tapped song is loaded', JSON.stringify(music.queue.items.map(x => x.id)) === '["1"]');
  const nextP = sandbox.AoiEngine.next();
  releaseGate();
  await nextP;
  check('next before completion: rotated to song 2 and playing', music.nowPlayingItem.id === '2' && JSON.stringify(music.setQueueCalls[music.setQueueCalls.length - 1].songs) === '["2"]');
  await new Promise(r => setTimeout(r, 60));
  check('stale completion: FULL queue is exactly the new rotation, nothing appended twice', JSON.stringify(music.queue.items.map(x => x.id)) === '["2","3","4","5","6","1"]');

  // ---- v109.9: jumpTo to a not-yet-loaded song rotates ----
  music.reset();
  let releaseGate2;
  music.playLaterGate = new Promise(r => { releaseGate2 = r; });
  await sandbox.AoiEngine.playQueue(['1', '2', '3', '4', '5', '6'], 0, false, 0);
  const jumpP = sandbox.AoiEngine.jumpTo(3);
  releaseGate2();
  await jumpP;
  check('jumpTo unloaded target: rotated from the app list, song 4 playing', music.nowPlayingItem.id === '4' && JSON.stringify(music.setQueueCalls[music.setQueueCalls.length - 1].songs) === '["4"]');
  await new Promise(r => setTimeout(r, 60));

  // ---- v109.9: Next after completion uses a plain skip ----
  music.reset();
  await sandbox.AoiEngine.playQueue(['1', '2', '3'], 0, false, 0);
  await new Promise(r => setTimeout(r, 60));
  const sqBefore = music.setQueueCalls.length;
  await sandbox.AoiEngine.next();
  check('next after completion: skip only, no re-queue', music.setQueueCalls.length === sqBefore && music.nowPlayingItem.id === '2');

  // ---- v109.10: re-tapping the playing song keeps the completion alive ----
  music.reset();
  let releaseGate3;
  music.playLaterGate = new Promise(r => { releaseGate3 = r; });
  await sandbox.AoiEngine.playQueue(['1', '2', '3'], 0, false, 0);
  const sqRetap = music.setQueueCalls.length, plRetap = music.playCalls;
  await sandbox.AoiEngine.playQueue(['1', '2', '3'], 0, false, 0);
  check('re-tap same song+list: no new setQueue, play only', music.setQueueCalls.length === sqRetap && music.playCalls === plRetap + 1);
  releaseGate3();
  await new Promise(r => setTimeout(r, 60));
  check('re-tap same song+list: background completion still landed', JSON.stringify(music.queue.items.map(x => x.id)) === '["1","2","3"]');

  // ---- v109.10: same song from a DIFFERENT list rebuilds the queue ----
  music.reset();
  await sandbox.AoiEngine.playQueue(['1', '2', '3'], 0, false, 0);
  await new Promise(r => setTimeout(r, 60));
  await sandbox.AoiEngine.playQueue(['1', '9', '8'], 0, false, 0);
  await new Promise(r => setTimeout(r, 60));
  check('same song, different list: queue rebuilt from the new list', music.setQueueCalls.length === 2 && JSON.stringify(music.queue.items.map(x => x.id)) === '["1","9","8"]');

  // ---- v109.10: jumpTo with no queue context refuses (no banned API) ----
  music.reset();
  await sandbox.AoiEngine.jumpTo(0);
  check('jumpTo no queue: changeToMediaAtIndex NOT called, error posted', music.jumpCalls === 0 && errPosts().some(p => p.where === 'jumpTo'));

  console.log(fails ? ('\n' + fails + ' FAILURES') : '\nALL PASS');
  process.exit(fails ? 1 : 0);
})().catch(e => { console.error('FAIL: exception: ' + (e && e.stack || e)); process.exit(1); });
