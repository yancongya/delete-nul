import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { createRoot } from 'react-dom/client';
import { flushSync } from 'react-dom';
import { DecryptReveal, supportsHtmlInCanvas } from './components/canvasui/DecryptReveal';
import { AsciiSweep } from './components/canvasui/AsciiSweep';
import { ParticleScroll } from './components/canvasui/ParticleScroll';

const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const hover = matchMedia('(hover: hover) and (pointer: fine)');
const root = document.documentElement;
function subscribe(callback) {
  const observer = new MutationObserver(callback);
  observer.observe(root, { attributes: true, attributeFilter: ['class'] });
  reduced.addEventListener('change', callback);
  hover.addEventListener('change', callback);
  return () => {
    observer.disconnect();
    reduced.removeEventListener('change', callback);
    hover.removeEventListener('change', callback);
  };
}
function useVisualPreferences() {
  const state = useSyncExternalStore(subscribe, () =>
    (root.classList.contains('light') ? 1 : 0) | (reduced.matches ? 2 : 0) | (hover.matches ? 4 : 0));
  return { light: !!(state & 1), reduceMotion: !!(state & 2), finePointer: !!(state & 4) };
}
const nativeCapture = supportsHtmlInCanvas();
const gpuProbe = document.createElement('canvas').getContext('webgl2');
const webgl = !!gpuProbe;
gpuProbe?.getExtension('WEBGL_lose_context')?.loseContext();

const IDLE = 'idle', DECODED = 'decoded', RESTORING = 'restoring';
const DECODE_DELAY = 650;   // hover -> bloom finished
const DECODE_HOLD = 15000;  // readable before the eased return
const RESTORE_TIME = 1100;  // cubic-bezier fade back into the cipher

function FeatureCard({ markup }) {
  const { light, reduceMotion, finePointer } = useVisualPreferences();
  const [phase, setPhase] = useState(IDLE);
  const timers = useRef([]);
  // The shader stays mounted for the whole session: the readable text is a layer
  // on top, so neither the hold nor the return remounts the WebGL context.
  const active = !reduceMotion && finePointer;
  const clearTimers = () => { timers.current.forEach(clearTimeout); timers.current = []; };
  useEffect(() => clearTimers, []);
  function scheduleReturn() {
    timers.current.push(setTimeout(() => {
      setPhase(RESTORING);
      timers.current.push(setTimeout(() => setPhase(IDLE), RESTORE_TIME));
    }, DECODE_HOLD));
  }
  function beginDecode(event) {
    if (!active || event.pointerType === 'touch') return;
    clearTimers();
    // Re-entry while readable or returning reopens the text and restarts the hold.
    if (phase !== IDLE) {
      setPhase(DECODED);
      scheduleReturn();
      return;
    }
    timers.current.push(setTimeout(() => {
      setPhase(DECODED);
      scheduleReturn();
    }, DECODE_DELAY));
  }
  // The original HTML sizes the row and stays available to assistive technology.
  // The visual copy is captured in full by the official shader.
  const body = <div className="card-body" dangerouslySetInnerHTML={{ __html: markup }} />;
  const state = phase === DECODED ? ' decoded' : phase === RESTORING ? ' restoring' : '';
  return <div className={'card-enhanced' + state} data-active={active ? '' : undefined} onPointerEnter={beginDecode}>
    {body}
    {active && <DecryptReveal className="canvasui-decrypt" radius={230} softness={0.92} smoothing={0.11} cell={8} edgeWidth={0.28}
      style={{ overflow: 'hidden' }} colored={0} color={light ? '#363636' : '#dedede'} aberration={10}
      background={light ? '#ffffff' : '#0f0f11'}>
      <div aria-hidden="true" style={{ height: '100%', background: 'var(--panel)' }}>{body}</div>
    </DecryptReveal>}
  </div>;
}

if (nativeCapture && webgl) {
  for (const target of document.querySelectorAll('#features .card')) {
    createRoot(target).render(<FeatureCard markup={target.querySelector('.card-body').innerHTML} />);
  }
}

const modeSection = document.querySelector('#modes');
const modes = Array.from(modeSection.querySelectorAll('.mode-panel'), (panel) => ({
  title: panel.querySelector('h3').textContent,
  description: panel.querySelector('p').innerHTML,
  sample: panel.querySelector('pre').textContent,
}));
function ModePanel({ mode }) {
  const { title, description, sample } = modes[mode];
  return <div className="mode-panel"><h3>{title}</h3>
    <p dangerouslySetInnerHTML={{ __html: description }} /><pre>{sample}</pre></div>;
}
function ModePicker() {
  const { reduceMotion, light } = useVisualPreferences();
  const [selected, setSelected] = useState(0);
  const [slot, setSlot] = useState(0);
  const [panels, setPanels] = useState([0, 0]);
  const [busy, setBusy] = useState(false);
  const animated = webgl && !reduceMotion;
  useEffect(() => { if (!animated) setBusy(false); }, [animated]);
  function select(mode) {
    if (mode === selected || (busy && animated)) return;
    const next = 1 - slot;
    if (animated) {
      flushSync(() => {
        setPanels((previous) => previous.map((value, i) => i === next ? mode : value));
        setBusy(true);
      });
      setSlot(next);
    } else {
      setPanels([mode, mode]);
      setBusy(false);
    }
    setSelected(mode);
  }
  return <>
    <div className="mode-picker" aria-label="使用模式" role="group" data-busy={animated && busy ? '' : undefined}>
      {modes.map(({ title }, index) => <button type="button" key={title} aria-controls="mode-preview"
        aria-disabled={animated && busy && index !== selected ? true : undefined}
        aria-pressed={index === selected} onClick={() => select(index)}>
        <span className="mode-index" aria-hidden="true">0{index + 1}</span>
        <span className="mode-label">{title}</span>
        <span className="mode-caret" aria-hidden="true">›</span>
      </button>)}
    </div>
    <div className="mode-screen" id="mode-preview">
      {animated ? <AsciiSweep className="canvasui-sweep" style={{ height: 200 }} index={slot} duration={0.7}
        color={light ? '#363636' : '#dedede'} aberration={0} onSweepEnd={() => setBusy(false)}
        alternate={<ModePanel mode={panels[1]} />}>
        <ModePanel mode={panels[0]} />
      </AsciiSweep> : <ModePanel mode={selected} />}
    </div>
  </>;
}
const picker = modeSection.querySelector('.mode-picker');
const modeMount = document.createElement('div');
picker.replaceWith(modeMount);
flushSync(() => createRoot(modeMount).render(<ModePicker />));
modeSection.querySelector('.mode-screen:not(#mode-preview)')?.remove();

// WHY: the section is a bounded scroll viewport so the sand has rows to
// dissolve and reassemble. Remount on theme change so the captured texture and
// backdrop color follow the monochrome inversion.
function WhyScroll({ markup }) {
  const { light } = useVisualPreferences();
  return <ParticleScroll key={light} className="why-scroll" pageScroll point={0.72} band={300} density={2.6}
    spread={90} gravity={0.3} drift={0.45} settle={0.9} smoothing={0.4}>
    <div className="why-scroll-inner" dangerouslySetInnerHTML={{ __html: markup }} />
  </ParticleScroll>;
}
const whyContainer = document.querySelector('[data-why-scroll]');
if (whyContainer) {
  const whyMarkup = whyContainer.querySelector('.why-scroll-inner').innerHTML;
  createRoot(whyContainer).render(<WhyScroll markup={whyMarkup} />);
}

