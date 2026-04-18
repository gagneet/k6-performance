/**
 * Strata Management — Authenticated API Load Test
 * Logs in once (setup phase) to avoid the 10 req/min rate limit on /auth/login,
 * then runs concurrent reads across the main API endpoints.
 *
 * Set TARGET_URL in the portal "Target URL" field:
 *   e.g. https://eastgateresidences.com.au/api
 *
 * Required env vars:
 *   STRATA_EMAIL / STRATA_PASSWORD / STRATA_BUILDING_ID
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

// Single login before load phase — token shared across all VUs via setup().
export function setup() {
  const res = http.post(
    `${BASE}/auth/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  if (res.status !== 200) {
    throw new Error(`Setup login failed (${res.status}): ${res.body}`);
  }
  return { token: res.json('access_token') };
}

export default function ({ token }) {
  const h = { headers: { Authorization: `Bearer ${token}` } };
  const bq = `building_id=${BUILDING_ID}`;

  group('user profile', () => {
    const r = http.get(`${BASE}/auth/me`, { ...h, tags: { endpoint: 'auth-me' } });
    check(r, { 'me 200': res => res.status === 200 });
  });

  group('building data', () => {
    const r = http.get(`${BASE}/building/strata-roll?${bq}`, {
      ...h, tags: { endpoint: 'strata-roll' },
    });
    check(r, { 'strata-roll 200': res => res.status === 200 });
  });

  group('documents', () => {
    const r = http.get(`${BASE}/documents?${bq}&limit=20`, {
      ...h, tags: { endpoint: 'documents' },
    });
    check(r, { 'documents 2xx': res => res.status < 300 });
  });

  group('announcements', () => {
    const r = http.get(`${BASE}/announcements?${bq}&limit=10`, {
      ...h, tags: { endpoint: 'announcements' },
    });
    check(r, { 'announcements 2xx': res => res.status < 300 });
  });

  sleep(Math.random() * 2 + 1);
}
