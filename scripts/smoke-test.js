import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET_URL = __ENV.TARGET_URL || 'https://httpbin.org/get';

export const options = {
  vus: 1,
  duration: '30s',
  thresholds: {
    http_req_failed: ['rate<0.01'],       // <1% errors
    http_req_duration: ['p(95)<1000'],    // 95% under 1s
  },
};

export default function () {
  const res = http.get(TARGET_URL);
  check(res, {
    'status 200': r => r.status === 200,
    'response time < 1s': r => r.timings.duration < 1000,
  });
  sleep(1);
}
