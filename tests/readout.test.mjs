// The title block's step time is only ever a number measured on this grid.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { stepTimeText } from '../web/readout.js';
import { root } from './helpers.mjs';

test('step time reads "measuring…" until the current grid has been timed', () => {
  assert.equal(stepTimeText(null, null, 512), 'measuring… (512² grid)');
  assert.equal(stepTimeText(null, 8.1, 256), 'measuring… (256² grid)');
  assert.equal(stepTimeText(Number.NaN, null, 256), 'measuring… (256² grid)');
  assert.equal(stepTimeText(1.234, null, 256), '1.23 ms per step, measured here (256² grid)');
  assert.equal(stepTimeText(2.5, 8.26, 512), '2.50 ms per step; rivers re-surveyed in 8.3 ms every 16 steps, measured here (512² grid)');
});

test('the page never seeds the step time with a made-up number', () => {
  const app = readFileSync(join(root, 'web', 'app.js'), 'utf8');
  assert.match(app, /stepMs: null/);
  // A new survey (or grid) forgets the last grid's timings.
  const start = app.slice(app.indexOf('function startSurvey'), app.indexOf('/** Time a few 512'));
  assert.match(start, /state\.stepMs = null/);
  assert.match(start, /state\.surveyMs = null/);
  // Choosing the grid at load times the 512² grid but does not report it as the step time.
  const choose = app.slice(app.indexOf('function chooseGrid'), app.indexOf('// Drawing and readouts'));
  assert.doesNotMatch(choose, /state\.stepMs\s*=/);
});
