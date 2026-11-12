import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {fileURLToPath} from 'node:url';
import {copyFileSync, chmodSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync, statSync} from 'node:fs';
import {homedir} from 'node:os';
import {join, sep} from 'node:path';

// macOS ScreenCaptureKit hangs for a helper binary inside a TCC-protected folder
// (~/Documents, ~/Desktop, ~/Downloads, iCloud Drive). Run a copy from Application Support.
export function stageExecutable(path, home = homedir()) {
  const protectedDirs = ['Documents', 'Desktop', 'Downloads', join('Library', 'Mobile Documents')].map(d => join(home, d) + sep);
  if (process.platform !== 'darwin' || !protectedDirs.some(d => path.startsWith(d))) return path;
  try {
    const info = statSync(path);
    const dir = join(home, 'Library', 'Application Support', 'OpenComputer', 'helper', `${info.size}-${Math.floor(info.mtimeMs)}`);
    const target = join(dir, 'opencomputer-native');
    if (!existsSync(target)) {
      mkdirSync(dir, {recursive: true});
      const temp = `${target}.${process.pid}.tmp`;
      copyFileSync(path, temp);
      chmodSync(temp, 0o755);
      renameSync(temp, target);
      // Older copies go; helpers already running keep their open binary.
      const parent = join(dir, '..');
      for (const name of readdirSync(parent)) if (join(parent, name) !== dir) rmSync(join(parent, name), {recursive: true, force: true});
    }
    return target;
  } catch { return path; }
}

export class ComputerError extends Error {
  constructor(code, message, details) { super(message); this.name = 'ComputerError'; this.code = code; if (details !== undefined) this.details = details; }
}

/** One connection owns one native process, which keeps one accessibility snapshot per app. */
export class Computer {
  #child; #queue = Promise.resolve(); #pending; #closed = false; #explicitAgent;
  constructor({apps = [], agent, overlay = true, executable = process.env.OPENCOMPUTER_NATIVE || fileURLToPath(new URL('../build/opencomputer-native', import.meta.url)), timeoutMs = 20000} = {}) {
    if (!Array.isArray(apps) || apps.some(x => typeof x !== 'string' || (x !== '*' && !/^[a-zA-Z0-9._-]+$/.test(x)))) throw new TypeError('apps must be exact bundle IDs or an explicit * for all apps');
    if (agent !== undefined && (typeof agent !== "string" || agent.length > 100)) throw new TypeError("agent must be a string of at most 100 characters");
    this.#explicitAgent = agent;
    this.timeoutMs = timeoutMs;
    this.#child = spawn(stageExecutable(executable), [], {env: {...process.env, OPENCOMPUTER_APPS: apps.join(','), OPENCOMPUTER_AGENT: agent ?? "Agent", OPENCOMPUTER_OVERLAY: overlay ? "1" : "0"}, stdio: ['pipe','pipe','pipe']});
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
        if (message.error) pending.reject(new ComputerError(message.error.code, message.error.message, message.error.details));
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
  setClientInfo(name) {
    if (this.#explicitAgent !== undefined) return Promise.resolve();
    return this.request("configure", {agent: String(name ?? "Agent").slice(0, 100)});
  }
  release() { return this.request("release"); }
  getState() { return this.request('apps'); }
  status() { return this.request('status'); }
  getApp(bundleId, {pid} = {}) { return new App(this, bundleId, pid); }
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
  #computer; #bundle; #pid; #snapshot;
  constructor(computer, bundle, pid) { this.#computer = computer; this.#bundle = bundle; this.#pid = pid; }
  #scope() { return this.#pid === undefined ? {app:this.#bundle} : {app:this.#bundle, pid:this.#pid}; }
  /** Launch the app, or open a URL in it, without bringing it forward. */
  open(url) { return this.#computer.request('open', {app:this.#bundle, ...(url === undefined ? {} : {url})}); }
  async getAXState({window, root, menu, limit} = {}) {
    if (root !== undefined && !this.#snapshot) throw new ComputerError('OBSERVE_REQUIRED', 'Observe before expanding a subtree');
    const result = await this.#computer.request('observe', {...this.#scope(), window, root, menu, limit, ...(root === undefined ? {} : {snapshot:this.#snapshot})});
    this.#snapshot = result.snapshot;
    return result;
  }
  getScreenshot(windowId) { return this.#computer.request('screenshot', {...this.#scope(), windowId}); }
  checkInteraction(element, {intrusive} = {}) {
    if (element !== undefined && !this.#snapshot) return Promise.reject(new ComputerError('OBSERVE_REQUIRED', 'Call getAXState before checking an element'));
    return this.#computer.request('checkInteraction', {...this.#scope(), ...(element === undefined ? {} : {snapshot:this.#snapshot, element}), intrusive});
  }
  // The snapshot survives actions; the helper replaces it on the next full observe.
  async #action(method, element, args = {}) {
    if (!this.#snapshot) throw new ComputerError('OBSERVE_REQUIRED', 'Call getAXState before acting on an element');
    return this.#computer.request(method, {...this.#scope(), snapshot:this.#snapshot, element, ...args});
  }
  click(element, options) { return this.#action('click', element, options); }
  clickPoint(x, y, options) { return this.#computer.request('clickPoint', {...this.#scope(), x, y, ...options}); }
  setValue(element, value, options) { return this.#action('setValue', element, {value, ...options}); }
  performSecondaryAction(element, action, options) { return this.#action('performAction', element, {action, ...options}); }
  typeText(element, text, options) { return this.#action('typeText', element, {text, ...options}); }
  /** Send a key to this app only. `element` is optional; give one to focus it first. */
  pressKey(key, {element, ...options} = {}) {
    if (element === undefined) return this.#computer.request('pressKey', {...this.#scope(), key, ...options});
    return this.#action('pressKey', element, {key, ...options});
  }
  scroll(element, direction, pages, options) { return this.#action('scroll', element, {direction, pages, ...options}); }
}
export function createComputer(options) { return new Computer(options); }
