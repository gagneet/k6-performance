/**
 * Strata Management — Smoke Test
 * Validates the core API is healthy: login → /auth/me → building strata-roll
 *
 * Set TARGET_URL in the portal "Target URL" field (or via --env):
 *   e.g. https://eastgateresidences.com.au/api
 *
 * Required env vars:
 *   STRATA_EMAIL        test user email
 *   STRATA_PASSWORD     test user password
 *   STRATA_BUILDING_ID  building partition key (default: 13195)
 */
import http from 'k6/http';
import { check, fail, sleep } from 'k6';

const BASE = __ENV.TARGET_URL || 'https://eastgateresidences.com.au/api';
const EMAIL = __ENV.STRATA_EMAIL;
const PASSWORD = __ENV.STRATA_PASSWORD;
const BUILDING_ID = __ENV.STRATA_BUILDING_ID || '13195';

export const options = {
  vus: 1,
  iterations: 1,
  thresholds: {
    http_req_failed: ['rate==0'],
    http_req_duration: ['p(95)<5000'],
  },
};

export default function () {
  // 1. Login
  const loginRes = http.post(
    `${BASE}/auth/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  if (!check(loginRes, { 'login 200': r => r.status === 200 })) {
    fail(`Login failed: ${loginRes.status} — ${loginRes.body}`);
  }
  const token = loginRes.json('access_token');
  const h = { headers: { Authorization: `Bearer ${token}` } };

  // 2. Profile
  const meRes = http.get(`${BASE}/auth/me`, h);
  check(meRes, { '/auth/me 200': r => r.status === 200 });

  // 3. Strata roll (core building data)
  const rollRes = http.get(`${BASE}/building/strata-roll?building_id=${BUILDING_ID}`, h);
  check(rollRes, {
    'strata-roll 200': r => r.status === 200,
    'strata-roll non-empty': r => r.body.length > 10,
  });

  // 4. Documents listing
  const docsRes = http.get(`${BASE}/documents?building_id=${BUILDING_ID}&limit=5`, h);
  check(docsRes, { 'documents 2xx': r => r.status < 300 });

  sleep(1);
}
