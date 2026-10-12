import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const componentPath = new URL('../src/components/ToolUsageList.tsx', import.meta.url);
const messagesPath = new URL('../src/i18n/messages.ts', import.meta.url);

test('ToolUsageList shows compact call counts and marks allocated tokens without repeated estimate text', async () => {
  const [component, messages] = await Promise.all([readFile(componentPath, 'utf8'), readFile(messagesPath, 'utf8')]);

  assert.match(component, /t\('projects\.calls'/);
  assert.match(component, /formatQuantity\(tool\.estimated_tokens\)/);
  assert.match(component, /projects\.estimatedTokensNote/);
  assert.match(component, /formatQuantity\(tool\.call_count\)/);
  assert.match(component, /from '\.\.\/utils\/formatQuantity'/);

  assert.match(messages, /calls:\s*'\{count\} \{unit\}'/);
  assert.match(messages, /calls:\s*'\{count\} 次'/);
  assert.match(messages, /estimatedTokens:\s*'≈\{value\}'/);
});
