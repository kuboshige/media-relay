const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 8765;

// Termux環境では /sdcard/MediaRelay、それ以外はカレントの storage/
const STORAGE_ROOT = process.env.STORAGE_ROOT
  || (process.env.HOME && process.env.HOME.includes('com.termux')
      ? '/sdcard/MediaRelay'
      : path.join(__dirname, 'storage'));

fs.mkdirSync(STORAGE_ROOT, { recursive: true });

// マルチパートを受け取るが保存先はrelativePathで決める
const upload = multer({ storage: multer.memoryStorage() });

function sha256OfFile(filePath) {
  const buf = fs.readFileSync(filePath);
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// ファイル存在確認
app.get('/exists', (req, res) => {
  const { hash } = req.query;
  if (!hash || !/^[a-f0-9]{64}$/.test(hash)) {
    return res.status(400).json({ error: 'invalid hash' });
  }

  // STORAGE_ROOT 以下を再帰的に探してSHA256が一致するファイルを探す
  function findByHash(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (findByHash(full)) return true;
      } else {
        if (sha256OfFile(full) === hash) return true;
      }
    }
    return false;
  }

  try {
    const found = findByHash(STORAGE_ROOT);
    res.json({ exists: found });
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

  // パストラバーサル対策
  const normalized = path.normalize(relativePath).replace(/^(\.\.(\/|\\|$))+/, '');
  const destPath = path.join(STORAGE_ROOT, normalized);

  // ディレクトリ作成
  fs.mkdirSync(path.dirname(destPath), { recursive: true });

  // 書き込み
  fs.writeFileSync(destPath, req.file.buffer);

  const hash = crypto.createHash('sha256').update(req.file.buffer).digest('hex');
  console.log(`[upload] ${normalized} (${req.file.size} bytes, sha256=${hash})`);

  res.json({ ok: true, relativePath: normalized, sha256: hash, size: req.file.size });
});

// サーバー状態確認
app.get('/ping', (req, res) => {
  res.json({ ok: true, storageRoot: STORAGE_ROOT });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`media-relay server listening on port ${PORT}`);
  console.log(`storage: ${STORAGE_ROOT}`);
});
