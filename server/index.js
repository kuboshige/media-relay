const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { execFile, execSync } = require('child_process');

const app = express();
const PORT = process.env.PORT || 8765;
// JSONボディを受ける（/setdate 用）
app.use(express.json());

// Termux環境では /sdcard/MediaRelay、それ以外はカレントの storage/
const isTermux = !!(process.env.HOME && process.env.HOME.includes('com.termux'));
const STORAGE_ROOT = process.env.STORAGE_ROOT
  || (isTermux ? '/sdcard/MediaRelay' : path.join(__dirname, 'storage'));

fs.mkdirSync(STORAGE_ROOT, { recursive: true });

// 重複判定（GET /exists）で照合するフォルダ。
// MediaRelay 本体に加えて、クイックシェアの保存先（Download/Quick Share）も含める。
// 環境変数 SCAN_DIRS（: 区切り）で上書き可能。
const DEFAULT_SCAN_DIRS = isTermux
  ? [STORAGE_ROOT, '/sdcard/Download/Quick Share', '/sdcard/Download']
  : [STORAGE_ROOT];
const SCAN_DIRS = (process.env.SCAN_DIRS
  ? process.env.SCAN_DIRS.split(':')
  : DEFAULT_SCAN_DIRS
).filter((d, i, arr) => arr.indexOf(d) === i);

// マルチパートを受け取るが保存先はrelativePathで決める
const upload = multer({ storage: multer.memoryStorage() });

// アップロードを拒否し始める空き容量の余白（バイト）
const FREE_SPACE_MARGIN = 500 * 1024 * 1024; // 500MB

// STORAGE_ROOT のある領域の空き容量（バイト）。取得できなければ null。
function freeBytes() {
  try {
    const st = fs.statfsSync(STORAGE_ROOT);
    return st.bavail * st.bsize;
  } catch {
    return null;
  }
}

// termux-media-scan が使えるか（起動時に一度だけ確認）。
let _mediaScanAvail;
function mediaScanAvailable() {
  if (_mediaScanAvail !== undefined) return _mediaScanAvail;
  try {
    execSync('which termux-media-scan', { timeout: 2000, stdio: 'ignore' });
    _mediaScanAvail = true;
  } catch {
    _mediaScanAvail = false;
  }
  return _mediaScanAvail;
}

// ---- 受領台帳（永続）＋ ディスク索引 ----
// 「Pixelが一度でも受け取った／見たことのある内容ハッシュ」を永続ファイルに
// 記録する。Googleフォトの「空き容量を増やす」でPixelのディスクから実ファイルが
// 消えても、すでにバックアップ済み＝受領済みと判定できるようにするため。
// （ディスク走査だけだと、空き容量確保で消えたファイルが /exists で false になり、
//  ① 再送時に重複アップロード ② Motorola側の元ファイルが削除できない、が起きる）
//
// seenHashes は「台帳 ∪ ディスク走査で見つけたハッシュ」の和集合で、決して縮まない。
const STATE_DIR = process.env.STATE_DIR || path.join(STORAGE_ROOT, '.state');
const LEDGER_PATH = path.join(STATE_DIR, 'received-hashes.txt');
fs.mkdirSync(STATE_DIR, { recursive: true });

let seenHashes = null; // Set<string> | null（受領台帳＋ディスク走査の和）
let scanned = false; // 起動後に一度ディスク走査を終えたか
let scanning = null; // Promise | null

// 台帳ファイルを読み込んで Set を作る（初回や未作成時は空）。
function loadLedger() {
  const set = new Set();
  try {
    const data = fs.readFileSync(LEDGER_PATH, 'utf8');
    for (const line of data.split('\n')) {
      const h = line.trim();
      if (/^[a-f0-9]{64}$/.test(h)) set.add(h);
    }
  } catch {
    /* 未作成は無視 */
  }
  return set;
}

