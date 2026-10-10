// ÆtherCodex — The Veil
// A subtle hermetic background: a breathing aurora, faint watching eyes,
// and slow dust motes. The eyes drift quietly and dilate near the cursor —
// the oracle observing, never shouting. Respects prefers-reduced-motion and
// pauses while the tab is hidden.
(function () {
  'use strict';

  var container = document.getElementById('eyes-container');
  if (!container) return;

  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  var canvas = document.createElement('canvas');
  canvas.setAttribute('aria-hidden', 'true');
  var ctx = canvas.getContext('2d');
  container.appendChild(canvas);

  var W = 0, H = 0, dpr = 1;
  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = container.clientWidth || window.innerWidth;
    H = container.clientHeight || window.innerHeight;
    canvas.width = Math.floor(W * dpr);
    canvas.height = Math.floor(H * dpr);
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  resize();
  window.addEventListener('resize', resize);

  var mouse = { x: -9999, y: -9999 };
  window.addEventListener('mousemove', function (e) {
    mouse.x = e.clientX;
    mouse.y = e.clientY;
  });

  var PALETTE = ['#4a90e2', '#8e44ad', '#6c5ce7', '#f39c12'];

  /* ---- watching eyes ---- */
  var eyes = [];
  function makeEye() {
    return {
      x: Math.random() * W,
      y: Math.random() * H,
      rx: 9 + Math.random() * 14,
      ry: 3.2 + Math.random() * 4.2,
      vx: (Math.random() - 0.5) * 0.12,
      vy: (Math.random() - 0.5) * 0.1,
      phase: Math.random() * Math.PI * 2,
      color: PALETTE[(Math.random() * PALETTE.length) | 0],
      base: 0.05 + Math.random() * 0.08, // resting alpha — barely there
      alpha: 0
    };
  }

  var EYE_COUNT = reduceMotion
    ? 0
    : Math.min(14, Math.max(8, Math.round(W / 170)));
  for (var i = 0; i < EYE_COUNT; i++) eyes.push(makeEye());

  /* ---- dust motes ---- */
  var motes = [];
  function makeMote() {
    return {
      x: Math.random() * W,
      y: Math.random() * H,
      r: 0.4 + Math.random() * 1.1,
      vx: (Math.random() - 0.5) * 0.06,
      vy: -(0.06 + Math.random() * 0.18),
      a: 0.04 + Math.random() * 0.14,
      phase: Math.random() * Math.PI * 2,
      color: PALETTE[(Math.random() * PALETTE.length) | 0]
    };
  }
  var MOTE_COUNT = reduceMotion ? 0 : Math.min(70, Math.round(W / 28));
  for (var j = 0; j < MOTE_COUNT; j++) motes.push(makeMote());

  var t = 0;
  var raf = null;
  var running = false;

  function drawAurora() {
    var cx = W * 0.5, cy = H * 0.42;
    var r = Math.max(W, H) * 0.9;
    var b1 = 0.06 + 0.03 * Math.sin(t * 0.00012);
    var b2 = 0.05 + 0.03 * Math.sin(t * 0.00009 + 1.7);

    var g1 = ctx.createRadialGradient(cx - W * 0.12, cy - H * 0.1, 0, cx - W * 0.12, cy - H * 0.1, r);
    g1.addColorStop(0, 'rgba(74,144,226,' + b1 + ')');
    g1.addColorStop(0.55, 'rgba(74,144,226,0)');
    ctx.fillStyle = g1;
    ctx.fillRect(0, 0, W, H);

    var g2 = ctx.createRadialGradient(cx + W * 0.16, cy + H * 0.14, 0, cx + W * 0.16, cy + H * 0.14, r);
    g2.addColorStop(0, 'rgba(142,68,173,' + b2 + ')');
    g2.addColorStop(0.55, 'rgba(142,68,173,0)');
    ctx.fillStyle = g2;
    ctx.fillRect(0, 0, W, H);
  }

  function draw() {
    t++;
    ctx.clearRect(0, 0, W, H);
    drawAurora();

    var i, m, e;

    /* motes */
    for (i = 0; i < motes.length; i++) {
      m = motes[i];
      m.x += m.vx;
      m.y += m.vy;
      if (m.y < -4) { m.y = H + 4; m.x = Math.random() * W; }
      if (m.x < -4) m.x = W + 4; else if (m.x > W + 4) m.x = -4;
      var tw = 0.6 + 0.4 * Math.sin(t * 0.02 + m.phase);
      ctx.globalAlpha = m.a * tw;
      ctx.fillStyle = m.color;
      ctx.beginPath();
      ctx.arc(m.x, m.y, m.r, 0, Math.PI * 2);
      ctx.fill();
    }

    /* eyes */
    for (i = 0; i < eyes.length; i++) {
      e = eyes[i];
      e.x += e.vx;
      e.y += e.vy;
      if (e.x < -40) e.x = W + 40; else if (e.x > W + 40) e.x = -40;
      if (e.y < -40) e.y = H + 40; else if (e.y > H + 40) e.y = -40;

      var dx = e.x - mouse.x, dy = e.y - mouse.y;
      var d = Math.sqrt(dx * dx + dy * dy);
      var near = d < 160;
      var target = near ? e.base + 0.14 * (1 - d / 160) : e.base;
      e.alpha += (target - e.alpha) * 0.05;

      ctx.globalAlpha = e.alpha;
      ctx.strokeStyle = e.color;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.ellipse(e.x, e.y, e.rx, e.ry, 0, 0, Math.PI * 2);
      ctx.stroke();

      ctx.fillStyle = e.color;
      ctx.beginPath();
      ctx.ellipse(e.x, e.y, e.rx * (near ? 0.34 : 0.24), e.ry * 0.86, 0, 0, Math.PI * 2);
      ctx.fill();
    }

    ctx.globalAlpha = 1;
    raf = requestAnimationFrame(draw);
  }

  function start() {
    if (running || reduceMotion) return;
    running = true;
    draw();
  }
  function stop() {
    running = false;
    if (raf) { cancelAnimationFrame(raf); raf = null; }
  }

  if (reduceMotion) {
    drawAurora(); // single static frame, no loop
  } else {
    start();
  }

  document.addEventListener('visibilitychange', function () {
    if (document.hidden) stop(); else start();
  });

  /* ---- scroll reveal ---- */
  var revealEls = document.querySelectorAll('[data-reveal]');
  if ('IntersectionObserver' in window && !reduceMotion) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('in-view');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add('in-view'); });
  }
})();
