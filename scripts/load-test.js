import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET_URL = __ENV.TARGET_URL || 'https://httpbin.org/get';

export const options = {
  stages: [
    { duration: '2m', target: 10 },   // ramp-up
    { duration: '5m', target: 10 },   // steady load
    { duration: '2m', target: 0 },    // ramp-down
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(90)<800', 'p(95)<1200'],
  },
};

export default function () {
  const params = { headers: { 'Content-Type': 'application/json' } };
  const res = http.get(TARGET_URL, params);

  check(res, {
    'status 2xx': r => r.status >= 200 && r.status < 300,
    'p95 < 1200ms': r => r.timings.duration < 1200,
  });
  sleep(Math.random() * 2 + 0.5);
}
