import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET_URL = __ENV.TARGET_URL || 'https://httpbin.org/get';

// Soak test: moderate load over a long duration to detect memory leaks / degradation
export const options = {
  stages: [
    { duration: '5m', target: 20 },
    { duration: '4h', target: 20 },  // adjust as needed
    { duration: '5m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1500'],
  },
};

export default function () {
  const res = http.get(TARGET_URL);
  check(res, {
    'status 200': r => r.status === 200,
    'body not empty': r => r.body.length > 0,
  });
  sleep(2);
}
