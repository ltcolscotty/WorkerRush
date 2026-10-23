import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const mode = __ENV.GAME_MODE || 'practice';
const target = __ENV.TARGET_URL;
const scored = mode === 'scored';
const stages = scored ? [
  { target: 2, duration: '60s' }, { target: 4, duration: '60s' },
  { target: 7, duration: '60s' }, { target: 3, duration: '60s' },
  { target: 1, duration: '60s' }, { target: 6, duration: '90s' },
  { target: 9, duration: '45s' }, { target: 4, duration: '75s' },
  { target: 2, duration: '45s' }, { target: 8, duration: '45s' }
] : [
  { target: 2, duration: '30s' }, { target: 6, duration: '30s' },
  { target: 2, duration: '30s' }, { target: 5, duration: '30s' }
];
export const options = {
  scenarios: { game: { executor: 'ramping-arrival-rate', startRate: 2, timeUnit: '1s', preAllocatedVUs: 30, maxVUs: 80, stages } },
  thresholds: { http_req_duration: ['p(95)<2000'] },
  summaryTrendStats: ['avg','p(90)','p(95)','max'],
};
export default function () {
  const id = `${exec.scenario.iterationInTest}-${__VU}`;
  const r = http.post(`${target}/job`, JSON.stringify({job_id:id}), {headers:{'Content-Type':'application/json'}, timeout:'2s'});
  check(r, {'completed': x => x.status === 200});
}
export function handleSummary(data) {
  return { '/tmp/k6-summary.json': JSON.stringify(data) };
}
