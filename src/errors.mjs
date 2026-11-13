/** An error with a stable `code` and optional `details`, as the native helper reports them. */
export class ComputerError extends Error {
  constructor(code, message, details) { super(message); this.name = 'ComputerError'; this.code = code; if (details !== undefined) this.details = details; }
}
