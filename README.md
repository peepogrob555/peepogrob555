<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>Block Puzzle Pro</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;600;700&family=Space+Mono:wght@400;700&display=swap');

  :root {
    --bg: #0a0a0f;
    --surface: #12121a;
    --border: #1e1e2e;
    --accent: #7c6fcd;
    --accent2: #e879f9;
    --green: #22d3ee;
    --score-glow: 0 0 20px #7c6fcd88;
    --cell-size: min(9vw, 42px);
    --gap: min(1vw, 4px);
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: #e0e0f0;
    font-family: 'Space Grotesk', sans-serif;
    min-height: 100dvh;
    display: flex;
    flex-direction: column;
    align-items: center;
    overflow-x: hidden;
    padding-bottom: 24px;
  }

  /* ── Header ── */
  header {
    width: 100%;
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 14px 20px 10px;
    border-bottom: 1px solid var(--border);
  }
  .logo {
    font-family: 'Space Mono', monospace;
    font-size: 15px;
    font-weight: 700;
    letter-spacing: 2px;
    color: var(--accent);
    text-transform: uppercase;
  }
  .logo span { color: var(--accent2); }

  /* ── Score ── */
  .score-area {
    display: flex;
    gap: 10px;
    margin: 14px 0 10px;
    width: 100%;
    max-width: 380px;
    padding: 0 12px;
  }
  .score-box {
    flex: 1;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 10px 12px;
    text-align: center;
  }
  .score-box label {
    display: block;
    font-size: 9px;
    letter-spacing: 2px;
    text-transform: uppercase;
    color: #666;
    margin-bottom: 4px;
  }
  .score-box .val {
    font-family: 'Space Mono', monospace;
    font-size: 22px;
    font-weight: 700;
    color: var(--accent);
    text-shadow: var(--score-glow);
    transition: all 0.15s;
  }
  .score-box.best .val { color: var(--accent2); }
  .score-box .combo-val {
    font-family: 'Space Mono', monospace;
    font-size: 20px;
    font-weight: 700;
    color: var(--green);
    text-shadow: 0 0 16px #22d3ee88;
  }

  /* ── Board ── */
  .board-wrap {
    position: relative;
    margin: 4px 0;
  }

  #board-canvas {
    display: block;
    border-radius: 14px;
    border: 1px solid var(--border);
    touch-action: none;
  }

  /* ── Float score animation ── */
  .float-score {
    position: fixed;
    font-family: 'Space Mono', monospace;
    font-size: 22px;
    font-weight: 700;
    color: #fff;
    pointer-events: none;
    text-shadow: 0 0 20px var(--accent2);
    animation: floatUp 0.9s ease-out forwards;
    z-index: 999;
  }
  @keyframes floatUp {
    0%   { opacity: 1; transform: translateY(0) scale(1); }
    80%  { opacity: 1; transform: translateY(-60px) scale(1.3); }
    100% { opacity: 0; transform: translateY(-90px) scale(0.8); }
  }

  /* ── Shape tray ── */
  .tray {
    display: flex;
    gap: 8px;
    margin: 8px 0;
    width: 100%;
    max-width: 380px;
    padding: 0 10px;
    justify-content: center;
  }
  .shape-card {
    flex: 1;
    background: var(--surface);
    border: 2px solid var(--border);
    border-radius: 14px;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 8px 4px;
    min-height: 80px;
    position: relative;
    transition: border-color 0.2s, transform 0.1s;
    cursor: pointer;
  }
  .shape-card.selected {
    border-color: var(--accent);
    transform: translateY(-3px);
    box-shadow: 0 6px 20px #7c6fcd44;
  }
  .shape-card.used { opacity: 0.28; }
  .shape-canvas { display: block; }

  /* ── Buttons ── */
  .btn-row {
    display: flex;
    gap: 8px;
    margin-top: 10px;
    width: 100%;
    max-width: 380px;
    padding: 0 12px;
  }
  .btn {
    flex: 1;
    padding: 12px 0;
    border: none;
    border-radius: 10px;
    font-family: 'Space Grotesk', sans-serif;
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 1px;
    cursor: pointer;
    transition: opacity 0.15s, transform 0.1s;
  }
  .btn:active { transform: scale(0.95); opacity: 0.8; }
  .btn-primary { background: var(--accent); color: #fff; }
  .btn-outline { background: transparent; border: 1px solid var(--border); color: #aaa; }
  .btn-ai {
    background: linear-gradient(135deg, var(--accent), var(--accent2));
    color: #fff;
    flex: 2;
  }

  /* ── AI Hint overlay ── */
  .hint-info {
    width: 100%;
    max-width: 380px;
    padding: 0 12px;
    margin-top: 8px;
    font-size: 12px;
    color: #888;
    text-align: center;
    min-height: 18px;
  }

  /* ── Toast ── */
  .toast {
    position: fixed;
    bottom: 30px;
    left: 50%;
    transform: translateX(-50%);
    background: #1e1e2e;
    border: 1px solid var(--accent);
    color: #e0e0f0;
    padding: 10px 22px;
    border-radius: 100px;
    font-size: 13px;
    font-weight: 600;
    z-index: 1000;
    opacity: 0;
    transition: opacity 0.3s;
    pointer-events: none;
  }
  .toast.show { opacity: 1; }

  /* ── Game Over overlay ── */
  .overlay {
    display: none;
    position: fixed;
    inset: 0;
    background: #0a0a0fcc;
    backdrop-filter: blur(6px);
    z-index: 100;
    align-items: center;
    justify-content: center;
  }
  .overlay.show { display: flex; }
  .over-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 20px;
    padding: 36px 28px;
    text-align: center;
    max-width: 320px;
    width: 90vw;
  }
  .over-card h2 {
    font-size: 28px;
    font-weight: 700;
    color: var(--accent2);
    margin-bottom: 6px;
  }
  .over-card .final-score {
    font-family: 'Space Mono', monospace;
    font-size: 48px;
    font-weight: 700;
    color: var(--accent);
    text-shadow: var(--score-glow);
    margin: 12px 0;
  }
  .over-card p { color: #666; font-size: 13px; margin-bottom: 20px; }

  /* ── Particles ── */
  .particle {
    position: fixed;
    pointer-events: none;
    border-radius: 2px;
    animation: particleFly 0.7s ease-out forwards;
    z-index: 998;
  }
  @keyframes particleFly {
    0%   { opacity: 1; transform: translate(0,0) scale(1); }
    100% { opacity: 0; transform: translate(var(--tx), var(--ty)) scale(0); }
  }
</style>
</head>
<body>

<header>
  <div class="logo">Block<span>Puzzle</span></div>
  <div style="font-size:11px;color:#555;letter-spacing:1px;">PRO EDITION</div>
</header>

<div class="score-area">
  <div class="score-box">
    <label>Score</label>
    <div class="val" id="scoreVal">0</div>
  </div>
  <div class="score-box">
    <label>Combo</label>
    <div class="combo-val" id="comboVal">×1</div>
  </div>
  <div class="score-box best">
    <label>Best</label>
    <div class="val" id="bestVal">0</div>
  </div>
</div>

<div class="board-wrap">
  <canvas id="board-canvas"></canvas>
</div>

<div class="tray" id="tray"></div>

<div class="btn-row">
  <button class="btn btn-outline" onclick="resetGame()">↺ New</button>
  <button class="btn btn-ai" onclick="triggerAI()">✦ AI Solve</button>
</div>

<div class="hint-info" id="hintInfo"></div>

<div class="toast" id="toast"></div>

<div class="overlay" id="overlay">
  <div class="over-card">
    <h2>Game Over</h2>
    <div class="final-score" id="finalScore">0</div>
    <p>No more moves available</p>
    <button class="btn btn-primary" style="width:100%;margin-top:4px" onclick="resetGame();document.getElementById('overlay').classList.remove('show')">Play Again</button>
  </div>
</div>

<script>
// ──────────────────────────────────────────
// CONSTANTS & STATE
// ──────────────────────────────────────────
const GRID = 8;
const PALETTE = [
  ['#7c6fcd','#a89ae0'],  // purple
  ['#e879f9','#f0abfc'],  // pink
  ['#22d3ee','#67e8f9'],  // cyan
  ['#f59e0b','#fcd34d'],  // amber
  ['#4ade80','#86efac'],  // green
  ['#f87171','#fca5a5'],  // red
];

// Canonical piece library (trimmed)
const PIECE_LIBRARY = [
  [[1]],                        // 1×1
  [[1,1]],                      // 1×2 H
  [[1],[1]],                    // 1×2 V
  [[1,1,1]],                    // 1×3 H
  [[1],[1],[1]],                // 1×3 V
  [[1,1,1,1]],                  // 1×4 H
  [[1],[1],[1],[1]],            // 1×4 V
  [[1,1],[1,1]],                // 2×2
  [[1,1,1],[1,0,0]],            // L
  [[1,1,1],[0,0,1]],            // J
  [[1,0],[1,0],[1,1]],          // L-V
  [[0,1],[0,1],[1,1]],          // J-V
  [[1,1,0],[0,1,1]],            // S
  [[0,1,1],[1,1,0]],            // Z
  [[0,1,0],[1,1,1]],            // T
  [[1,1,1],[0,1,0]],            // T2
  [[1,0],[1,1],[0,1]],          // S-V
  [[0,1],[1,1],[1,0]],          // Z-V
  [[1,1,1],[1,0,0],[1,0,0]],    // big-L
  [[1,1,1],[0,0,1],[0,0,1]],    // big-J
  [[1,1,1,1,1]],                // I-5
  [[1],[1],[1],[1],[1]],        // I-5V
  [[1,1,1],[1,1,1]],            // 3×2 rect
  [[1,1],[1,1],[1,1]],          // 2×3 rect
  [[1,1,1],[1,0,1],[1,1,1]],    // O-frame
];

let board, shapes, selectedShape, score, best, combo, hintMode, hintSeq, hintStep;
let boardCanvas, boardCtx, cellSize, boardPad;

// ──────────────────────────────────────────
// INIT
// ──────────────────────────────────────────
function initCanvas() {
  boardCanvas = document.getElementById('board-canvas');
  const W = Math.min(window.innerWidth - 24, 380);
  boardCanvas.width  = W;
  boardCanvas.height = W;
  boardCtx = boardCanvas.getContext('2d');
  cellSize = (W - 16) / GRID;
  boardPad = 8;
  boardCanvas.addEventListener('touchstart', onBoardTouch, {passive:false});
  boardCanvas.addEventListener('click', onBoardClick);
}

function resetGame() {
  board = Array.from({length:GRID}, () => Array(GRID).fill(null));
  score = 0; combo = 1;
  selectedShape = null; hintMode = false; hintSeq = null; hintStep = 0;
  best = parseInt(localStorage.getItem('blockBest')||'0');
  updateScoreUI();
  spawnShapes();
  renderAll();
}

// ──────────────────────────────────────────
// SHAPES
// ──────────────────────────────────────────
function randPiece() {
  const p = PIECE_LIBRARY[Math.floor(Math.random() * PIECE_LIBRARY.length)];
  const color = PALETTE[Math.floor(Math.random() * PALETTE.length)];
  return { cells: p.map(r => [...r]), color, used: false };
}

function spawnShapes() {
  shapes = [randPiece(), randPiece(), randPiece()];
  selectedShape = null;
  hintMode = false; hintSeq = null;
  renderTray();
  document.getElementById('hintInfo').textContent = '';
  if (!anyMovePossible()) {
    setTimeout(gameOver, 400);
  }
}

function renderTray() {
  const tray = document.getElementById('tray');
  tray.innerHTML = '';
  shapes.forEach((sh, i) => {
    const card = document.createElement('div');
    card.className = 'shape-card' + (sh.used ? ' used' : '') + (selectedShape === i && !sh.used ? ' selected' : '');
    card.onclick = () => selectShape(i);
    const cv = document.createElement('canvas');
    cv.className = 'shape-canvas';
    const maxDim = Math.max(sh.cells.length, sh.cells[0].length);
    const s = Math.min(52 / maxDim, 14);
    cv.width  = sh.cells[0].length * s + 2;
    cv.height = sh.cells.length    * s + 2;
    const cx = cv.getContext('2d');
    sh.cells.forEach((row, r) => row.forEach((v, c) => {
      if (!v) return;
      const grad = cx.createLinearGradient(c*s, r*s, c*s+s, r*s+s);
      grad.addColorStop(0, sh.color[0]);
      grad.addColorStop(1, sh.color[1]);
      cx.fillStyle = grad;
      cx.beginPath();
      cx.roundRect(c*s+1, r*s+1, s-2, s-2, 2);
      cx.fill();
    }));
    card.appendChild(cv);
    tray.appendChild(card);
  });
}

function selectShape(i) {
  if (shapes[i].used) return;
  selectedShape = (selectedShape === i) ? null : i;
  hintMode = false;
  renderTray();
  renderBoard();
  document.getElementById('hintInfo').textContent = selectedShape !== null ? 'Tap a cell on the board to place' : '';
}

// ──────────────────────────────────────────
// BOARD RENDERING
// ──────────────────────────────────────────
function renderBoard(ghostR=-1, ghostC=-1) {
  const ctx = boardCtx;
  const W = boardCanvas.width;
  ctx.clearRect(0,0,W,W);

  // Background glow
  const bgGrad = ctx.createRadialGradient(W/2,W/2,0,W/2,W/2,W*0.7);
  bgGrad.addColorStop(0,'#131320');
  bgGrad.addColorStop(1,'#0a0a0f');
  ctx.fillStyle = bgGrad;
  ctx.beginPath(); ctx.roundRect(0,0,W,W,14); ctx.fill();

  // Grid dots
  ctx.fillStyle = '#1a1a2a';
  for (let r=0;r<GRID;r++) for (let c=0;c<GRID;c++) {
    const x = boardPad + c*cellSize, y = boardPad + r*cellSize;
    ctx.strokeStyle = '#1e1e30';
    ctx.lineWidth = 0.5;
    ctx.strokeRect(x+1,y+1,cellSize-2,cellSize-2);
  }

  // Ghost highlight for hint
  let ghostCells = null;
  if (hintMode && hintSeq && hintStep < hintSeq.length) {
    const step = hintSeq[hintStep];
    ghostCells = getOccupiedCells(shapes[step.shape].cells, step.r, step.c);
  } else if (selectedShape !== null && ghostR >= 0) {
    const sh = shapes[selectedShape];
    if (canPlace(sh.cells, ghostR, ghostC, board)) {
      ghostCells = getOccupiedCells(sh.cells, ghostR, ghostC);
    }
  }
  if (ghostCells) {
    ghostCells.forEach(([r,c]) => {
      const x = boardPad + c*cellSize, y = boardPad + r*cellSize;
      ctx.fillStyle = hintMode ? '#7c6fcd44' : '#ffffff22';
      ctx.beginPath(); ctx.roundRect(x+2,y+2,cellSize-4,cellSize-4,4); ctx.fill();
    });
  }

  // Placed cells
  for (let r=0;r<GRID;r++) for (let c=0;c<GRID;c++) {
    if (!board[r][c]) continue;
    const x = boardPad + c*cellSize, y = boardPad + r*cellSize;
    const col = board[r][c];
    const grad = ctx.createLinearGradient(x,y,x+cellSize,y+cellSize);
    grad.addColorStop(0, col[0]);
    grad.addColorStop(1, col[1]);
    ctx.fillStyle = grad;
    ctx.shadowColor = col[0];
    ctx.shadowBlur = 8;
    ctx.beginPath();
    ctx.roundRect(x+2, y+2, cellSize-4, cellSize-4, 5);
    ctx.fill();
    ctx.shadowBlur = 0;

    // Shine
    ctx.fillStyle = 'rgba(255,255,255,0.12)';
    ctx.beginPath();
    ctx.roundRect(x+3, y+3, cellSize-6, (cellSize-6)*0.45, [4,4,0,0]);
    ctx.fill();
  }

  // Hint step arrow overlay
  if (hintMode && hintSeq && hintStep < hintSeq.length) {
    const step = hintSeq[hintStep];
    const x = boardPad + step.c*cellSize + cellSize/2;
    const y = boardPad + step.r*cellSize + cellSize/2;
    ctx.fillStyle = '#7c6fcd';
    ctx.shadowColor = '#7c6fcd';
    ctx.shadowBlur = 12;
    ctx.beginPath();
    ctx.arc(x, y, 5, 0, Math.PI*2);
    ctx.fill();
    ctx.shadowBlur = 0;
  }
}

function renderAll() { renderBoard(); renderTray(); updateScoreUI(); }

// ──────────────────────────────────────────
// PLACEMENT LOGIC
// ──────────────────────────────────────────
function getOccupiedCells(cells, r, c) {
  const out = [];
  cells.forEach((row, dr) => row.forEach((v, dc) => { if(v) out.push([r+dr, c+dc]); }));
  return out;
}

function canPlace(cells, r, c, b) {
  return cells.every((row, dr) => row.every((v, dc) => {
    if (!v) return true;
    const nr = r+dr, nc = c+dc;
    return nr>=0 && nc>=0 && nr<GRID && nc<GRID && !b[nr][nc];
  }));
}

function placeShape(shapeIdx, r, c) {
  const sh = shapes[shapeIdx];
  const occ = getOccupiedCells(sh.cells, r, c);
  occ.forEach(([rr,cc]) => { board[rr][cc] = sh.color; });
  const cleared = clearLines();
  sh.used = true;

  // Score
  const placePts = occ.length * 10;
  const clearPts = cleared * 50 * combo;
  if (cleared > 0) {
    combo = Math.min(combo + 1, 8);
    spawnParticles(occ);
  } else {
    combo = Math.max(1, combo - 1);
  }
  const pts = placePts + clearPts;
  score += pts;
  if (score > best) { best = score; localStorage.setItem('blockBest', best); }
  showFloatScore(r, c, pts);
  updateScoreUI();

  if (shapes.every(s => s.used)) {
    setTimeout(spawnShapes, 300);
  } else {
    renderAll();
    if (!anyMovePossible()) setTimeout(gameOver, 400);
  }
}

function clearLines() {
  let cleared = 0;
  const toFlash = [];
  for (let r=0;r<GRID;r++) if (board[r].every(v=>v)) { toFlash.push({type:'row', idx:r}); }
  for (let c=0;c<GRID;c++) if (board.every(r=>r[c])) { toFlash.push({type:'col', idx:c}); }
  if (!toFlash.length) return 0;
  toFlash.forEach(({type, idx}) => {
    cleared++;
    for (let i=0;i<GRID;i++) {
      if (type==='row') board[idx][i] = null;
      else board[i][idx] = null;
    }
  });
  return cleared;
}

function anyMovePossible() {
  return shapes.some(sh => {
    if (sh.used) return false;
    for (let r=0;r<GRID;r++) for (let c=0;c<GRID;c++) {
      if (canPlace(sh.cells, r, c, board)) return true;
    }
    return false;
  });
}

// ──────────────────────────────────────────
// INPUT
// ──────────────────────────────────────────
let hoverR = -1, hoverC = -1;

function getBoardCell(clientX, clientY) {
  const rect = boardCanvas.getBoundingClientRect();
  const scaleX = boardCanvas.width / rect.width;
  const scaleY = boardCanvas.height / rect.height;
  const x = (clientX - rect.left) * scaleX - boardPad;
  const y = (clientY - rect.top) * scaleY - boardPad;
  return [Math.floor(y / cellSize), Math.floor(x / cellSize)];
}

boardCanvas && boardCanvas.addEventListener('mousemove', e => {
  const [r,c] = getBoardCell(e.clientX, e.clientY);
  if (r !== hoverR || c !== hoverC) { hoverR=r; hoverC=c; renderBoard(r,c); }
});

function onBoardClick(e) { handleBoardInput(e.clientX, e.clientY); }
function onBoardTouch(e) {
  e.preventDefault();
  const t = e.touches[0];
  handleBoardInput(t.clientX, t.clientY);
}

function handleBoardInput(cx, cy) {
  const [r,c] = getBoardCell(cx, cy);
  if (r<0||c<0||r>=GRID||c>=GRID) return;

  if (hintMode && hintSeq && hintStep < hintSeq.length) {
    const step = hintSeq[hintStep];
    if (canPlace(shapes[step.shape].cells, step.r, step.c, board)) {
      placeShape(step.shape, step.r, step.c);
      hintStep++;
      if (hintStep >= hintSeq.length || shapes.every(s=>s.used)) {
        hintMode = false; hintSeq = null;
        document.getElementById('hintInfo').textContent = '✓ AI hint complete!';
      } else {
        const s = hintSeq[hintStep];
        document.getElementById('hintInfo').textContent =
          `AI hint ${hintStep+1}/${hintSeq.length} — tap highlighted cell`;
      }
      renderAll();
    }
    return;
  }

  if (selectedShape === null) { showToast('Select a piece first'); return; }
  const sh = shapes[selectedShape];
  if (sh.used) return;
  if (!canPlace(sh.cells, r, c, board)) { showToast('Cannot place here'); return; }
  placeShape(selectedShape, r, c);
  selectedShape = null;
}

// ──────────────────────────────────────────
// AI — BEAM SEARCH (much smarter)
// ──────────────────────────────────────────
function evalBoard(b) {
  let filled = 0, isolated = 0, edges = 0;
  const rows = Array(GRID).fill(0), cols = Array(GRID).fill(0);

  for (let r=0;r<GRID;r++) for (let c=0;c<GRID;c++) {
    if (b[r][c]) { filled++; rows[r]++; cols[c]++; }
  }

  // Almost-complete line bonus (8 or 7 filled = huge bonus)
  for (let i=0;i<GRID;i++) {
    if (rows[i]===8) edges += 200;
    else if (rows[i]>=6) edges += (rows[i]-5)*30;
    if (cols[i]===8) edges += 200;
    else if (cols[i]>=6) edges += (cols[i]-5)*30;
  }

  // Penalty: isolated empty squares (surrounded by filled)
  for (let r=0;r<GRID;r++) for (let c=0;c<GRID;c++) {
    if (b[r][c]) continue;
    const ns = [[r-1,c],[r+1,c],[r,c-1],[r,c+1]];
    const wallsFilled = ns.filter(([nr,nc]) =>
      nr<0||nc<0||nr>=GRID||nc>=GRID || b[nr][nc]
    ).length;
    if (wallsFilled >= 3) isolated++;
  }

  // Open space is slightly good
  const empty = GRID*GRID - filled;

  return edges + filled*2 - isolated*15 + empty*0.5;
}

function simulatePlace(b, cells, r, c, color) {
  const nb = b.map(row => [...row]);
  cells.forEach((row, dr) => row.forEach((v, dc) => {
    if (v) nb[r+dr][c+dc] = color;
  }));
  // Clear lines
  const rowsToClear = [], colsToClear = [];
  for (let i=0;i<GRID;i++) {
    if (nb[i].every(v=>v)) rowsToClear.push(i);
    if (nb.every(rw=>rw[i])) colsToClear.push(i);
  }
  rowsToClear.forEach(ri => { for (let ci=0;ci<GRID;ci++) nb[ri][ci]=null; });
  colsToClear.forEach(ci => { for (let ri=0;ri<GRID;ri++) nb[ri][ci]=null; });
  return { board: nb, cleared: rowsToClear.length + colsToClear.length };
}

function getBestPlacement(b, cells) {
  let best = null, bestScore = -Infinity;
  for (let r=0;r<GRID;r++) for (let c=0;c<GRID;c++) {
    if (!canPlace(cells, r, c, b)) continue;
    const { board: nb, cleared } = simulatePlace(b, cells, r, c, [[1],[1]]);
    const s = evalBoard(nb) + cleared*150;
    if (s > bestScore) { bestScore=s; best={r,c,score:s}; }
  }
  return best;
}

function triggerAI() {
  const available = shapes.map((s,i) => s.used ? null : i).filter(v=>v!==null);
  if (!available.length) { showToast('No pieces to place'); return; }

  // Try all permutations of available shapes, pick best sequence
  const perms = permutations(available);
  let bestScore = -Infinity, bestPerm = null, bestPlacements = null;

  for (const perm of perms) {
    let b = board.map(r=>[...r]);
    let seq = [], valid = true, totalScore = 0;

    for (const si of perm) {
      const placement = getBestPlacement(b, shapes[si].cells);
      if (!placement) { valid = false; break; }
      seq.push({ shape: si, r: placement.r, c: placement.c });
      const { board: nb, cleared } = simulatePlace(b, shapes[si].cells, placement.r, placement.c, shapes[si].color);
      b = nb;
      totalScore += placement.score + cleared*200;
    }
    if (valid && totalScore > bestScore) {
      bestScore = totalScore; bestPerm = perm; bestPlacements = seq;
    }
  }

  if (!bestPlacements || !bestPlacements.length) { showToast('No valid moves found'); return; }

  hintSeq = bestPlacements;
  hintStep = 0;
  hintMode = true;

  // Auto-select first shape
  selectedShape = hintSeq[0].shape;
  renderAll();
  document.getElementById('hintInfo').textContent =
    `AI hint 1/${hintSeq.length} — tap the highlighted cell`;
}

function permutations(arr) {
  if (arr.length <= 1) return [arr];
  const out = [];
  arr.forEach((v,i) => {
    const rest = [...arr.slice(0,i), ...arr.slice(i+1)];
    permutations(rest).forEach(p => out.push([v,...p]));
  });
  return out;
}

// ──────────────────────────────────────────
// UI HELPERS
// ──────────────────────────────────────────
function updateScoreUI() {
  document.getElementById('scoreVal').textContent = score.toLocaleString();
  document.getElementById('bestVal').textContent  = best.toLocaleString();
  document.getElementById('comboVal').textContent = `×${combo}`;
}

function showFloatScore(r, c, pts) {
  const rect = boardCanvas.getBoundingClientRect();
  const x = rect.left + boardPad + c*cellSize*(rect.width/boardCanvas.width) + 20;
  const y = rect.top  + boardPad + r*cellSize*(rect.height/boardCanvas.height);
  const el = document.createElement('div');
  el.className = 'float-score';
  el.textContent = `+${pts}`;
  el.style.left = x+'px'; el.style.top = y+'px';
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 900);
}

function spawnParticles(cells) {
  const rect = boardCanvas.getBoundingClientRect();
  cells.slice(0,6).forEach(([r,c]) => {
    for (let k=0;k<4;k++) {
      const el = document.createElement('div');
      el.className = 'particle';
      el.style.width = el.style.height = (4+Math.random()*5)+'px';
      el.style.background = PALETTE[Math.floor(Math.random()*PALETTE.length)][0];
      el.style.left = (rect.left + boardPad + (c+0.5)*cellSize*(rect.width/boardCanvas.width))+'px';
      el.style.top  = (rect.top  + boardPad + (r+0.5)*cellSize*(rect.height/boardCanvas.height))+'px';
      const angle = Math.random()*Math.PI*2;
      const dist  = 30+Math.random()*60;
      el.style.setProperty('--tx', Math.cos(angle)*dist+'px');
      el.style.setProperty('--ty', Math.sin(angle)*dist+'px');
      document.body.appendChild(el);
      setTimeout(()=>el.remove(), 700);
    }
  });
}

let toastTimer;
function showToast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 2000);
}

function gameOver() {
  document.getElementById('finalScore').textContent = score.toLocaleString();
  document.getElementById('overlay').classList.add('show');
}

// ──────────────────────────────────────────
// BOOT
// ──────────────────────────────────────────
window.addEventListener('load', () => {
  initCanvas();
  resetGame();

  // Re-init canvas on resize
  window.addEventListener('resize', () => {
    initCanvas();
    renderBoard();
  });
});
</script>
</body>
</html>
