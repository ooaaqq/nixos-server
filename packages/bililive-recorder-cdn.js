// Executed by BililiveRecorder's Jint runtime. Cookie is injected at activation.
const cdnPriority = __CDN_PRIORITY__;
const reconnectWindowMs = 6 * 60 * 60 * 1000;
const cooldownMs = 5 * 60 * 1000;

recorderEvents = {
    onFetchStreamUrl(data) {
        try {
            const cacheKey = "cdn-candidates:" + data.roomid;
            const oldKeys = JSON.parse(sharedStorage.getItem(cacheKey) || "[]");
            for (const key of oldKeys) sharedStorage.removeItem(key);
            sharedStorage.removeItem(cacheKey);
            const response = fetchSync(
                "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo" +
                "?room_id=" + data.roomid + "&protocol=0&format=0&codec=0,1" +
                "&qn=" + data.qn[0] + "&platform=web&ptype=8&dolby=5",
                { headers: {
                    Cookie: recorderCookie,
                    Referer: "https://live.bilibili.com/",
                    Origin: "https://live.bilibili.com",
                    "User-Agent": "Mozilla/5.0"
                } }
            );
            if (!response.ok) return null;
            const body = JSON.parse(response.body);
            if (body.code !== 0) return null;
            const streams = body.data?.playurl_info?.playurl?.stream || [];
            const preferences = data.qn_v2 || data.qn.map(qn => ({ qn, codec: "avc" }));
            let candidates = [];
            for (const preference of preferences) {
                for (const stream of streams) {
                    if (stream.protocol_name !== "http_stream") continue;
                    for (const format of stream.format || []) {
                        if (format.format_name !== "flv") continue;
                        for (const codec of format.codec || []) {
                            if (codec.codec_name !== preference.codec || codec.current_qn !== preference.qn) continue;
                            for (const info of codec.url_info || []) {
                                const url = info.host + codec.base_url + info.extra;
                                const host = new URL(url).hostname;
                                const cdn = new URL(url).searchParams.get("cdn") ||
                                    (host.match(/(ov-gotcha\d+)/) || [])[1] || host;
                                candidates.push({ url, host, cdn });
                            }
                        }
                    }
                }
                if (candidates.length) break;
            }
            if (!candidates.length) return null;
            const keys = [];
            const attempt = Date.now() + ":" + Math.random();
            for (const candidate of candidates) {
                const key = "cdn-path:" + new URL(candidate.url).pathname;
                if (keys.includes(key)) continue;
                keys.push(key);
                sharedStorage.setItem(key, JSON.stringify({ roomid: data.roomid, attempt, candidates }));
            }
            sharedStorage.setItem(cacheKey, JSON.stringify(keys));
        } catch (_) {
            console.warn("CDN candidates unavailable; using recorder default selection");
        }
        // Keep native quality negotiation and file metadata intact.
        return null;
    },
    onTransformStreamUrl(originalUrl) {
        try {
            const keyPath = "cdn-path:" + new URL(originalUrl).pathname;
            const cache = JSON.parse(sharedStorage.getItem(keyPath) || "null");
            if (!cache) return null;
            let candidates = cache.candidates;
            const nonMcdn = candidates.filter(candidate => !candidate.host.includes(".mcdn."));
            if (nonMcdn.length) candidates = nonMcdn;
            const key = "cdn-policy:" + cache.roomid;
            const now = Date.now();
            const state = JSON.parse(sharedStorage.getItem(key) || "{}");
            if (state.attempt === cache.attempt) return null; // Do not rewrite redirects again.
            const blocked = state.blocked || {};
            for (const cdn of Object.keys(blocked)) {
                if (blocked[cdn] <= now) delete blocked[cdn];
            }
            // The hook runs on recording starts/reconnects, not hourly file cuts.
            if (state.lastCdn && now - state.selectedAt < reconnectWindowMs) {
                blocked[state.lastCdn] = now + cooldownMs;
            }
            function rank(candidate) {
                const index = cdnPriority.indexOf(candidate.cdn);
                return index < 0 ? cdnPriority.length : index;
            }
            candidates.sort((a, b) => rank(a) - rank(b));
            const selected = candidates.find(candidate => !blocked[candidate.cdn]) || candidates[0];
            sharedStorage.setItem(key, JSON.stringify({ lastCdn: selected.cdn, selectedAt: now, blocked, attempt: cache.attempt }));
            console.info("CDN policy room=" + cache.roomid + " selected=" + selected.host);
            return selected.url;
        } catch (_) {
            // Preserve the recorder's built-in selection on API/script failure.
            console.warn("CDN policy unavailable; using recorder default selection");
            return null;
        }
    }
};
