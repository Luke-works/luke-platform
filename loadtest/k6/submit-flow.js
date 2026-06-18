// Luke engine load-test — finds the throughput "knee" for the form-submit path
// (and, optionally, raw engine process-start).
//
// Run with k6 (https://k6.io). This is an OPEN-MODEL test: it drives a target
// ARRIVAL RATE (requests/sec) and ramps it up. Where p95 latency or the error
// rate breaks the thresholds, that arrival rate is your practical ceiling.
//
//   k6 run -e BASE_URL=https://platform-qa-engine.onrender.com \
//          -e TENANT_ID=loadtest -e FORM_CODE=loadtest-form \
//          -e AUTH_HEADER="Bearer <act-as-user-jwt>" \
//          -e MAX_RATE=50 k6/submit-flow.js
//
// Scenarios (SCENARIO env): submit_flow (default) | engine_start | all
//   submit_flow  — POST /api/form-instances  then  POST .../{id}/submit
//                  (the real user flow; exercises capability + engine + DB)
//   engine_start — POST /engine-rest/process-definition/key/<key>/start
//                  (isolates raw engine/job-executor throughput; needs ENGINE_AUTH)
//
// ⚠️  Run against a STAGED/throwaway env (qa/uat), never prod: every iteration
//     creates real rows and starts real process instances. See README for cleanup.

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// ---- config (all via -e ENV) -------------------------------------------------
const BASE_URL    = (__ENV.BASE_URL    || 'http://localhost:8082').replace(/\/+$/, '');
const ENGINE_URL  = (__ENV.ENGINE_URL  || BASE_URL).replace(/\/+$/, '');     // where /engine-rest lives
const TENANT_ID   = __ENV.TENANT_ID    || 'loadtest-tenant';
const USER_ID     = __ENV.USER_ID      || 'loadtest-user';
const FORM_CODE   = __ENV.FORM_CODE    || 'loadtest-form';
const AUTH_HEADER = __ENV.AUTH_HEADER  || '';   // attached to /api/*  e.g. "Bearer .." / "Basic .."
const ENGINE_AUTH = __ENV.ENGINE_AUTH  || '';   // attached to /engine-rest/*  e.g. "Basic <b64 admin:admin>"
const PROC_KEY    = __ENV.PROC_KEY     || 'FormSubmissionIntakeProcess';
const SCENARIO    = __ENV.SCENARIO     || 'submit_flow';
const MAX_RATE    = Number(__ENV.MAX_RATE  || 50);  // peak target requests/sec to ramp to
const STAGE_SEC   = Number(__ENV.STAGE_SEC || 30);  // seconds per ramp stage

// ---- custom metrics ----------------------------------------------------------
const createDur   = new Trend('luke_create_duration', true);
const submitDur   = new Trend('luke_submit_duration', true);
const startDur    = new Trend('luke_engine_start_duration', true);
const procStarted = new Rate('luke_process_started');   // did the intake process actually start?
const errors      = new Counter('luke_errors');

function apiHeaders() {
  const h = { 'Content-Type': 'application/json', 'X-Tenant-Id': TENANT_ID, 'X-User-Id': USER_ID };
  if (AUTH_HEADER) h['Authorization'] = AUTH_HEADER;
  return h;
}
function engineHeaders() {
  const h = { 'Content-Type': 'application/json', 'X-Tenant-Id': TENANT_ID };
  if (ENGINE_AUTH) h['Authorization'] = ENGINE_AUTH;
  return h;
}

// staged ramp toward MAX_RATE — the knee where thresholds break ≈ capacity
function ramp(peak) {
  return [
    { target: Math.max(1, Math.round(peak * 0.10)), duration: `${STAGE_SEC}s` },
    { target: Math.max(2, Math.round(peak * 0.25)), duration: `${STAGE_SEC}s` },
    { target: Math.max(5, Math.round(peak * 0.50)), duration: `${STAGE_SEC}s` },
    { target: peak,                                  duration: `${STAGE_SEC}s` },
    { target: peak,                                  duration: `${STAGE_SEC}s` }, // hold at peak
    { target: 0,                                     duration: '15s' },
  ];
}

function arrivalScenario(exec) {
  return {
    executor: 'ramping-arrival-rate',
    exec,
    startRate: 1,
    timeUnit: '1s',
    preAllocatedVUs: Math.max(20, MAX_RATE),
    maxVUs: Math.max(50, MAX_RATE * 5),
    stages: ramp(MAX_RATE),
  };
}

const ALL = {
  submit_flow:  arrivalScenario('submitFlow'),
  engine_start: arrivalScenario('engineStart'),
};

export const options = {
  scenarios: SCENARIO === 'all' ? ALL : { [SCENARIO]: ALL[SCENARIO] },
  thresholds: {
    http_req_failed:        ['rate<0.01'],     // <1% transport/HTTP errors
    luke_submit_duration:   ['p(95)<2000'],    // submit p95 under 2s
    luke_process_started:   ['rate>0.95'],     // >95% of submits actually started a process
  },
};

const SAMPLE_DATA = { note: 'load-test', amount: 42 };

// ---- scenario A: realistic form submit → process start -----------------------
export function submitFlow() {
  // 1) create an instance of the published form
  const createBody = JSON.stringify({ definitionCode: FORM_CODE, prefill: {}, context: { source: 'loadtest' } });
  const c = http.post(`${BASE_URL}/api/form-instances`, createBody, { headers: apiHeaders(), tags: { op: 'create' } });
  createDur.add(c.timings.duration);
  if (!check(c, { 'create -> 201': r => r.status === 201 })) { errors.add(1); return; }

  const id = c.json('instance.id');
  if (!id) { errors.add(1); return; }

  // 2) submit it — this persists the submission and starts the intake process
  const submitBody = JSON.stringify({ data: SAMPLE_DATA });
  const s = http.post(`${BASE_URL}/api/form-instances/${id}/submit`, submitBody, { headers: apiHeaders(), tags: { op: 'submit' } });
  submitDur.add(s.timings.duration);
  if (!check(s, { 'submit -> 200': r => r.status === 200 })) { errors.add(1); procStarted.add(false); return; }

  // confirm the process actually started (recorded on instance.context by ProcessStarter)
  const status = s.json('instance.context.processStartStatus');
  const pid    = s.json('instance.context.processInstanceId');
  procStarted.add(status === 'STARTED' || (!!pid && pid !== ''));
}

// ---- scenario B: raw engine throughput (no form layer) -----------------------
// Variables mirror what InternalProcessController sets, so a BPMN that reads
// formData/formMetaData still executes. Adjust if your process needs others.
export function engineStart() {
  const body = JSON.stringify({
    businessKey: `lt-${__VU}-${__ITER}`,
    variables: {
      formData:     { value: JSON.stringify(SAMPLE_DATA), type: 'Json' },
      formMetaData: { value: JSON.stringify({ source: 'loadtest', tenantId: TENANT_ID }), type: 'Json' },
    },
  });
  const r = http.post(`${ENGINE_URL}/engine-rest/process-definition/key/${PROC_KEY}/start`,
    body, { headers: engineHeaders(), tags: { op: 'engine_start' } });
  startDur.add(r.timings.duration);
  if (!check(r, { 'engine start -> 200': res => res.status === 200 })) errors.add(1);
}
