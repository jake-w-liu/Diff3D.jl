import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { createHash } from 'node:crypto';
import os from 'node:os';
import { Matrix4, Vector3, REVISION } from 'three';

if (process.argv.length !== 4) throw new Error('usage: node --expose-gc projection.mjs FIXTURE_JSON OUTPUT_JSON');
if (typeof global.gc !== 'function') throw new Error('run Node with --expose-gc for retained-heap measurements');
const input = readFileSync(process.argv[2]);
const fixture = JSON.parse(input);
if (fixture.schema !== 1 || fixture.matrix.length !== 16 || !fixture.matrix.every(Number.isFinite) ||
    !Number.isInteger(fixture.samples) || fixture.samples < 1 ||
    !Number.isInteger(fixture.warmup) || fixture.warmup < 1 || !fixture.cases.length) {
  throw new Error('invalid projection fixture');
}
if (REVISION !== '186') throw new Error(`unexpected three.js revision ${REVISION}`);
const matrix = new Matrix4().fromArray(fixture.matrix);

function objectiveFor(c) {
  const point = new Vector3();
  return parameters => {
    if (parameters.length !== c.count) throw new Error('point parameter count');
    let total = 0;
    for (let i = 0; i < parameters.length; ++i) {
      point.set(c.x[i], c.y[i], parameters[i]).applyMatrix4(matrix);
      total += (point.x - c.target_x[i]) ** 2 + (point.y - c.target_y[i]) ** 2;
    }
    return total / (2 * parameters.length);
  };
}

function centralDifference(objective, parameters) {
  const work = Float64Array.from(parameters), gradient = new Float64Array(parameters.length);
  const step = 1e-5;
  for (let i = 0; i < parameters.length; ++i) {
    work[i] = parameters[i] + step;
    const plus = objective(work);
    work[i] = parameters[i] - step;
    const minus = objective(work);
    gradient[i] = (plus - minus) / (2 * step);
    work[i] = parameters[i];
  }
  return gradient;
}

const report = {status: 'failed', three_revision: REVISION, node: process.version,
  os: os.platform(), arch: os.arch(), cpu: os.cpus()[0]?.model ?? 'unavailable',
  fixture_sha256: createHash('sha256').update(input).digest('hex'), results: []};
mkdirSync(dirname(process.argv[3]), {recursive: true});
try {
  for (const c of fixture.cases) {
    if (!Number.isInteger(c.count) || c.count < 1 || !Number.isFinite(c.expected_loss)) {
      throw new Error('positive point count and finite reference loss required');
    }
    for (const key of ['x', 'y', 'parameters', 'target_x', 'target_y', 'expected_gradient', 'truth']) {
      if (c[key].length !== c.count || !c[key].every(Number.isFinite)) {
        throw new Error(`invalid fixture field ${key}`);
      }
    }
    const objective = objectiveFor(c), parameters = Float64Array.from(c.parameters);
    const loss = objective(parameters);
    if (!Number.isFinite(loss) || Math.abs(loss - c.expected_loss) > 1e-15 + 1e-12 * Math.abs(c.expected_loss)) {
      throw new Error('projection value oracle failed');
    }
    let started = process.hrtime.bigint();
    const result = centralDifference(objective, parameters);
    const first = Number(process.hrtime.bigint() - started);
    const gradientError = Math.max(...result.map((value, i) => Math.abs(value - c.expected_gradient[i])));
    if (!Number.isFinite(gradientError) || gradientError >= 1e-9) throw new Error(`gradient oracle failed: ${gradientError}`);
    for (let i = 0; i < fixture.warmup; ++i) centralDifference(objective, parameters);
    global.gc();
    const samples = [];
    for (let i = 0; i < fixture.samples; ++i) {
      started = process.hrtime.bigint();
      centralDifference(objective, parameters);
      samples.push(Number(process.hrtime.bigint() - started));
    }
    let evaluations = 0;
    centralDifference(p => { evaluations++; return objective(p); }, parameters);
    global.gc();
    const before = process.memoryUsage();
    const retained = centralDifference(objective, parameters);
    global.gc();
    const after = process.memoryUsage();
    const record = {method: 'central_difference', count: c.count, loss,
      gradient: Array.from(result), gradient_max_error: gradientError,
      objective_evaluations: evaluations, first_invocation_ns: first, samples_ns: samples,
      retained_heap_delta_bytes: after.heapUsed - before.heapUsed,
      retained_array_buffer_delta_bytes: after.arrayBuffers - before.arrayBuffers,
      result_bytes: retained.byteLength, rss_bytes: after.rss};
    if (c.count === 16) {
      const fitted = Float64Array.from(parameters);
      for (let iteration = 0; iteration < 1000; ++iteration) {
        const gradient = centralDifference(objective, fitted);
        for (let i = 0; i < fitted.length; ++i) {
          fitted[i] = Math.max(-5, Math.min(-1, fitted[i] - 8 * c.count * gradient[i]));
        }
      }
      const error = Math.max(...fitted.map((value, i) => Math.abs(value - c.truth[i])));
      if (!Number.isFinite(error) || error >= 1e-6) throw new Error(`parameter recovery failed: ${error}`);
      record.recovered_parameter_max_error = error;
      record.fitted_loss = objective(fitted);
    }
    report.results.push(record);
    const ordered = [...samples].sort((a, b) => a - b);
    console.log(`PROJECTION_OK three_central_difference n=${c.count} median_ns=${ordered[Math.floor(ordered.length / 2)]} gradient_error=${gradientError}`);
  }
  report.status = 'passed';
} finally {
  writeFileSync(process.argv[3], JSON.stringify(report, null, 2) + '\n');
}
