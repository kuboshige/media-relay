const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { execFile } = require('child_process');

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

// ---- SHA256ハッシュ・インデックス（重複判定の高速化） ----
// 対象フォルダ配下を一度だけ走査してSHA256の集合を作りメモリに保持する。
// アップロード時は差分追加、POST /reindex で再構築できる。

let hashIndex = null; // Set<string> | null
let building = null; // Promise | null

function* walkFiles(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return; // 存在しない/権限なしは無視
  }
  for (const entry of entries) {
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

async function buildIndex() {
  const idx = new Set();
  let count = 0;
  const start = Date.now();
  for (const root of SCAN_DIRS) {
    for (const file of walkFiles(root)) {
      const hex = await sha256OfFileStream(file);
      if (hex) {
        idx.add(hex);
        count++;
      }
    }
  }
  hashIndex = idx;
  const sec = ((Date.now() - start) / 1000).toFixed(1);
  console.log(`[index] built: ${count} files / ${idx.size} unique hashes in ${sec}s`);
  console.log(`[index] dirs: ${SCAN_DIRS.join(', ')}`);
  return idx;
}

function ensureIndex() {
  if (hashIndex) return Promise.resolve(hashIndex);
  if (!building) {
    building = buildIndex().finally(() => {
      building = null;
    });
  }
  return building;
}

// ファイル存在確認（SHA256照合）。インデックス未構築なら構築完了を待つ。
app.get('/exists', async (req, res) => {
  const { hash } = req.query;
  if (!hash || !/^[a-f0-9]{64}$/.test(hash)) {
    return res.status(400).json({ error: 'invalid hash' });
  }
  try {
    const idx = await ensureIndex();
    res.json({ exists: idx.has(hash) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// インデックス再構築（クイックシェアで新たに受信したファイルを取り込む）
app.post('/reindex', async (req, res) => {
  hashIndex = null;
  building = null;
  try {
    const idx = await ensureIndex();
    res.json({ ok: true, count: idx.size, dirs: SCAN_DIRS });
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
  // インデックスが構築済みなら差分追加（再構築不要で即座に重複判定に反映）
  if (hashIndex) hashIndex.add(hash);

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
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`media-relay server listening on port ${PORT}`);
  console.log(`storage: ${STORAGE_ROOT}`);
  console.log(`scan dirs: ${SCAN_DIRS.join(', ')}`);
  // 起動時にバックグラウンドでインデックスを構築しておく
  ensureIndex().catch((e) => console.error('[index] build error:', e.message));
});
