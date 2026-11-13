import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {fileURLToPath} from 'node:url';
import {copyFileSync, chmodSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync, statSync} from 'node:fs';
import {homedir} from 'node:os';
import {join, sep} from 'node:path';
import {ComputerError} from './errors.mjs';
import {chooseMenu, expectations, pressByMenu, viewsOf, waitFor} from './flows.mjs';

export {ComputerError};

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

/** One connection owns one native process, which keeps one accessibility snapshot per app. */
export class Computer {
  #child; #queue = Promise.resolve(); #pending; #closed = false; #explicitAgent; #clientName;
  constructor({apps = [], agent, overlay = true, executable = process.env.OPENCOMPUTER_NATIVE || fileURLToPath(new URL('../build/opencomputer-native', import.meta.url)), timeoutMs = 20000} = {}) {
    // bundle:read (or *:read) allows observing and screenshots of that app, but no actions;
    // bundle:click (or *:click) also allows clicking and scrolling, but no text or keys.
    if (!Array.isArray(apps) || apps.some(x => typeof x !== 'string' || !/^(\*|[a-zA-Z0-9._-]+)(:read|:click)?$/.test(x))) throw new TypeError('apps must be exact bundle IDs or an explicit * for all apps, each optionally ending in :read (read-only) or :click (click and scroll only)');
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
  get closed() { return this.#closed; }
  get clientName() { return this.#clientName; }
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
    this.#clientName = name;
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
  /**
   * Read the app. `refresh: true` re-reads into the current snapshot so earlier element ids
   * keep working (a fresh observe when there is none).
   */
  async getAXState({window, windowTitle, root, menu, limit, budgetMs, refresh} = {}) {
    if (root !== undefined && !this.#snapshot) throw new ComputerError('OBSERVE_REQUIRED', 'Observe before expanding a subtree');
    const args = {...this.#scope(), window, windowTitle, root, menu, limit, budgetMs};
    if (refresh && this.#snapshot && root === undefined && !menu) {
      try {
        const result = await this.#computer.request('observe', {...args, refresh:true, snapshot:this.#snapshot});
        this.#snapshot = result.snapshot;
        return result;
      } catch (error) { if (error.code !== 'STALE_SNAPSHOT') throw error; }
    }
    const result = await this.#computer.request('observe', {...args, ...(root === undefined ? {} : {snapshot:this.#snapshot})});
    this.#snapshot = result.snapshot;
    return result;
  }
  /** Capture a window. `marks` labels element ids, `region` zooms into the last screenshot, `ocr` adds recognized text lines, `maxEdge` caps the long side in pixels. */
  getScreenshot(windowId, {marks, region, ocr, maxEdge} = {}) { return this.#computer.request('screenshot', {...this.#scope(), windowId, marks, region, ocr, maxEdge}); }
  /** Full text of an element, or of everything inside a container, from `offset` (UTF-16 units). */
  readText(element, {offset, length} = {}) {
    if (!this.#snapshot) return Promise.reject(new ComputerError('OBSERVE_REQUIRED', 'Call getAXState before reading an element'));
    return this.#computer.request('readText', {...this.#scope(), snapshot:this.#snapshot, element, offset, length});
  }
  /** Re-read until an element matches `query` (or, with `gone`, none does); resolves with the read and its matches. */
  async waitFor(query, {gone, timeoutMs, window, windowTitle} = {}) {
    const request = (method, args) => this.#computer.request(method, args);
    const views = viewsOf(this.#computer);
    // Start from this handle's snapshot so the ids it already holds stay valid.
    if (this.#snapshot && views.get(this.#bundle)?.snapshot !== this.#snapshot) views.remember(this.#bundle, {snapshot:this.#snapshot, nodes:[]}, {});
    const outcome = await waitFor(request, views, {...this.#scope(), query, gone, timeoutMs, window, windowTitle});
    this.#snapshot = outcome.result.snapshot;
    return outcome;
  }
  /** Press a menu bar command by path, such as 'File > Export as PDF…' or ['File', 'Export as PDF…']. */
  async chooseMenu(path, options = {}) {
    const result = await chooseMenu((method, args) => this.#computer.request(method, args), {...this.#scope(), path, ...options});
    this.#snapshot = result.snapshot;
    return result;
  }
  /**
   * Check conditions such as [{query:'Sheet Save', exists:false}] or [{element:12, valueContains:'Hi'}]
   * against a fresh read (re-reading until they hold, up to `timeoutMs`). Resolves with
   * {outcome: 'confirmed'|'deviation'|'unverifiable', results, result}.
   */
  async verify(expect, {timeoutMs, window, windowTitle} = {}) {
    if (!Array.isArray(expect) || !expect.length) throw new ComputerError('INVALID_ARGUMENT', 'expect is a non-empty array of conditions');
    const views = viewsOf(this.#computer);
    if (this.#snapshot && views.get(this.#bundle)?.snapshot !== this.#snapshot) views.remember(this.#bundle, {snapshot:this.#snapshot, nodes:[]}, {});
    const scope = {...this.#scope(), ...(window === undefined ? {} : {window}), ...(windowTitle === undefined ? {} : {windowTitle})};
    const {result, verdict} = await expectations((method, args) => this.#computer.request(method, args), views, scope, expect, {timeoutMs:Math.min(Number(timeoutMs) || 0, 30000)});
    this.#snapshot = result.snapshot;
    return {...verdict, result};
  }
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
  /**
   * Send a key to this app only. `element` is optional; give one to focus it first.
   * `via: 'menu'` presses the menu bar item that has this shortcut instead of sending keys.
   */
  pressKey(key, {element, via, ...options} = {}) {
    if (via === 'menu') return pressByMenu((method, args) => this.#computer.request(method, args), {...this.#scope(), key, ...options});
    if (element === undefined) return this.#computer.request('pressKey', {...this.#scope(), key, ...options});
    return this.#action('pressKey', element, {key, ...options});
  }
  scroll(element, direction, pages, options) { return this.#action('scroll', element, {direction, pages, ...options}); }
}
export function createComputer(options) { return new Computer(options); }

/**
 * A long-lived connection for servers: after a timeout or a helper exit it starts a new
 * helper on the next request, and it moves to a rebuilt helper binary between requests.
 * Either way snapshots are lost, so the agent sees STALE_SNAPSHOT and observes again.
 */
export class ReconnectingComputer {
  #options; #current; #stamp; #queue = Promise.resolve();
  constructor(options = {}) { this.#options = options; this.#start(); }
  #binary() { return this.#options.executable || process.env.OPENCOMPUTER_NATIVE || fileURLToPath(new URL('../build/opencomputer-native', import.meta.url)); }
  #stampNow() { try { const s = statSync(this.#binary()); return `${s.size}-${s.mtimeMs}`; } catch { return undefined; } }
  #start() {
    const name = this.#current?.clientName;
    this.#current = new Computer(this.#options);
    this.#stamp = this.#stampNow();
    return name === undefined ? Promise.resolve() : this.#current.setClientInfo(name);
  }
  get restarts() { return this.#restarts; }
  #restarts = 0;
  async #ensure() {
    const stale = this.#current.closed || (this.#stamp !== undefined && this.#stampNow() !== undefined && this.#stampNow() !== this.#stamp);
    if (!stale) return;
    this.#current.close();
    this.#restarts++;
    await this.#start();
  }
  request(method, args = {}) {
    const run = async () => { await this.#ensure(); return this.#current.request(method, args); };
    const result = this.#queue.then(run);
    this.#queue = result.catch(() => {});
    return result;
  }
  setClientInfo(name) { return this.#queue = this.#queue.then(() => this.#current.setClientInfo(name)).catch(() => {}); }
  getState() { return this.request('apps'); }
  close() { this.#current.close(); }
  [Symbol.dispose]() { this.close(); }
}
