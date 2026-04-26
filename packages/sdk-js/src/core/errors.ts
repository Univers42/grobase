export class MiniBaasError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: unknown,
  ) {
    super(message);
    this.name = 'MiniBaasError';
  }
}

export class MiniBaasTimeoutError extends Error {
  constructor(readonly timeoutMs: number) {
    super(`MiniBaas request timed out after ${timeoutMs}ms`);
    this.name = 'MiniBaasTimeoutError';
  }
}
