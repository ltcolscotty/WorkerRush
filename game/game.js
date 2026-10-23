import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const target = __ENV.TARGET_URL;
// Stages are generated per round by round_plan.py (jittered per seed in scored mode).
const plan = JSON.parse(open(__ENV.SCHEDULE_FILE || '/tmp/game-schedule.json'));
export const options = {
  scenarios: { game: { executor: 'ramping-arrival-rate', startRate: plan.startRate, timeUnit: '1s', preAllocatedVUs: 30, maxVUs: 80, stages: plan.stages } },
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