// ハッシュを記憶する。新規なら台帳へ追記する（実ファイルが消えても残る）。
function rememberHash(hash) {
  if (!seenHashes) seenHashes = loadLedger();
  if (seenHashes.has(hash)) return;
  seenHashes.add(hash);
  try {
    fs.appendFileSync(LEDGER_PATH, hash + '\n');
  } catch (e) {
    console.error('[ledger] append failed:', e.message);
  }
}

function* walkFiles(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return; // 存在しない/権限なしは無視
  }
  for (const entry of entries) {
    // 隠しファイル/フォルダ（.state の台帳や .thumbnails 等）は対象外。
    // 台帳ファイル自身をハッシュして台帳が自己増殖するのを防ぐ。
    if (entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      yield* walkFiles(full);
    } else if (entry.isFile()) {
      yield full;
    }
  }
}

// 大きな動画でもメモリを食わないようストリームでハッシュ計算
function sha256OfFileStream(filePath) {
  return new Promise((resolve) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', () => resolve(null));
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

// ディスクを走査して、見つかったハッシュをすべて台帳に記憶する（縮まない）。
async function scanDisk() {
  if (!seenHashes) seenHashes = loadLedger();
  let count = 0;
  let added = 0;
  const start = Date.now();
  for (const root of SCAN_DIRS) {
    for (const file of walkFiles(root)) {
      const hex = await sha256OfFileStream(file);
      if (hex) {
        count++;
        if (!seenHashes.has(hex)) {
          rememberHash(hex);
          added++;
        }
      }
    }
  }
  const sec = ((Date.now() - start) / 1000).toFixed(1);
  console.log(`[index] scanned ${count} files, +${added} new, total ${seenHashes.size} hashes in ${sec}s`);
  console.log(`[index] dirs: ${SCAN_DIRS.join(', ')}`);
  return seenHashes;
}

// 起動後に最低一度はディスク走査を済ませる（台帳に無い既存ファイルを取り込む）。
function ensureScanned() {
  if (scanned) return Promise.resolve(seenHashes);
  if (!scanning) {
    scanning = scanDisk()
      .then((s) => {
        scanned = true;
        return s;
      })
      .finally(() => {
        scanning = null;
      });
  }
  return scanning;
}

// 受領確認（SHA256照合）。
// 「Pixelが一度でも受け取った／見た」内容なら true。実ファイルがディスクに
// 今あるかどうかは問わない（空き容量確保で消えていても受領済みなら true）。
app.get('/exists', async (req, res) => {
  const { hash } = req.query;
  if (!hash || !/^[a-f0-9]{64}$/.test(hash)) {
    return res.status(400).json({ error: 'invalid hash' });
  }
  try {
    if (!seenHashes) seenHashes = loadLedger();
    // 台帳に有れば即 true。無ければ初回だけディスク走査して既存分を取り込む。
    if (seenHashes.has(hash)) return res.json({ exists: true });
    await ensureScanned();
    res.json({ exists: seenHashes.has(hash) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 索引再構築（クイックシェア等の新規受信を取り込む）。台帳は消さず和集合を更新。
app.post('/reindex', async (req, res) => {
  scanned = false;
  scanning = null;
  try {
    const s = await ensureScanned();
    res.json({ ok: true, count: s.size, dirs: SCAN_DIRS });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ファイルアップロード
// フォーム: file=<binary>, relativePath=<文字列>
app.post('/upload', upload.single('file'), (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: 'no file' });
  }

  const relativePath = req.body.relativePath;
  if (!relativePath) {
    return res.status(400).json({ error: 'relativePath is required' });
  }

  // 空き容量チェック（このファイル＋余白が入らなければ拒否）
  const free = freeBytes();
  if (free !== null && free < req.file.size + FREE_SPACE_MARGIN) {
    console.warn(`[upload] rejected: low storage (free=${free}, need=${req.file.size})`);
    return res.status(507).json({
      error: 'insufficient storage',
      freeBytes: free,
      neededBytes: req.file.size,
    });
  }

  // パストラバーサル対策
  const normalized = path.normalize(relativePath).replace(/^(\.\.(\/|\\|$))+/, '');
  const destPath = path.join(STORAGE_ROOT, normalized);

  // ディレクトリ作成
  fs.mkdirSync(path.dirname(destPath), { recursive: true });

  // 書き込み
  fs.writeFileSync(destPath, req.file.buffer);

  // 元の撮影日時をファイル更新日時に反映する（Googleフォトの日付対策）。
  // 書き込み時刻（今日）になってしまうと、EXIF/ファイル名で日付を取れない
  // ファイルが「今日の写真」として並んでしまうため。
  applyOriginalDate(destPath, req.body.originalDate);

  const hash = crypto.createHash('sha256').update(req.file.buffer).digest('hex');
  // 受領台帳に永続記録（実ファイルが後で消えても受領済みと判定できる）
  rememberHash(hash);

  console.log(`[upload] ${normalized} (${req.file.size} bytes, sha256=${hash})`);

  res.json({ ok: true, relativePath: normalized, sha256: hash, size: req.file.size });
});

// ファイル更新日時を元の撮影日時(ms)に設定する。失敗は無視。
function applyOriginalDate(filePath, originalDateMs) {
  const ms = parseInt(originalDateMs, 10);
  if (isNaN(ms) || ms <= 0) return false;
  try {
    const t = ms / 1000; // 秒
    fs.utimesSync(filePath, t, t);
    return true;
  } catch {
    return false;
  }
}

// 既に保存済みファイルの日付だけ後から修正する（再転送せず日付対策）。
// JSON: { relativePath, originalDate(ms) }
app.post('/setdate', (req, res) => {
  const { relativePath, originalDate } = req.body || {};
  if (!relativePath) {
    return res.status(400).json({ error: 'relativePath is required' });
  }
  const normalized = path.normalize(relativePath).replace(/^(\.\.(\/|\\|$))+/, '');
  const destPath = path.join(STORAGE_ROOT, normalized);
  if (!fs.existsSync(destPath)) {
    return res.json({ ok: false, error: 'not found' });
  }
  const ok = applyOriginalDate(destPath, originalDate);
  res.json({ ok });
});

// メディアスキャン：保存したファイルをAndroidのMediaStoreに登録する。
// これをやらないとGoogleフォト等の「端末内フォルダ」に出てこない。
// termux-api（pkg install termux-api ＋ Termux:API アプリ）が必要。
app.post('/scan', (req, res) => {
  execFile('termux-media-scan', ['-r', STORAGE_ROOT], { timeout: 5 * 60 * 1000 },
    (err) => {
      if (err) {
        return res.json({
          ok: false,
          error: err.message,
          hint: 'termux-api が必要です（pkg install termux-api ＋ F-DroidのTermux:APIアプリ）',
        });
      }
      console.log(`[scan] media scan done: ${STORAGE_ROOT}`);
      res.json({ ok: true, scanned: STORAGE_ROOT });
    });
});

// サーバー状態確認
app.get('/ping', (req, res) => {
  res.json({
    ok: true,
    storageRoot: STORAGE_ROOT,
    scanDirs: SCAN_DIRS,
    freeBytes: freeBytes(),
    mediaScan: mediaScanAvailable(),
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`media-relay server listening on port ${PORT}`);
  console.log(`storage: ${STORAGE_ROOT}`);
  console.log(`scan dirs: ${SCAN_DIRS.join(', ')}`);
  // 起動時に台帳を読み込み、バックグラウンドでディスク走査も済ませておく
  seenHashes = loadLedger();
  console.log(`[ledger] loaded ${seenHashes.size} hashes from ${LEDGER_PATH}`);
  ensureScanned().catch((e) => console.error('[index] scan error:', e.message));
});
