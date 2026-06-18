// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { afterAll, beforeEach, describe, expect, it, jest } from '@jest/globals';
import { ArgumentsHost, HttpException, HttpStatus, Logger } from '@nestjs/common';
import { AllExceptionsFilter } from './all-exceptions.filter';

// A minimal ArgumentsHost double exposing only switchToHttp().getResponse()/
// getRequest() — the surface the filter touches. Kept shallow (no arrow nested
// past one level) so it does not trip Sonar S2004.
function makeHost(requestId?: string) {
  const json = jest.fn();
  const status = jest.fn(() => ({ json }));
  const httpCtx = {
    getResponse: () => ({ status }),
    getRequest: () => ({ requestId }),
  };
  const host = { switchToHttp: () => httpCtx } as unknown as ArgumentsHost;
  return { host, status, json };
}

describe('AllExceptionsFilter', () => {
  const filter = new AllExceptionsFilter();

  // The filter logs server-faults (5xx / non-Error) via Nest's Logger before
  // masking them as 500. Silence that EXPECTED output so the suite stays quiet,
  // and below we assert it actually fired (server bugs must be logged, not lost).
  const errorSpy = jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
  beforeEach(() => {
    errorSpy.mockClear();
  });
  afterAll(() => {
    errorSpy.mockRestore();
  });

  it('HttpException with a string body keeps its status + message + requestId', () => {
    const { host, status, json } = makeHost('req-1');
    filter.catch(new HttpException('nope', HttpStatus.FORBIDDEN), host);
    expect(status).toHaveBeenCalledWith(HttpStatus.FORBIDDEN);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({
        statusCode: HttpStatus.FORBIDDEN,
        message: 'nope',
        error: 'FORBIDDEN',
        requestId: 'req-1',
      }),
    );
  });

  it('HttpException with an object body surfaces its message + error', () => {
    const { host, json } = makeHost();
    filter.catch(
      new HttpException({ message: ['a', 'b'], error: 'Bad Request' }, HttpStatus.BAD_REQUEST),
      host,
    );
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ statusCode: 400, message: ['a', 'b'], error: 'Bad Request' }),
    );
  });

  it('HttpException object body without message/error falls back to the status name', () => {
    const { host, json } = makeHost();
    filter.catch(new HttpException({}, HttpStatus.NOT_FOUND), host);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ statusCode: 404, error: 'NOT_FOUND' }),
    );
  });

  it('a plain Error carrying a 4xx statusCode surfaces as that 4xx', () => {
    const { host, status, json } = makeHost();
    filter.catch(Object.assign(new Error('too big'), { statusCode: 413 }), host);
    expect(status).toHaveBeenCalledWith(413);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ statusCode: 413, message: 'too big' }),
    );
  });

  it('a plain Error with a 4xx `status` field is honoured', () => {
    const { host, status } = makeHost();
    filter.catch(Object.assign(new Error('rate'), { status: 429 }), host);
    expect(status).toHaveBeenCalledWith(429);
  });

  it('body-parser entity.too.large maps to 413', () => {
    const { host, status } = makeHost();
    filter.catch(Object.assign(new Error('payload too large'), { type: 'entity.too.large' }), host);
    expect(status).toHaveBeenCalledWith(413);
    expect(errorSpy).not.toHaveBeenCalled(); // a client 4xx is not a server fault
  });

  it('malformed JSON (entity.parse.failed) maps to 400', () => {
    const { host, status } = makeHost();
    filter.catch(Object.assign(new Error('bad json'), { type: 'entity.parse.failed' }), host);
    expect(status).toHaveBeenCalledWith(400);
  });

  it('a 5xx-carrying Error stays a masked 500 (server bugs are not surfaced)', () => {
    const { host, status, json } = makeHost();
    filter.catch(Object.assign(new Error('boom'), { statusCode: 503 }), host);
    expect(status).toHaveBeenCalledWith(500);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ statusCode: 500, error: 'Internal Server Error' }),
    );
    expect(errorSpy).toHaveBeenCalled(); // the masked server bug is still logged
  });

  it('a non-Error throwable is logged and masked as 500', () => {
    const { host, status } = makeHost();
    filter.catch('a bare string', host);
    expect(status).toHaveBeenCalledWith(500);
    expect(errorSpy).toHaveBeenCalled(); // unknown throwable is logged before masking
  });
});
