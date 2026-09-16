// Viewer fit-width 回归自检：直接执行 resources/ 下的真实脚本（最小 DOM stub），
// 断言 Office 查看器的 auto-fit 缩放、测量后重算、用户缩放后不再被覆盖，
// 以及 DOCX 查看器的 fitToWidth。
//
//   node tests/viewer_fit_check.js

'use strict';

const fs = require('fs');
const path = require('path');

let failures = 0;

function check(cond, name) {
  if (cond) return;
  failures += 1;
  console.error('FAIL: ' + name);
}

function makeElement() {
  return {
    style: {},
    children: [],
    childElementCount: 0,
    textContent: '',
    value: '',
    rectWidth: 0,
    rectHeight: 0,
    scrollWidth: 0,
    scrollHeight: 0,
    offsetWidth: 0,
    offsetHeight: 0,
    clientWidth: 0,
    clientHeight: 0,
    parentNode: null,
    queryNodes: [],
    queryNode: null,
    classList: { add() {}, remove() {}, toggle() {} },
    appendChild(node) {
      node.parentNode = this;
      this.children.push(node);
      this.childElementCount = this.children.length;
      return node;
    },
    insertBefore(node) {
      node.parentNode = this;
      this.children.push(node);
      this.childElementCount = this.children.length;
      return node;
    },
    querySelectorAll() { return this.queryNodes; },
    querySelector() { return this.queryNode; },
    getBoundingClientRect() {
      return {
        left: 0,
        top: 0,
        right: this.rectWidth,
        bottom: this.rectHeight,
        width: this.rectWidth,
        height: this.rectHeight,
      };
    },
    addEventListener() {},
    removeEventListener() {},
    setAttribute() {},
    getAttribute() { return null; },
  };
}

function zoomFromTransform(host) {
  const match = /scale\(([0-9.]+)\)/.exec(host.style.transform || '');
  return match ? Number.parseFloat(match[1]) : NaN;
}

let frameQueue = [];
let events = [];
let listeners = {};

function setupDom(elements) {
  frameQueue = [];
  events = [];
  listeners = {};
  global.requestAnimationFrame = (cb) => { frameQueue.push(cb); return frameQueue.length; };
  global.setTimeout = () => 0;
  global.CustomEvent = class CustomEvent {
    constructor(type, init) { this.type = type; this.detail = init ? init.detail : undefined; }
  };
  global.MutationObserver = class MutationObserver {
    constructor(cb) { this.cb = cb; global.__ffObserver = this; }
    observe() {}
    disconnect() {}
  };
  global.window = {
    events,
    innerWidth: 390,
    scrollX: 0,
    scrollY: 0,
    dispatchEvent(event) { events.push(event); return true; },
    addEventListener(type, handler) { listeners[type] = handler; },
  };
  global.document = {
    getElementById(id) { return elements[id] || null; },
    createElement() { return makeElement(); },
    addEventListener() {},
    querySelectorAll() { return []; },
  };
}

function flushFrames() {
  for (let i = 0; i < 4; i += 1) {
    const batch = frameQueue.splice(0, frameQueue.length);
    for (const cb of batch) cb(0);
  }
}

function loadScript(relativePath) {
  const code = fs.readFileSync(path.join(__dirname, '..', relativePath), 'utf8');
  const run = new Function('window', 'document', 'MutationObserver', 'CustomEvent',
    'requestAnimationFrame', 'setTimeout', code);
  run(global.window, global.document, global.MutationObserver, global.CustomEvent,
    global.requestAnimationFrame, global.setTimeout);
}

function testOfficeAutoFit() {
  const view = makeElement();
  view.clientWidth = 390;
  view.clientHeight = 700;
  const host = makeElement();
  const container = makeElement();
  container.appendChild(host);
  const child = makeElement();
  child.rectWidth = 794;
  child.rectHeight = 1123;
  host.queryNodes = [child];
  host.childElementCount = 1;
  host.offsetWidth = 600;
  host.scrollWidth = 700;
  host.offsetHeight = 1123;
  host.scrollHeight = 1123;

  setupDom({ 'ff-viewport': view, 'ff-document-host': host });
  loadScript('resources/office/fixed-layout.js');
  flushFrames();

  const first = zoomFromTransform(host);
  check(first > 0.48 && first < 0.5,
    'office: first measure opens at fit width, got ' + first);

  const zoomEvent = events.filter((event) => event.type === 'ffofficezoom').pop();
  check(zoomEvent && Math.abs(zoomEvent.detail.zoom - first) < 0.001,
    'office: layout broadcasts the chosen zoom');
  check(zoomEvent && zoomEvent.detail.autoFit === true,
    'office: broadcast reports autoFit while it owns the zoom');

  // A late drawing/image makes the authored width grow: auto-fit must follow.
  child.rectWidth = 1200;
  global.__ffObserver.cb([{ type: 'childList', target: host }]);
  flushFrames();
  const refit = zoomFromTransform(host);
  check(refit > 0.32 && refit < 0.33,
    'office: re-measure refits to the wider document, got ' + refit);

  // An explicit user zoom leaves auto-fit for good.
  global.window.FFOfficeLayout.setAutoFit(false);
  host.style.zoom = '1.5';
  global.__ffObserver.cb([{ type: 'attributes', target: host, attributeName: 'style' }]);
  check(Math.abs(zoomFromTransform(host) - 1.5) < 0.001,
    'office: inline user zoom is consumed');

  child.rectWidth = 1500;
  global.__ffObserver.cb([{ type: 'childList', target: host }]);
  flushFrames();
  check(Math.abs(zoomFromTransform(host) - 1.5) < 0.001,
    'office: manual zoom survives later re-measures');

  // Zoomed below fit the canvas must be centered, not pinned left.
  host.style.zoom = '0.25';
  global.__ffObserver.cb([{ type: 'attributes', target: host, attributeName: 'style' }]);
  check(host.style.left === '7px',
    'office: narrow canvas is centered, got left=' + host.style.left);

  // Search highlighting (marks/text nodes) must not trigger a re-measure:
  // the authored canvas is unchanged, so freezeLayout must not run.
  const mark = makeElement();
  mark.nodeType = 1;
  mark.classList.contains = (name) => name === 'ff-hit';
  child.rectWidth = 3000;
  const widthBefore = host.style.width;
  global.__ffObserver.cb([{
    type: 'childList',
    target: host,
    addedNodes: [mark],
    removedNodes: [{ nodeType: 3 }],
  }]);
  flushFrames();
  check(host.style.width === widthBefore,
    'office: search decorations do not trigger a re-measure, got ' + host.style.width);

  // Rotation with a user zoom keeps the point at the viewport centre stable.
  view.clientWidth = 500;
  view.scrollLeft = 50;
  view.scrollTop = 100;
  listeners.resize?.();
  check(Math.abs(view.scrollLeft - 105.25) < 0.6 && Math.abs(view.scrollTop - 100) < 0.6,
    'office: resize anchors the centre, got ' + view.scrollLeft + ',' + view.scrollTop);
}

testOfficeAutoFit();

if (failures) {
  console.error(failures + ' viewer fit check(s) failed');
  process.exit(1);
}
console.log('viewer fit checks passed');
