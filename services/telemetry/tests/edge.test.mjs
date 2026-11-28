import assert from 'node:assert/strict';
import test from 'node:test';
import worker from '../worker/index.ts';

test('a throttled request is rejected before validation or D1', async () => {
  const request = new Request('https://example.test/v1/events', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'CF-Connecting-IP': '192.0.2.10',
    },
    body: '{}',
  });
  const response = await worker.fetch(request, {
    TELEMETRY_RATE_LIMIT: {
      limit: async ({ key }) => {
        assert.equal(key, '192.0.2.10');
        return { success: false };
      },
    },
  });
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('Retry-After'), '10');
  assert.equal(response.headers.get('Access-Control-Expose-Headers'), 'Retry-After');
  assert.deepEqual(await response.json(), { error: 'rate_limited' });
});
