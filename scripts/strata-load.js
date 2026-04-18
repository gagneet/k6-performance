/**
 * Strata Management — Authenticated API Load Test
 *
 * Auth strategy (why this design):
 *   - JWT TTL is 24h, so expiry during a ≤5-min test is not a risk.
 *   - Login endpoint is rate-limited to 10 req/min. setup() authenticates
 *     ONCE before VUs start; the token is deep-copied to every VU by k6.
 *   - Each iteration checks for 401 and re-authenticates defensively, so
 *     the test survives session invalidation or token rotation mid-run.
 *   - vuSetup() lifecycle hooks are not yet released in k6 v1.x, so the
 *     __ITER === 0 pattern is used to let each VU log its own session on
 *     its first iteration. VUs ramp up naturally, spreading login requests
 *     across the ramp-up period without bursting the rate limit.
 *
 * Set TARGET_URL in the portal "Target URL" field:
 *   https://eastgateresidences.com.au/api
 *
 * Required env vars (set in portal Env Vars field):
 *   STRATA_EMAIL        test user email
 *   STRATA_PASSWORD     test user password
 *   STRATA_BUILDING_ID  building partition key (default: 13195)
 */
import http from 'k6/http';
import { check, sleep, group } from 'k6';

const BASE = __ENV.TARGET_URL || 'https://eastgateresidences.com.au/api';
const EMAIL = __ENV.STRATA_EMAIL;
const PASSWORD = __ENV.STRATA_PASSWORD;
const BUILDING_ID = __ENV.STRATA_BUILDING_ID || '13195';

export const options = {
  stages: [
    { duration: '1m', target: 10 },
    { duration: '3m', target: 10 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.02'],
    http_req_duration: ['p(90)<2000', 'p(95)<3500'],
    'http_req_duration{endpoint:auth-me}': ['p(95)<800'],
    'http_req_duration{endpoint:strata-roll}': ['p(95)<3000'],
    'http_req_duration{endpoint:documents}': ['p(95)<3000'],
  },
};

// Module-level token store: one token per VU (VU state persists across iterations).
// k6 VU state is isolated — no cross-VU sharing.
let vuToken = null;

function login() {
  const res = http.post(
    `${BASE}/auth/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' }, tags: { endpoint: 'auth-login' } },
  );
  if (res.status !== 200) {
    console.error(`VU ${__VU} login failed (${res.status}): ${res.body.slice(0, 200)}`);
    return null;
  }
  return res.json('access_token');
}

export default function () {
  // Each VU authenticates on its first iteration. VUs ramp up gradually
  // (per options.stages) so logins are naturally spread across the ramp-up
  // window — no burst on the rate-limited login endpoint.
  if (__ITER === 0) {
    vuToken = login();
    if (!vuToken) return; // skip iteration if auth failed
  }

  const h = (extra = {}) => ({
    headers: { Authorization: `Bearer ${vuToken}`, 'Content-Type': 'application/json' },
    ...extra,
  });
  const bq = `building_id=${BUILDING_ID}`;

  group('user profile', () => {
    const r = http.get(`${BASE}/auth/me`, h({ tags: { endpoint: 'auth-me' } }));

    // 401 = token was invalidated; re-authenticate and retry once
    if (r.status === 401) {
      vuToken = login();
      if (!vuToken) return;
      const retry = http.get(`${BASE}/auth/me`, h({ tags: { endpoint: 'auth-me' } }));
      check(retry, { 'me 200 after re-auth': res => res.status === 200 });
      return;
    }
    check(r, { 'me 200': res => res.status === 200 });
  });

  group('building data', () => {
    const r = http.get(`${BASE}/building/strata-roll?${bq}`, h({ tags: { endpoint: 'strata-roll' } }));
    check(r, { 'strata-roll 200': res => res.status === 200 });
  });

  group('documents', () => {
    const r = http.get(`${BASE}/documents?${bq}&limit=20`, h({ tags: { endpoint: 'documents' } }));
    check(r, { 'documents 2xx': res => res.status < 300 });
  });

  group('announcements', () => {
    const r = http.get(`${BASE}/announcements?${bq}&limit=10`, h({ tags: { endpoint: 'announcements' } }));
    check(r, { 'announcements 2xx': res => res.status < 300 });
  });

  sleep(Math.random() * 2 + 1);
}
