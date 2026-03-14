/**
 * MLX vision client — drop-in replacement for ollama.js.
 *
 * Spawns a persistent Python subprocess running mlx-infer.py in batch mode.
 * The model loads once and stays warm across all page requests.
 *
 * Usage mirrors ollamaVision() but takes image file paths instead of base64.
 */

import { spawn, execSync } from 'child_process';
import { createInterface } from 'readline';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const VENV_PYTHON = join(__dirname, '.venv', 'bin', 'python3');
const INFER_SCRIPT = join(__dirname, 'mlx-infer.py');

// Memory guard — minimum free memory (in GB) before allowing MLX to start
// Startup needs ~6 GB to load the model; once loaded, 1.5 GB suffices for inference
const MIN_FREE_MEMORY_GB_STARTUP = 4;
const MIN_FREE_MEMORY_GB_RUNNING = 1.5;
// Warn threshold — prints a warning but continues
const WARN_FREE_MEMORY_GB = 3;

/**
 * Get available (free + purgeable + inactive) memory in GB on macOS.
 * Includes inactive pages because macOS reclaims them on demand —
 * they are NOT in use and will be freed when an app requests memory.
 * Returns null on non-macOS or if the check fails.
 */
export function getAvailableMemoryGB() {
  try {
    const raw = execSync('vm_stat', { encoding: 'utf-8', timeout: 5000 });
    const pageSize = 16384; // ARM64 page size
    const get = (label) => {
      const m = raw.match(new RegExp(`${label}:\\s+(\\d+)`));
      return m ? parseInt(m[1], 10) : 0;
    };
    const freePages = get('Pages free') + get('Pages purgeable') + get('Pages inactive');
    return (freePages * pageSize) / (1024 ** 3);
  } catch {
    return null;
  }
}

/**
 * Check system memory and throw if below minimum threshold.
 * Uses a higher threshold at startup (before model loads) vs during inference.
 * @param {string} context - Where the check is happening (for logging)
 */
export function checkMemoryOrDie(context = 'MLX startup') {
  const available = getAvailableMemoryGB();
  if (available === null) return; // can't check, proceed

  const isRunning = _process !== null;
  const threshold = isRunning ? MIN_FREE_MEMORY_GB_RUNNING : MIN_FREE_MEMORY_GB_STARTUP;

  if (available < threshold) {
    const msg = `[${context}] ABORTED: Only ${available.toFixed(1)} GB free memory (need ${threshold} GB). Close Firefox/screen sharing/other apps and retry.`;
    console.error(msg);
    throw new Error(msg);
  }

  if (available < WARN_FREE_MEMORY_GB) {
    console.error(`  [${context}] WARNING: ${available.toFixed(1)} GB free — low memory`);
  }
}

let _process = null;
let _readline = null;
let _ready = null;
let _pending = null; // resolve/reject for current request

/**
 * Start the MLX batch inference subprocess.
 * Returns a promise that resolves when the model is loaded and ready.
 */
export async function startMLX() {
  if (_process) return _ready;

  // Pre-flight memory check before loading a ~4GB model
  checkMemoryOrDie('MLX startup');

  _ready = new Promise((resolve, reject) => {
    _process = spawn(VENV_PYTHON, [INFER_SCRIPT, '--batch'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env,
        HF_HOME: process.env.HF_HOME || '/Volumes/X10 Pro/mlx-models'
      }
    });

    // stderr: status messages from the Python process
    const stderrRL = createInterface({ input: _process.stderr });
    stderrRL.on('line', line => {
      try {
        const msg = JSON.parse(line);
        if (msg.status === 'ready') {
          console.error(`  MLX model loaded in ${msg.load_time}s`);
          resolve();
        } else if (msg.status === 'loading') {
          console.error(`  Loading MLX model: ${msg.model}`);
        }
      } catch {
        // Non-JSON stderr — just forward
        console.error(`  [mlx] ${line}`);
      }
    });

    // stdout: JSON line responses
    _readline = createInterface({ input: _process.stdout });
    _readline.on('line', line => {
      if (_pending) {
        try {
          const result = JSON.parse(line);
          if (result.error) {
            _pending.reject(new Error(result.error));
          } else {
            _pending.resolve(result);
          }
        } catch (err) {
          _pending.reject(new Error(`MLX parse error: ${err.message}`));
        }
        _pending = null;
      }
    });

    _process.on('error', err => {
      console.error(`  MLX process error: ${err.message}`);
      reject(err);
    });

    _process.on('exit', (code, signal) => {
      console.error(`  MLX process exited (code=${code}, signal=${signal})`);
      _process = null;
      _readline = null;
      if (_pending) {
        _pending.reject(new Error(`MLX process exited unexpectedly (code=${code})`));
        _pending = null;
      }
    });
  });

  return _ready;
}

