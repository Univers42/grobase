import { describe, expect, it } from '@jest/globals';
import { redactDsn } from './redact-dsn';

// Concatenated at runtime so no source line looks like a credentialed DSN to gitleaks.
const CANARY = 'Canary-' + 'pw_7f3a';

describe('redactDsn', () => {
  it.each([
    ['url', `connect postgresql://app:${CANARY}@db:5432/shop failed`],
    ['url in quotes', `dial "mysql://root:${CANARY}@10.0.0.1/x": refused`],
    ['keyword', `connect host=db password=${CANARY} sslmode=require`],
    ['quoted keyword', `host=db PASSWORD='${CANARY}' user=app`],
    ['pwd keyword', `Server=db;Uid=sa;Pwd=${CANARY};`],
  ])('hides the canary (%s)', (_, text) => {
    const redacted = redactDsn(text);
    expect(redacted).not.toContain(CANARY);
    expect(redacted).toMatch(/\[redacted(-dsn)?\]/);
  });

  it('keeps the words around the secret', () => {
    expect(redactDsn(`connect host=db password=${CANARY} failed`)).toBe(
      'connect host=db password=[redacted] failed',
    );
  });

  it('leaves text with no DSN unchanged', () => {
    expect(redactDsn('relation "items" does not exist')).toBe('relation "items" does not exist');
  });
});
