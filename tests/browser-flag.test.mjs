// REQUIRE_BROWSER=1 turns a missing Chrome into a failure (for CI); by
// default a missing Chrome skips the browser test.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { browserPlan, findChrome } from './cdp.mjs';

test('no Chrome: skip by default, fail with REQUIRE_BROWSER=1', () => {
  assert.equal(findChrome({ CHROME_PATH: '/nonexistent/chrome' }), null);
  assert.ok(browserPlan(null, {}).skip);
  assert.match(browserPlan(null, { REQUIRE_BROWSER: '1' }).fail, /REQUIRE_BROWSER=1/);
  assert.deepEqual(browserPlan('/some/chrome', {}), { run: true });
});
