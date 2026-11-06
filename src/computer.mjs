import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {fileURLToPath} from 'node:url';

export class ComputerError extends Error {
  constructor(code, message) { super(message); this.name = 'ComputerError'; this.code = code; }
}

/** One connection owns one native process and one current accessibility snapshot. */
export class Computer {
  #child; #queue = Promise.resolve(); #pending; #closed = false;
  constructor({apps = [], executable = fileURLToPath(new URL('../build/opencomputer-native', import.meta.url)), timeoutMs = 20000} = {}) {
    if (!Array.isArray(apps) || apps.some(x => typeof x !== 'string' || !/^[a-zA-Z0-9._-]+$/.test(x))) throw new TypeError('apps must be exact bundle IDs');
    this.timeoutMs = timeoutMs;
    this.#child = spawn(executable, [], {env: {...process.env, OPENCOMPUTER_APPS: apps.join(',')}, stdio: ['pipe','pipe','pipe']});
    // Native diagnostics go only to stderr; stdout is reserved for the protocol.
    this.#child.stderr.on('data', data => process.stderr.write(data));
    const lines = createInterface({input: this.#child.stdout});
    lines.on('line', line => {
      const pending = this.#pending;
      if (!pending) return this.close();
      this.#pending = undefined;
      clearTimeout(pending.timer);
      try {
        const message = JSON.parse(line);
        if (message.error) pending.reject(new ComputerError(message.error.code, message.error.message));
        else if (message.result && typeof message.result === 'object') pending.resolve(message.result);
        else { pending.reject(new ComputerError('PROTOCOL_ERROR', 'Invalid native response')); this.close(); }
      } catch (error) { pending.reject(error); this.close(); }
    });
    const died = error => {
      this.#closed = true;
      if (this.#pending) { clearTimeout(this.#pending.timer); this.#pending.reject(error); this.#pending = undefined; }
    };
    this.#child.on('error', error => died(new ComputerError('HELPER_UNAVAILABLE', `${error.message}. Run npm run build on macOS.`)));
    this.#child.on('exit', () => died(new ComputerError('HELPER_EXITED', 'Native helper exited. Create a new Computer connection.')));
    this.#child.stdin.on('error', error => died(error));
  }
  request(method, args = {}) {
    const run = () => new Promise((resolve, reject) => {
      if (this.#closed) return reject(new ComputerError('CLOSED', 'Computer connection is closed'));
      const payload = JSON.stringify({...args, method});
      if (Buffer.byteLength(payload) > 1_048_576) return reject(new ComputerError('TOO_LARGE', 'Request exceeds 1 MiB'));
      const timer = setTimeout(() => {
        this.#pending = undefined;
        reject(new ComputerError('TIMEOUT', 'Native request timed out. Connection closed; re-observe before retrying.'));
        this.close();
      }, this.timeoutMs);
      this.#pending = {resolve, reject, timer};
      this.#child.stdin.write(payload + '\n');
    });
    const result = this.#queue.then(run);
    this.#queue = result.catch(() => {});
    return result;
  }
  getState() { return this.request('apps'); }
  status() { return this.request('status'); }
  getApp(bundleId) { return new App(this, bundleId); }
  close() {
    if (this.#pending) {
      clearTimeout(this.#pending.timer);
      this.#pending.reject(new ComputerError('CLOSED', 'Computer connection closed'));
      this.#pending = undefined;
    }
    this.#closed = true;
    this.#child.kill();
  }
  [Symbol.dispose]() { this.close(); }
}

class App {
  #computer; #bundle; #snapshot;
  constructor(computer, bundle) { this.#computer = computer; this.#bundle = bundle; }
  async getAXState() {
    const result = await this.#computer.request('observe', {app:this.#bundle});
    this.#snapshot = result.snapshot;
    return result;
  }
  getScreenshot(windowId) { return this.#computer.request('screenshot', {app:this.#bundle, windowId}); }
  async #action(method, element, args = {}) {
    if (!this.#snapshot) throw new ComputerError('OBSERVE_REQUIRED', 'Call getAXState before each action');
    const snapshot = this.#snapshot;
    this.#snapshot = undefined;
    return this.#computer.request(method, {app:this.#bundle, snapshot, element, ...args});
  }
  click(element) { return this.#action('click', element); }
  setValue(element, value) { return this.#action('setValue', element, {value}); }
  performSecondaryAction(element, action) { return this.#action('performAction', element, {action}); }
  pressKey(element, key) { return this.#action('pressKey', element, {key}); }
  typeText(element, text) { return this.#action('typeText', element, {text}); }
  scroll(element, direction) { return this.#action('scroll', element, {direction}); }
}
export function createComputer(options) { return new Computer(options); }