/**
 * Stop the MLX subprocess.
 */
export function stopMLX() {
  if (_process) {
    _process.stdin.end();
    _process.kill();
    _process = null;
    _readline = null;
    _pending = null;
  }
}

/**
 * Send a vision request to the MLX model.
 *
 * @param {string} imagePath - Path to image file (no base64 needed)
 * @param {string} prompt - Prompt text
 * @param {object} [opts]
 * @param {number} [opts.maxTokens] - Max tokens (default 4096)
 * @param {number} [opts.temperature] - Temperature (default 0.1)
 * @param {number} [opts.timeout] - Timeout in ms (default 120000)
 * @returns {Promise<string>} Model response text
 */
export async function mlxVision(imagePath, prompt, opts = {}) {
  await startMLX();

  const request = {
    image: imagePath,
    prompt,
    max_tokens: opts.maxTokens || 4096,
    temperature: opts.temperature ?? 0.1
  };

  return new Promise((resolve, reject) => {
    const timeoutMs = opts.timeout || 300000;
    const timer = setTimeout(() => {
      if (_pending) {
        _pending = null;
        reject(new Error(`MLX timeout after ${timeoutMs}ms`));
      }
    }, timeoutMs);

    _pending = {
      resolve: (result) => {
        clearTimeout(timer);
        resolve(result.text);
      },
      reject: (err) => {
        clearTimeout(timer);
        reject(err);
      }
    };

    _process.stdin.write(JSON.stringify(request) + '\n');
  });
}

/**
 * Parse JSON from model response, stripping markdown fencing.
 * Attempts to repair truncated JSON from vision models.
 * (Self-contained copy — no ollama.js dependency needed.)
 */
export function parseModelJSON(text) {
  const clean = text
    .replace(/^```json?\s*\n?/m, '')
    .replace(/\n?```\s*$/m, '')
    .trim();

  try {
    return JSON.parse(clean);
  } catch (firstErr) {
    let repaired = clean;

    // Fix bare non-ASCII tokens in arrays (e.g. [†, ‡] → ["†", "‡"])
    repaired = repaired.replace(/\[([^\[\]]*)\]/g, (match, inner) => {
      // Split on commas, quote any bare non-JSON-primitive tokens
      const items = inner.split(',').map(item => {
        const t = item.trim();
        if (!t) return t;
        if (/^-?\d+(\.\d+)?$/.test(t) || t === 'true' || t === 'false' || t === 'null') return t;
        if (t.startsWith('"') && t.endsWith('"')) return t;
        // Bare token — wrap in quotes
        return `"${t.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
      });
      return `[${items.join(', ')}]`;
    });

    // Try parsing after bare-token fix before applying truncation repairs
    try { return JSON.parse(repaired); } catch { /* continue to truncation repair */ }

    repaired = repaired.replace(/,?\s*"[^"]*$/, '');
    repaired = repaired.replace(/,?\s*"[^"]*":\s*$/, '');

    const opens = { '{': 0, '[': 0 };
    let inString = false;
    let escape = false;
    for (const ch of repaired) {
      if (escape) { escape = false; continue; }
      if (ch === '\\') { escape = true; continue; }
      if (ch === '"') { inString = !inString; continue; }
      if (inString) continue;
      if (ch === '{') opens['{']++;
      if (ch === '}') opens['{']--;
      if (ch === '[') opens['[']++;
      if (ch === ']') opens['[']--;
    }

    repaired = repaired.replace(/,\s*$/, '');
    for (let i = 0; i < opens['[']; i++) repaired += ']';
    for (let i = 0; i < opens['{']; i++) repaired += '}';

    try {
      return JSON.parse(repaired);
    } catch {
      throw firstErr;
    }
  }
}
