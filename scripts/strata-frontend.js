/**
 * Strata Management — Next.js Frontend Load Test
 * Tests the public-facing site (HTML page load, static assets, API health).
 *
 * Set TARGET_URL in the portal "Target URL" field:
 *   e.g. https://eastgateresidences.com.au
 */
import http from 'k6/http';
import { check, sleep, group } from 'k6';

const FRONT = __ENV.TARGET_URL || 'https://eastgateresidences.com.au';

export const options = {
  stages: [
    { duration: '1m', target: 5 },
    { duration: '3m', target: 5 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<5000'],
    'http_req_duration{page:home}': ['p(95)<3000'],
    'http_req_duration{page:login}': ['p(95)<3000'],
    'http_req_duration{page:api-health}': ['p(95)<1000'],
  },
};

export default function () {
  group('home page', () => {
    const r = http.get(`${FRONT}/`, { tags: { page: 'home' } });
    check(r, { 'home 200': res => res.status === 200 });
  });

  group('login page', () => {
    const r = http.get(`${FRONT}/login`, { tags: { page: 'login' } });
    check(r, { 'login 200': res => res.status === 200 });
  });

  group('api reachability', () => {
    const r = http.get(`${FRONT}/api/health`, { tags: { page: 'api-health' } });
    // 200 or 404 both indicate the server is up; 5xx means it's down
    check(r, { 'api reachable': res => res.status < 500 });
  });

  sleep(Math.random() * 3 + 1);
}
