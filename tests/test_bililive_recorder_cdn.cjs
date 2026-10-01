const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const source = fs.readFileSync(path.join(__dirname, '../packages/bililive-recorder-cdn.js'), 'utf8')
  .replace('__CDN_PRIORITY__', JSON.stringify(['ov-gotcha05', 'ov-gotcha07', 'ov-gotcha04']));

function harness() {
  const storage = new Map();
  const clock = { now: 100000000 };
  const response = { ok: true, body: '' };
  const context = {
    URL, recorderCookie: 'test-cookie',
    Date: { now: () => clock.now },
    console: { info() {}, warn() {} },
    sharedStorage: { getItem: key => storage.get(key) || null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    fetchSync(url, opts) { assert.equal(opts.headers.Cookie, 'test-cookie'); return response; }
  };
  const data = { roomid: 123, qn: [10000], qn_v2: [{ qn: 10000, codec: 'avc' }] };
  function fetch(hosts, codec = 'avc', qn = 10000) {
    response.body = JSON.stringify({ code: 0, data: { playurl_info: { playurl: { stream: [{
      protocol_name: 'http_stream', format: [{ format_name: 'flv', codec: [{
        codec_name: codec, current_qn: qn, base_url: '/live.flv',
        url_info: hosts.map(host => ({ host: `https://d1--${host}.bilivideo.com`, extra: `?cdn=${host.replace(/07b$/, '07')}&sign=original` }))
      }] }]
    }] } } } });
    // Jint re-executes the script for each event; only sharedStorage survives.
    const sandbox = vm.createContext({ ...context });
    vm.runInContext(source, sandbox);
    assert.equal(sandbox.recorderEvents.onFetchStreamUrl(data), null);
    const original = 'https://d1--ov-gotcha07.bilivideo.com/live.flv?cdn=ov-gotcha07&sign=original';
    const selected = sandbox.recorderEvents.onTransformStreamUrl(original);
    if (selected) assert.equal(sandbox.recorderEvents.onTransformStreamUrl(selected), null);
    return selected;
  }
  return { fetch, clock, response, data };
}

test('chooses ov05 without rewriting signed URLs, then cools down failed CDN', () => {
  const h = harness();
  const hosts = ['ov-gotcha07b', 'ov-gotcha04', 'ov-gotcha05'];
  assert.equal(h.fetch(hosts), 'https://d1--ov-gotcha05.bilivideo.com/live.flv?cdn=ov-gotcha05&sign=original');
  h.clock.now += 10000;
  assert.match(h.fetch(hosts), /d1--ov-gotcha07b/);
  h.clock.now += 10000;
  assert.match(h.fetch(hosts), /d1--ov-gotcha04/);
  h.clock.now += 310000;
  assert.match(h.fetch(hosts), /d1--ov-gotcha05/);
});
test('uses available backup when preferred CDN is absent', () => {
  assert.match(harness().fetch(['ov-gotcha04', 'ov-gotcha07']), /d1--ov-gotcha07/);
});
test('keeps a usable candidate when every CDN is cooling down', () => {
  const h = harness();
  assert.match(h.fetch(['ov-gotcha05']), /ov-gotcha05/);
  h.clock.now += 1000;
  assert.match(h.fetch(['ov-gotcha05']), /ov-gotcha05/);
});
test('new room is independent and long idle resets to primary', () => {
  const h = harness();
  h.fetch(['ov-gotcha05', 'ov-gotcha07']);
  h.data.roomid = 456;
  assert.match(h.fetch(['ov-gotcha05', 'ov-gotcha07']), /ov-gotcha05/);
  h.clock.now += 7 * 3600000;
  assert.match(h.fetch(['ov-gotcha05', 'ov-gotcha07']), /ov-gotcha05/);
});
test('API failure, empty streams or incompatible quality preserve built-in selection', () => {
  const h = harness();
  h.response.ok = false;
  assert.equal(h.fetch(['ov-gotcha05']), null);
  h.response.ok = true;
  assert.equal(h.fetch([]), null);
  assert.equal(h.fetch(['ov-gotcha05'], 'hevc'), null);
  assert.equal(h.fetch(['ov-gotcha05'], 'avc', 400), null);
});
