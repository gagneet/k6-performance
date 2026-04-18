import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET_URL = __ENV.TARGET_URL || 'https://httpbin.org/get';

// Stress test: push beyond expected capacity to find breaking point
export const options = {
  stages: [
    { duration: '2m', target: 20 },
    { duration: '2m', target: 50 },
    { duration: '2m', target: 100 },
    { duration: '2m', target: 150 },
    { duration: '2m', target: 200 },
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.15'],
    http_req_duration: ['p(95)<3000'],
  },
};

export default function () {
  const res = http.get(TARGET_URL);
  check(res, { 'not 5xx': r => r.status < 500 });
  sleep(1);
}
