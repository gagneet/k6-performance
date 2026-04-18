import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET_URL = __ENV.TARGET_URL || 'https://httpbin.org/get';

// Spike test: sudden burst of traffic
export const options = {
  stages: [
    { duration: '1m', target: 5 },    // baseline
    { duration: '30s', target: 200 }, // spike!
    { duration: '2m', target: 200 },  // sustain
    { duration: '30s', target: 5 },   // recovery
    { duration: '1m', target: 5 },    // verify recovery
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.2'],
  },
};

export default function () {
  const res = http.get(TARGET_URL);
  check(res, { 'not 5xx': r => r.status < 500 });
  sleep(0.5);
}
