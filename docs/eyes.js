// Ætheric Companion Drift — the council breathes through the void.
// Ten companions + the hermetic eye, drifting, mirroring, glowing near the cursor.
(function () {
  'use strict';

  var glyphs = ['🦉', '🦊', '🔥', '🐍', '🐈', '🐺', '🌊', '🦢', '🐉', '🐦‍⬛', '👁'];
  var colors = [
    '#4a90e2', '#8e44ad', '#f39c12', '#6c5ce7', '#17a2b8',
    '#e74c3c', '#27ae60', '#dc2626', '#f59e0b', '#7c3aed', '#f8f9fa'
  ];

  var container = document.getElementById('eyes-container');
  if (!container) return;

  var mouseX = 0, mouseY = 0;
  document.addEventListener('mousemove', function (e) {
    mouseX = 100 * (e.clientX / (window.visualViewport ? window.visualViewport.width : window.innerWidth));
    mouseY = 100 * (e.clientY / (window.visualViewport ? window.visualViewport.height : window.innerHeight));
  });

  function spawn() {
    var el = document.createElement('div');
    el.className = 'eye';
    el.textContent = glyphs[Math.floor(Math.random() * glyphs.length)];
    var color = colors[Math.floor(Math.random() * colors.length)];
    el.style.color = color;

    var size = Math.random() * 5 + 1.2;
    el.style.fontSize = size + 'rem';

    var x = Math.random() * 100;
    var y = Math.random() * 100;
    var sx = Math.random() * 0.3 - 0.15;
    var sy = Math.random() * 0.5 - 0.2;
    var scale = Math.random() + 0.5;
    var rot = Math.random() * 60 - 30;
    var mirror = Math.random() > 0.5 ? 1 : -1;
    var opacity = 0;

    container.appendChild(el);

    function frame() {
      var d = (mouseX - x) * (mouseX - x) + (mouseY - y) * (mouseY - y);

      if (Math.random() < 0.008) {
        sx = Math.random() * 0.3 - 0.15;
        sy = Math.random() * 0.5 - 0.2;
        mirror = sx > 0 ? -1 : 1;
        rot = sx * 170 + Math.abs(sy) * 170 * mirror;
      }
      if (Math.random() < 0.008) rot += Math.random() * 42 - 21;
      if (Math.random() < 0.01) {
        opacity = Math.random() * 0.5 + 0.1;
        scale = Math.random() + 0.5;
      }
      if (Math.random() < 0.004) {
        opacity = 0;
        setTimeout(function () { opacity = 0.1; }, Math.random() * 3000);
      }

      el.style.textShadow = d < 300 ? '0 0 ' + (18 * (d / 300)) + 'px ' + color : 'none';

      if (d < 300) {
        x += sx - sx * (3 / (d / 300));
        y += sy - sy * (3 / (d / 300));
      } else {
        x += sx;
        y += sy;
      }

      if (x < -20) x = 120;
      if (x > 120) x = -20;
      if (y < -20) y = 120;
      if (y > 120) y = -20;

      el.style.opacity = d < 300 ? Math.min(1, opacity + 300 / d) : opacity;
      el.style.transform =
        'translate(' + x + 'vw, ' + y + 'vh) scaleX(' + (scale * mirror) +
        ') scaleY(' + scale + ') rotateZ(' + rot + 'deg)';

      requestAnimationFrame(frame);
    }

    requestAnimationFrame(frame);
  }

  for (var i = 0; i < 28; i++) setTimeout(spawn, i * 420);
})();
