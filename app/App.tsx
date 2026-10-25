import { StatusBar } from 'expo-status-bar';
import { type ReactNode, useCallback, useEffect, useState } from 'react';
import { AppState, Image, type ImageSourcePropType, Pressable, ScrollView, Share, StyleSheet, Text, View } from 'react-native';

import Gow3Core from './modules/gow3-core/src/Gow3CoreModule';

const APP_NAME = 'Olympus';
const GAME_TITLE = 'God of War III Remastered';
const POOL_MB = 256;
const HELMET = require('./assets/icon.png');

type Pairing = Awaited<ReturnType<typeof Gow3Core.pairingState>>;
type BuiltIn = Awaited<ReturnType<typeof Gow3Core.builtInJitStatus>>;
type Tab = 'home' | 'setup' | 'system';

// controllers() is new in the native build after 4ed13b6; older installed IPAs lack it.
const listControllers = () => (typeof Gow3Core.controllers === 'function' ? Gow3Core.controllers() : []);
// The on-screen controls switch is new in 0.1.44, the FPS cap in 0.1.45; older installed IPAs lack them.
const hasTouchControls = typeof Gow3Core.touchControlsEnabled === 'function';
const hasFpsLimit = typeof Gow3Core.fpsLimit === 'function';
const FPS_LIMITS = [30, 60, 0];
// The Windows engine is new in 0.2.0, its game list in 0.2.1; older installed IPAs lack them.
const hasWindowsEngine = typeof Gow3Core.windowsStatus === 'function';
const hasWindows = typeof Gow3Core.windowsGames === 'function';
const HELPER_EXE = /crash|unins|setup|install|redist|dxweb|quicksfv|report/i;
/** 0.2.0 has no game list, only its .exe list, whose paths all start C:\drive_c\ (its path bug; on the
 *  phone the game folders were moved into drive_c\drive_c so those paths work). One game per top-level
 *  folder, started by its first program that is not a helper. */
function legacyWindowsGames(): WindowsGame[] {
  if (!hasWindowsEngine) return [];
  const groups = new Map<string, string[]>();
  for (const exe of Gow3Core.windowsStatus().programs) {
    const parts = exe.replace(/^C:\\/, '').replace(/^drive_c\\/, '').split('\\');
    if (parts.length < 2 || parts[0] === 'drive_c') continue;
    groups.set(parts[0], [...(groups.get(parts[0]) ?? []), exe]);
  }
  return [...groups].map(([name, exes]) => {
    const exe = exes.find((e) => !HELPER_EXE.test(e.split('\\').pop() ?? '')) ?? exes[0];
    const program = exe.split('\\').slice(3).join('/');
    return { name, programs: [program], program, exe, cover: '' };
  });
}
const listWindowsGames = (): WindowsGame[] => (hasWindows ? Gow3Core.windowsGames() : legacyWindowsGames());
const hasFpsMeter = typeof Gow3Core.windowsFpsMeter === 'function';
const readWindowsStatus = () => (typeof Gow3Core.windowsStatus === 'function' ? Gow3Core.windowsStatus() : null);
type WindowsGame = ReturnType<typeof Gow3Core.windowsGames>[number];
type Game = { key: string; kind: 'gow3' | 'windows'; title: string; platform: string; cover: ImageSourcePropType | null; win?: WindowsGame };

const color = {
  bg: '#07070a',
  panel: 'rgba(22, 22, 28, 0.92)',
  raised: '#1e1e26',
  border: 'rgba(255, 255, 255, 0.08)',
  text: '#f4f2ee',
  muted: '#a29fab',
  faint: '#615e69',
  ember: '#d4412f',
  gold: '#e6b44f',
  ok: '#4cc38a',
  warn: '#f0a04b',
};

function pretty(json: string): string {
  try {
    return JSON.stringify(JSON.parse(json), null, 2);
  } catch {
    return json;
  }
}

function jitReady(report: string): boolean {
  try {
    return JSON.parse(report).jit_pool === true;
  } catch {
    return false;
  }
}

function useClock(): string {
  const format = () => new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const [time, setTime] = useState(format);
  useEffect(() => {
    const timer = setInterval(() => setTime(format()), 15000);
    return () => clearInterval(timer);
  }, []);
  return time;
}

function Pill({ label, good }: { label: string; good: boolean }) {
  return (
    <View style={[styles.pill, { borderColor: good ? 'rgba(76,195,138,0.5)' : 'rgba(240,160,75,0.5)' }]}>
      <View style={[styles.dot, { backgroundColor: good ? color.ok : color.warn }]} />
      <Text style={styles.pillText}>{label}</Text>
    </View>
  );
}

function Button({ title, onPress, disabled, quiet }: { title: string; onPress: () => void; disabled?: boolean; quiet?: boolean }) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      style={({ pressed }) => [styles.button, quiet && styles.buttonQuiet, pressed && styles.pressed, disabled && styles.disabled]}
    >
      <Text style={styles.buttonText}>{title}</Text>
    </Pressable>
  );
}

function QuickTile({ title, value, detail, onPress, active }: { title: string; value: string; detail: string; onPress?: () => void; active?: boolean }) {
  return (
    <Pressable onPress={onPress} disabled={!onPress} style={({ pressed }) => [styles.quick, active && styles.quickActive, pressed && styles.pressed]}>
      <Text style={styles.quickTitle}>{title}</Text>
      <Text style={styles.quickValue} numberOfLines={1}>
        {value}
      </Text>
      <Text style={styles.quickDetail} numberOfLines={2}>
        {detail}
      </Text>
    </Pressable>
  );
}

function Panel({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <View style={styles.panel}>
      <Text style={styles.panelTitle}>{title}</Text>
      {subtitle ? <Text style={styles.panelSubtitle}>{subtitle}</Text> : null}
      <View style={styles.panelBody}>{children}</View>
    </View>
  );
}

function FileLine({ name, present, required }: { name: string; present: boolean; required?: boolean }) {
  return (
    <View style={styles.fileLine}>
      <Text style={[styles.fileMark, { color: present ? color.ok : required ? color.ember : color.faint }]}>{present ? '✓' : '✕'}</Text>
      <Text style={styles.fileName}>{name}</Text>
      {!present ? <Text style={styles.fileHint}>{required ? 'required' : 'optional'}</Text> : null}
    </View>
  );
}

function Mono({ title, text }: { title: string; text: string }) {
  return (
    <View style={styles.mono}>
      <Text style={styles.monoTitle}>{title}</Text>
      <Text style={styles.monoText} selectable>
        {text}
      </Text>
    </View>
  );
}

/** A game's cover, or its initials on a dark tile when it has none. */
function Cover({ source, title, size, onError }: { source: ImageSourcePropType | null; title: string; size: number; onError?: () => void }) {
  if (source) return <Image source={source} style={[styles.cover, { width: size, height: size, borderRadius: size / 7 }]} onError={onError} />;
  const initials = title
    .split(/[\s:_-]+/)
    .filter((w) => /^[A-Za-z0-9]/.test(w))
    .slice(0, 2)
    .map((w) => w[0].toUpperCase())
    .join('');
  return (
    <View style={[styles.cover, styles.monogram, { width: size, height: size, borderRadius: size / 7 }]}>
      <Text style={[styles.monogramText, { fontSize: size / 2.8 }]}>{initials || '?'}</Text>
    </View>
  );
}

const WINDOWS_STATES: Record<number, string> = { [-1]: 'Failed', 0: 'Not started', 1: 'Starting', 2: 'Running', 3: 'Exited' };

/** Phase 2 test screen for the Windows engine (docs/WINE_ENGINE.md): start a program copied into
 *  Documents/wine/drive_c. One engine per launch, so it is locked once GoW3 used JIT or started. */
function WindowsTest({ locked }: { locked: string | null }) {
  const [status, setStatus] = useState(() => Gow3Core.windowsStatus());
  const [log, setLog] = useState('');
  const [message, setMessage] = useState('');
  const [starting, setStarting] = useState(false);
  const live = status.state === 1 || status.state === 2;

  useEffect(() => {
    if (!live) return;
    const timer = setInterval(() => {
      setStatus(Gow3Core.windowsStatus());
      setLog(Gow3Core.readWindowsLog());
    }, 1000);
    return () => clearInterval(timer);
  }, [live]);

  const start = async (exe: string) => {
    setStarting(true);
    setMessage(`Starting ${exe}…`);
    try {
      const jit = await Gow3Core.builtInJitStatus();
      const builtIn = Gow3Core.isDebuggerAttached() || (jit.available && jit.paired);
      if (!builtIn && !(await Gow3Core.isStikDebugInstalled())) {
        setMessage('JIT: pair this iPhone (Setup) or install StikDebug.');
        return;
      }
      const code = await Gow3Core.startWindowsGame(exe, '', builtIn);
      setMessage(code === 0 ? 'Started. To leave, close the app from the app switcher.' : `Did not start (${code}).`);
    } catch (e) {
      setMessage(String(e));
    } finally {
      setStatus(Gow3Core.windowsStatus());
      setLog(Gow3Core.readWindowsLog());
      setStarting(false);
    }
  };

  const ready = status.framework && status.resources;
  return (
    <>
      <Panel
        title="Windows engine (test)"
        subtitle={ready ? `${WINDOWS_STATES[status.state] ?? status.state}${status.failure ? `: ${status.failure}` : ''}` : 'Not in this build'}
      >
        <Text style={styles.body}>
          {`Copy a game's folder into Files › ${APP_NAME} › wine › drive_c, then tap its program.`}
        </Text>
        <Text style={styles.hint}>
          {status.earlyClaim
            ? `Early reservation made at this launch: ${status.earlyClaim}.`
            : 'If a start fails on the JIT pool: Prepare launch, close the app from the app switcher, reopen it, then start again.'}
        </Text>
        {locked ? <Text style={styles.hint}>{locked}</Text> : null}
        {status.programs.length === 0 ? <Text style={styles.hint}>No .exe found in {status.folder}.</Text> : null}
        {status.programs.map((exe) => (
          <View key={exe} style={styles.row}>
            <Button title={exe} onPress={() => start(exe)} disabled={!ready || starting || live || !!locked} />
          </View>
        ))}
        <View style={styles.row}>
          <Button title="Look again" onPress={() => setStatus(Gow3Core.windowsStatus())} quiet />
          <Button
            title="Prepare launch"
            onPress={() => {
              try {
                Gow3Core.prepareWindowsLaunch();
                setMessage('Now close Olympus from the app switcher and open it again.');
              } catch (e) {
                setMessage(String(e));
              }
            }}
            disabled={live}
            quiet
          />
          <Button title="Show log" onPress={() => setLog(Gow3Core.readWindowsLog())} quiet />
        </View>
        {message ? <Text style={styles.hint}>{message}</Text> : null}
      </Panel>
      {log ? <Mono title="Windows log (madeira-log.txt)" text={log} /> : null}
    </>
  );
}

function TabButton({ label, glyph, active, onPress }: { label: string; glyph: string; active: boolean; onPress: () => void }) {
  return (
    <Pressable onPress={onPress} style={styles.tab}>
      <Text style={[styles.tabGlyph, active && styles.tabActive]}>{glyph}</Text>
      <Text style={[styles.tabLabel, active && styles.tabActive]}>{label}</Text>
      {active ? <View style={styles.tabMark} /> : null}
    </Pressable>
  );
}

export default function App() {
  const clock = useClock();
  const [tab, setTab] = useState<Tab>('home');
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState('');
  const [report, setReport] = useState(() => Gow3Core.deviceReport());
  const [result, setResult] = useState('');
  const [log, setLog] = useState(() => Gow3Core.readLog());
  const [pads, setPads] = useState(listControllers);
  const [builtIn, setBuiltIn] = useState<BuiltIn | null>(null);
  const [pairing, setPairing] = useState<Pairing | null>(null);
  const [files, setFiles] = useState(() => Gow3Core.gameFiles());
  const [gameLog, setGameLog] = useState(() => Gow3Core.readGameLog());
  const [gpuReport, setGpuReport] = useState('');
  const [fpsLimit, setFpsLimit] = useState(() => (hasFpsLimit ? Gow3Core.fpsLimit() : 30));
  const [touchControls, setTouchControls] = useState(() => (hasTouchControls ? Gow3Core.touchControlsEnabled() : false));
  const [coverFailed, setCoverFailed] = useState(false);
  const [winGames, setWinGames] = useState(listWindowsGames);
  const [winStatus, setWinStatus] = useState(readWindowsStatus);
  const [selected, setSelected] = useState('gow3');
  // The Windows game started in this launch (its tile shows Resume while it runs).
  const [runningKey, setRunningKey] = useState('');
  const [fpsMeter, setFpsMeter] = useState(() => (hasFpsMeter ? Gow3Core.windowsFpsMeter() : false));

  const refresh = useCallback(() => {
    setReport(Gow3Core.deviceReport());
    setLog(Gow3Core.readLog());
    setPads(listControllers());
    Gow3Core.builtInJitStatus().then(setBuiltIn, () => setBuiltIn(null));
    Gow3Core.pairingState().then(setPairing, () => setPairing(null));
    setFiles(Gow3Core.gameFiles());
    setGameLog(Gow3Core.readGameLog());
    setWinGames(listWindowsGames());
    setWinStatus(readWindowsStatus());
  }, []);

  useEffect(() => {
    refresh();
    // Pairing happens in Settings: refresh when the app comes back.
    const sub = AppState.addEventListener('change', (state) => state === 'active' && refresh());
    return () => sub.remove();
  }, [refresh]);

  // While the game runs, follow its log.
  useEffect(() => {
    if (!files.started) return;
    const timer = setInterval(() => setGameLog(Gow3Core.readGameLog()), 1000);
    return () => clearInterval(timer);
  }, [files.started]);

  // While a Windows game starts or runs, follow its state (Starting, Resume, exited).
  const winLive = winStatus?.state === 1 || winStatus?.state === 2;
  useEffect(() => {
    if (!winLive) return;
    const timer = setInterval(() => setWinStatus(readWindowsStatus()), 2000);
    return () => clearInterval(timer);
  }, [winLive]);

  const pairingActive = pairing?.phase === 'waiting' || pairing?.phase === 'pin';
  useEffect(() => {
    if (!pairingActive) return;
    const timer = setInterval(() => {
      Gow3Core.pairingState().then((p) => {
        setPairing(p);
        if (p.phase === 'paired') refresh();
      });
    }, 1000);
    return () => clearInterval(timer);
  }, [pairingActive, refresh]);

  const run = useCallback(
    async (what: () => Promise<string>) => {
      setBusy(true);
      try {
        setStatus(await what());
      } catch (e) {
        setStatus(String(e));
      } finally {
        refresh();
        setBusy(false);
      }
    },
    [refresh]
  );

  const enableJit = useCallback(
    () =>
      run(async () => {
        const ready = (code: number) => (code === 0 ? 'JIT is ready.' : `JIT setup failed (${code}).`);
        const status = await Gow3Core.builtInJitStatus();
        if (Gow3Core.isDebuggerAttached() || (status.available && status.paired)) {
          setStatus('Enabling JIT…');
          return ready(await Gow3Core.enableJitBuiltIn(POOL_MB));
        }
        if (await Gow3Core.isStikDebugInstalled()) {
          setStatus('Waiting for StikDebug…');
          return ready(await Gow3Core.enableJit(POOL_MB));
        }
        setTab('setup');
        return status.available ? 'Pair this iPhone first (Setup), and connect LocalDevVPN.' : `JIT unavailable: ${status.reason}`;
      }),
    [run]
  );

  const runSelfTest = useCallback(async () => {
    setBusy(true);
    setStatus('Running self-test…');
    try {
      setResult(pretty(await Gow3Core.runSelfTest()));
      setStatus('Self-test finished.');
    } catch (e) {
      setStatus(`Self-test: ${String(e)}`);
    } finally {
      refresh();
      setBusy(false);
    }
  }, [refresh]);

  const jit = jitReady(report);
  const filesReady = files.boot && files.eboot;
  const missing = [!files.boot, !files.eboot].filter(Boolean).length;
  const pad = pads[0];
  // The dump's own cover (0.1.46+ reports its path); the helmet before that or without one.
  const cover: ImageSourcePropType = files.cover && !coverFailed ? { uri: files.cover } : HELMET;

  const games: Game[] = [
    { key: 'gow3', kind: 'gow3', title: GAME_TITLE, platform: 'PS4 · REMASTERED', cover },
    ...winGames.map((g): Game => ({
      key: `win:${g.name}`,
      kind: 'windows',
      title: g.name,
      platform: 'WINDOWS',
      cover: g.cover ? { uri: g.cover } : null,
      win: g,
    })),
  ];
  const current = games.find((g) => g.key === selected) ?? games[0];
  // One game engine per launch (docs/WINE_ENGINE.md): GoW3's and the Windows engine's JIT pools,
  // signal handlers and address-space reservations cannot share a process.
  const winState = winStatus?.state ?? 0;
  const windowsUsed = winState !== 0;
  const gow3Used = files.started || jit;
  const reopen = (why: string) => ({
    title: 'Reopen to play',
    onPress: () => {},
    disabled: true,
    hint: `${why} One game engine per launch: close ${APP_NAME} from the app switcher and open it again.`,
  });

  const startWindows = (g: WindowsGame) =>
    run(async () => {
      const s = await Gow3Core.builtInJitStatus();
      const builtInJit = Gow3Core.isDebuggerAttached() || (s.available && s.paired);
      if (!builtInJit && !(await Gow3Core.isStikDebugInstalled())) {
        setTab('setup');
        return 'JIT: pair this iPhone (Setup) and connect LocalDevVPN, or install StikDebug.';
      }
      setStatus(`Starting ${g.name}…`);
      setRunningKey(`win:${g.name}`);
      const code = await Gow3Core.startWindowsGame(g.exe, '', builtInJit);
      return code === 0 ? `${g.name} is starting. A two-finger double tap in game returns here.` : `${g.name} did not start (${code}).`;
    });

  let play: { title: string; onPress: () => void; disabled: boolean; hint: string };
  if (current.kind === 'windows' && current.win) {
    const g = current.win;
    if (runningKey === current.key && winState === 2) {
      play = hasWindows
        ? { title: 'Resume', onPress: () => Gow3Core.resumeWindowsGame(), disabled: false, hint: 'Running. A two-finger double tap in game returns here.' }
        : { title: 'Running', onPress: () => {}, disabled: true, hint: 'Running. This build has no way back from the game; the next one does.' };
    } else if (runningKey === current.key && winState === 1) {
      play = { title: 'Starting…', onPress: () => {}, disabled: true, hint: 'Setting up JIT and Windows; the first start takes longer.' };
    } else if (gow3Used) {
      play = reopen(`${GAME_TITLE} used JIT in this launch.`);
    } else if (windowsUsed) {
      play = reopen(winState === -1 ? `The last start failed: ${winStatus?.failure ?? ''}.` : 'A Windows game ran in this launch.');
    } else {
      play = { title: 'Play', onPress: () => startWindows(g), disabled: busy, hint: 'JIT is enabled when you press Play.' };
    }
  } else if (files.started) {
    play = { title: 'Running', onPress: () => {}, disabled: true, hint: 'In game. A two-finger double tap there brings you back here.' };
  } else if (windowsUsed) {
    play = reopen('A Windows game ran in this launch.');
  } else if (!filesReady) {
    play = { title: 'Add game files', onPress: () => setTab('setup'), disabled: false, hint: `Copy your own dump in with the Files app (${APP_NAME} › gow3).` };
  } else if (!jit) {
    play = { title: 'Enable JIT', onPress: enableJit, disabled: busy, hint: 'Needed once each time the app opens.' };
  } else {
    play = { title: 'Play', onPress: () => run(() => Gow3Core.startGame()), disabled: busy, hint: 'Ready.' };
  }

  // A Windows game's program: the next one in its folder (when the launcher picked the wrong .exe).
  const nextProgram = (g: WindowsGame) => {
    const next = g.programs[(g.programs.indexOf(g.program) + 1) % g.programs.length];
    try {
      Gow3Core.setWindowsGameProgram(g.name, next);
    } catch (e) {
      setStatus(String(e));
    }
    setWinGames(listWindowsGames());
  };

  const jitText = builtIn
    ? builtIn.available
      ? builtIn.paired
        ? 'Paired. Connect LocalDevVPN, run Check setup once, then Enable JIT.'
        : builtIn.pairingSupported
          ? 'Not paired. Tap Pair, then open Settings › Privacy & Security › Developer Mode and tap “Pair with gow3-ios”.'
          : 'Not paired. In-app pairing needs iOS 27; StikDebug works too.'
      : builtIn.reason
    : 'Checking…';

  const cycleFps = () => {
    const next = FPS_LIMITS[(FPS_LIMITS.indexOf(fpsLimit) + 1) % FPS_LIMITS.length];
    Gow3Core.setFpsLimit(next);
    setFpsLimit(next);
  };

  return (
    <View style={styles.root}>
      {/* Backdrop: the cover, blurred and faded into the background. */}
      <Image source={current.cover ?? HELMET} style={styles.backdrop} blurRadius={40} onError={() => current.kind === 'gow3' && setCoverFailed(true)} />
      <View style={[styles.backdropFade, { top: 180, opacity: 0.45 }]} />
      <View style={[styles.backdropFade, { top: 260, opacity: 0.75 }]} />
      <View style={[styles.backdropFade, { top: 340, opacity: 1 }]} />

      <View style={styles.topBar}>
        <View style={styles.brand}>
          <Image source={HELMET} style={styles.brandIcon} />
          <Text style={styles.brandText}>{APP_NAME}</Text>
        </View>
        <View style={styles.topRight}>
          <View style={[styles.dot, { backgroundColor: jit ? color.ok : color.warn }]} />
          {pad ? <Text style={styles.topText}>🎮</Text> : null}
          <Text style={styles.clock}>{clock}</Text>
        </View>
      </View>

      <ScrollView contentContainerStyle={styles.content}>
        {tab === 'home' ? (
          <>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.shelf}>
              {games.map((g) => (
                <Pressable key={g.key} onPress={() => setSelected(g.key)} style={({ pressed }) => [styles.shelfTile, pressed && styles.pressed]}>
                  <View style={[styles.shelfFrame, g.key === current.key && styles.shelfFrameActive]}>
                    <Cover source={g.cover} title={g.title} size={76} />
                  </View>
                  <Text style={[styles.shelfTitle, g.key === current.key && styles.shelfTitleActive]} numberOfLines={1}>
                    {g.title}
                  </Text>
                </Pressable>
              ))}
              {hasWindowsEngine ? (
                <Pressable
                  onPress={() => {
                    setStatus(`Add a Windows game: copy its installed folder into Files › ${APP_NAME} › wine › drive_c, then reopen the app. A cover.jpg in the folder becomes its cover.`);
                    setWinGames(listWindowsGames());
                  }}
                  style={({ pressed }) => [styles.shelfTile, pressed && styles.pressed]}
                >
                  <View style={styles.shelfFrame}>
                    <View style={[styles.cover, styles.monogram, styles.addTile]}>
                      <Text style={styles.addGlyph}>+</Text>
                    </View>
                  </View>
                  <Text style={styles.shelfTitle}>Add game</Text>
                </Pressable>
              ) : null}
            </ScrollView>

            <View style={styles.hero}>
              <Cover source={current.cover} title={current.title} size={132} onError={() => current.kind === 'gow3' && setCoverFailed(true)} />
              <View style={styles.heroInfo}>
                <Text style={styles.platform}>{current.platform}</Text>
                <Text style={styles.gameTitle} numberOfLines={3}>
                  {current.title}
                </Text>
                <View style={styles.pills}>
                  {current.kind === 'gow3' ? (
                    <>
                      <Pill label={jit ? 'JIT ready' : 'JIT needed'} good={jit} />
                      <Pill label={filesReady ? 'Installed' : `${missing} missing`} good={filesReady} />
                    </>
                  ) : (
                    <>
                      <Pill label={runningKey === current.key && winState === 2 ? 'Running' : 'Installed'} good />
                      <Pill label="Wine · FEX · DXMT" good />
                    </>
                  )}
                </View>
              </View>
            </View>
            {current.kind === 'windows' && current.win ? (
              <Pressable onPress={() => hasWindows && current.win && current.win.programs.length > 1 && nextProgram(current.win)} style={styles.programRow}>
                <Text style={styles.programLabel}>STARTS</Text>
                <Text style={styles.programName} numberOfLines={1}>
                  {current.win.program}
                </Text>
                {current.win.programs.length > 1 ? <Text style={styles.programChange}>Change</Text> : null}
              </Pressable>
            ) : null}

            <Pressable
              onPress={play.onPress}
              disabled={play.disabled}
              style={({ pressed }) => [styles.play, pressed && styles.pressed, play.disabled && styles.disabled]}
            >
              <Text style={styles.playGlyph}>▶</Text>
              <Text style={styles.playText}>{play.title}</Text>
            </Pressable>
            <Text style={styles.hint}>{status || play.hint}</Text>

            <Text style={styles.section}>Quick settings</Text>
            <View style={styles.quickRow}>
              {hasFpsLimit && current.kind === 'gow3' ? (
                <QuickTile
                  title="FRAME CAP"
                  value={fpsLimit ? `${fpsLimit} FPS` : 'Off'}
                  detail={files.started ? 'Next start' : fpsLimit === 30 ? 'Steady, cooler' : 'Tap to change'}
                  onPress={cycleFps}
                  active={fpsLimit === 30}
                />
              ) : null}
              {hasTouchControls && current.kind === 'gow3' ? (
                <QuickTile
                  title="TOUCH"
                  value={touchControls ? 'On' : 'Off'}
                  detail="Hold Hide in game to edit"
                  onPress={() => {
                    Gow3Core.setTouchControlsEnabled(!touchControls);
                    setTouchControls(!touchControls);
                  }}
                  active={touchControls}
                />
              ) : null}
              {hasFpsMeter && current.kind === 'windows' ? (
                <QuickTile
                  title="FPS METER"
                  value={fpsMeter ? 'On' : 'Off'}
                  detail="FPS, GPU, memory in game"
                  onPress={() => {
                    Gow3Core.setWindowsFpsMeter(!fpsMeter);
                    setFpsMeter(!fpsMeter);
                  }}
                  active={fpsMeter}
                />
              ) : null}
              <QuickTile
                title="CONTROLLER"
                value={pad ? pad.name : 'None'}
                detail={pad ? (pad.battery >= 0 ? `${Math.round(pad.battery * 100)}% battery` : pad.kind) : 'Pair in Bluetooth'}
                onPress={refresh}
                active={!!pad}
              />
            </View>

            <Text style={styles.section}>Tips</Text>
            {current.kind === 'gow3' ? (
              <View style={styles.panel}>
                <Text style={styles.body}>• Menu (touch) or R3 + L2 opens the settings and cheats menu in game.</Text>
                <Text style={styles.body}>• Two-finger double tap on an empty spot returns here; the game keeps running.</Text>
                <Text style={styles.body}>• A 30 FPS cap keeps heavy fights steady and the phone cooler.</Text>
              </View>
            ) : (
              <View style={styles.panel}>
                <Text style={styles.body}>• Play with a controller: while one is connected, touches are not sent to the game as a mouse.</Text>
                <Text style={styles.body}>• Two-finger double tap in game returns here; Resume goes back. The game keeps running.</Text>
                <Text style={styles.body}>{`• Wrong program? Tap STARTS to pick another .exe from the game's folder.`}</Text>
                <Text style={styles.body}>{`• Settings for all Windows games: Files › ${APP_NAME} › madeira.cfg (Madeira's format). Log: madeira-log.txt.`}</Text>
              </View>
            )}
          </>
        ) : null}

        {tab === 'setup' ? (
          <>
            <Panel title="JIT" subtitle={jit ? 'Ready for this session' : builtIn?.paired ? 'Paired' : 'Pairing needed'}>
              <Text style={styles.body}>{jitText}</Text>
              {pairing && pairing.phase !== 'idle' ? (
                <View style={styles.pairing}>
                  {pairing.phase === 'pin' ? (
                    <Text style={styles.pin} selectable>
                      {pairing.pin}
                    </Text>
                  ) : null}
                  <Text style={styles.body}>{pairing.message}</Text>
                  {pairingActive && pairing.backgroundLimited ? <Text style={styles.warn}>iOS only waits about 30 s in the background: go to Settings straight away.</Text> : null}
                </View>
              ) : null}
              <View style={styles.row}>
                <Button title="Enable JIT" onPress={enableJit} disabled={busy || jit} />
                {pairingActive ? (
                  <Button title="Cancel pairing" onPress={() => Gow3Core.cancelPairing().then(refresh)} />
                ) : (
                  <Button
                    title={builtIn?.paired ? 'Pair again' : 'Pair'}
                    onPress={() => Gow3Core.startPairing().then(refresh)}
                    disabled={busy || !builtIn?.available || !builtIn?.pairingSupported}
                  />
                )}
              </View>
              <View style={styles.row}>
                <Button
                  title="Check setup"
                  onPress={() => run(async () => (setStatus('Checking LocalDevVPN and the Developer Disk Image…'), await Gow3Core.prepareBuiltInJit()))}
                  disabled={busy || !builtIn?.paired || pairingActive}
                />
                <Button title="Reset disk image" onPress={() => run(() => Gow3Core.resetDeveloperDiskImage())} disabled={busy || !builtIn?.available} quiet />
              </View>
              <Button title="Forget pairing" onPress={() => Gow3Core.forgetPairing().then(refresh)} disabled={busy || !builtIn?.paired || pairingActive} quiet />
            </Panel>

            <Panel title="Game files" subtitle={filesReady ? 'All required files found' : `${missing} required file${missing === 1 ? '' : 's'} missing`}>
              <Text style={styles.body}>
                {`Files app › On My iPhone › ${APP_NAME} › gow3. Use your own legally dumped copy (CUSA01623/01715/01720, update 01.02) and the files the PC prepare step makes.`}
              </Text>
              <View style={styles.fileList}>
                <FileLine name="boot-linked.bin" present={files.boot} required />
                <FileLine name="game/eboot.bin" present={files.eboot} required />
                <FileLine name="game/sce_sys/param.sfo" present={files.sfo} />
                <FileLine name="content.bin" present={files.content} />
                <FileLine name="patches.bin" present={files.patches} />
              </View>
              <Button title="Check again" onPress={refresh} />
            </Panel>
            {status ? <Text style={styles.hint}>{status}</Text> : null}
          </>
        ) : null}

        {tab === 'system' ? (
          <>
            <Panel title="Diagnostics" subtitle="Tests, logs and device details">
              <View style={styles.row}>
                <Button title="Self-test" onPress={runSelfTest} disabled={busy} />
                <Button
                  title="GPU test"
                  onPress={() =>
                    run(async () => {
                      const json = await Gow3Core.gpuScreenTest(5);
                      setGpuReport(pretty(json));
                      return JSON.parse(json).ok ? 'GPU screen test passed.' : 'GPU screen test failed (see the report).';
                    })
                  }
                  disabled={busy || files.started}
                />
              </View>
              <View style={styles.row}>
                {files.started ? (
                  <Button title="Dump threads" onPress={() => run(async () => `Thread dump: ${await Gow3Core.dumpGameThreads()} threads (see the game log).`)} disabled={busy} />
                ) : (
                  <Button title="CPU only" onPress={() => run(() => Gow3Core.startGameCpuOnly())} disabled={busy || !filesReady} />
                )}
                <Button
                  title="Share game log"
                  onPress={() => {
                    const text = Gow3Core.readGameLog();
                    if (text) Share.share({ message: text }).catch(() => {});
                  }}
                  disabled={!gameLog}
                />
              </View>
              <View style={styles.row}>
                <Button
                  title="Clear game log"
                  onPress={() => {
                    Gow3Core.clearGameLog();
                    refresh();
                  }}
                  disabled={busy}
                  quiet
                />
                <Button
                  title="Clear test log"
                  onPress={() => {
                    Gow3Core.clearLog();
                    refresh();
                  }}
                  disabled={busy}
                  quiet
                />
              </View>
              {status ? <Text style={styles.hint}>{status}</Text> : null}
            </Panel>
            <WindowsTest
              locked={files.started || jit ? 'GoW3 used JIT or started in this launch: reopen the app to start a Windows program.' : null}
            />
            {gameLog ? <Mono title="Game log" text={gameLog} /> : null}
            {gpuReport ? <Mono title="GPU test" text={gpuReport} /> : null}
            {result ? <Mono title="Self-test" text={result} /> : null}
            <Mono title="Controllers" text={pads.length ? pads.map((p) => `${p.kind}: ${p.name} (${p.category})`).join('\n') : 'none'} />
            <Mono title="Device" text={pretty(report)} />
            <Mono title="Test log (survives crashes)" text={log || '(empty)'} />
            <View style={styles.panel}>
              <Text style={styles.panelTitle}>About</Text>
              <Text style={styles.body}>
                {`${APP_NAME} runs your own copy of ${GAME_TITLE} through FEX and shadPS4's video core on Metal. A fan port, not affiliated with Sony Interactive Entertainment or Santa Monica Studio.`}
              </Text>
            </View>
          </>
        ) : null}
      </ScrollView>

      <View style={styles.tabBar}>
        <TabButton label="Home" glyph="⌂" active={tab === 'home'} onPress={() => setTab('home')} />
        <TabButton label="Setup" glyph="⚙︎" active={tab === 'setup'} onPress={() => setTab('setup')} />
        <TabButton label="System" glyph="≡" active={tab === 'system'} onPress={() => setTab('system')} />
      </View>
      <StatusBar style="light" />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: color.bg },
  backdrop: { position: 'absolute', top: 0, left: 0, right: 0, height: 460, width: '100%', opacity: 0.55 },
  backdropFade: { position: 'absolute', left: 0, right: 0, bottom: 0, backgroundColor: color.bg },
  topBar: { paddingTop: 58, paddingHorizontal: 20, paddingBottom: 8, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  brand: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  brandIcon: { width: 30, height: 30, borderRadius: 8 },
  brandText: { color: color.text, fontSize: 20, fontWeight: '800', letterSpacing: 1 },
  topRight: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  topText: { color: color.text, fontSize: 15 },
  clock: { color: color.text, fontSize: 16, fontWeight: '600', fontVariant: ['tabular-nums'] },
  content: { paddingHorizontal: 20, paddingTop: 18, paddingBottom: 120, gap: 14 },
  hero: { flexDirection: 'row', gap: 16, alignItems: 'flex-end' },
  shelf: { gap: 14, paddingBottom: 6, paddingRight: 8 },
  shelfTile: { width: 84, alignItems: 'center', gap: 6 },
  shelfFrame: { padding: 3, borderRadius: 16, borderWidth: 2, borderColor: 'transparent' },
  shelfFrameActive: { borderColor: color.ember },
  shelfTitle: { color: color.muted, fontSize: 11, fontWeight: '600', maxWidth: 84 },
  shelfTitleActive: { color: color.text },
  monogram: { backgroundColor: color.raised, alignItems: 'center', justifyContent: 'center' },
  monogramText: { color: color.gold, fontWeight: '800', letterSpacing: 1 },
  addTile: { width: 76, height: 76, borderRadius: 11, borderStyle: 'dashed' },
  addGlyph: { color: color.muted, fontSize: 30, fontWeight: '300' },
  programRow: { flexDirection: 'row', alignItems: 'center', gap: 10, backgroundColor: color.panel, borderRadius: 14, borderWidth: 1, borderColor: color.border, paddingHorizontal: 14, paddingVertical: 10 },
  programLabel: { color: color.faint, fontSize: 10, fontWeight: '800', letterSpacing: 1.5 },
  programName: { flex: 1, color: color.text, fontSize: 13, fontWeight: '600' },
  programChange: { color: color.gold, fontSize: 13, fontWeight: '700' },
  cover: { width: 132, height: 132, borderRadius: 18, borderWidth: 1, borderColor: 'rgba(255,255,255,0.15)' },
  heroInfo: { flex: 1, gap: 6, paddingBottom: 4 },
  platform: { color: color.gold, fontSize: 11, fontWeight: '700', letterSpacing: 2 },
  gameTitle: { color: color.text, fontSize: 24, fontWeight: '800', lineHeight: 28 },
  pills: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginTop: 4 },
  pill: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 10, paddingVertical: 5, borderRadius: 999, borderWidth: 1, backgroundColor: 'rgba(0,0,0,0.35)' },
  pillText: { color: color.text, fontSize: 12, fontWeight: '600' },
  dot: { width: 8, height: 8, borderRadius: 4 },
  play: {
    marginTop: 10,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
    backgroundColor: color.ember,
    borderRadius: 18,
    paddingVertical: 20,
    shadowColor: color.ember,
    shadowOpacity: 0.55,
    shadowRadius: 22,
    shadowOffset: { width: 0, height: 8 },
  },
  playGlyph: { color: '#fff', fontSize: 22 },
  playText: { color: '#fff', fontSize: 22, fontWeight: '800', letterSpacing: 1.5 },
  hint: { color: color.muted, fontSize: 13, textAlign: 'center' },
  section: { color: color.faint, fontSize: 12, fontWeight: '700', letterSpacing: 2, textTransform: 'uppercase', marginTop: 12 },
  quickRow: { flexDirection: 'row', gap: 10 },
  quick: { flex: 1, backgroundColor: color.panel, borderRadius: 16, borderWidth: 1, borderColor: color.border, padding: 12, gap: 4, minHeight: 104 },
  quickActive: { borderColor: 'rgba(212,65,47,0.6)' },
  quickTitle: { color: color.faint, fontSize: 10, fontWeight: '800', letterSpacing: 1.5 },
  quickValue: { color: color.text, fontSize: 19, fontWeight: '800' },
  quickDetail: { color: color.muted, fontSize: 11 },
  panel: { backgroundColor: color.panel, borderRadius: 18, borderWidth: 1, borderColor: color.border, padding: 16, gap: 8 },
  panelTitle: { color: color.text, fontSize: 18, fontWeight: '800' },
  panelSubtitle: { color: color.muted, fontSize: 12 },
  panelBody: { gap: 12, marginTop: 6 },
  body: { color: color.muted, fontSize: 14, lineHeight: 20 },
  row: { flexDirection: 'row', gap: 10 },
  button: { flex: 1, backgroundColor: color.raised, borderRadius: 12, paddingVertical: 13, alignItems: 'center', borderWidth: 1, borderColor: color.border },
  buttonQuiet: { backgroundColor: 'transparent' },
  buttonText: { color: color.text, fontWeight: '600', fontSize: 15 },
  pressed: { opacity: 0.75, transform: [{ scale: 0.98 }] },
  disabled: { opacity: 0.4 },
  pairing: { gap: 8, padding: 14, borderRadius: 12, backgroundColor: color.raised },
  pin: { color: color.text, fontFamily: 'Menlo', fontSize: 40, fontWeight: '700', letterSpacing: 6, textAlign: 'center' },
  warn: { color: color.warn, fontSize: 12 },
  fileList: { gap: 8, paddingVertical: 4 },
  fileLine: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  fileMark: { fontSize: 15, fontWeight: '800', width: 16, textAlign: 'center' },
  fileName: { color: color.text, fontFamily: 'Menlo', fontSize: 13, flex: 1 },
  fileHint: { color: color.faint, fontSize: 12 },
  mono: { backgroundColor: 'rgba(12,12,16,0.95)', borderRadius: 12, padding: 12, gap: 6, borderWidth: 1, borderColor: color.border },
  monoTitle: { color: color.gold, fontSize: 11, fontWeight: '700', letterSpacing: 1, textTransform: 'uppercase' },
  monoText: { color: '#cfcdd6', fontFamily: 'Menlo', fontSize: 10.5 },
  tabBar: {
    position: 'absolute',
    left: 16,
    right: 16,
    bottom: 26,
    flexDirection: 'row',
    backgroundColor: 'rgba(18,18,24,0.96)',
    borderRadius: 24,
    borderWidth: 1,
    borderColor: color.border,
    paddingVertical: 8,
  },
  tab: { flex: 1, alignItems: 'center', gap: 2, paddingVertical: 4 },
  tabGlyph: { color: color.faint, fontSize: 20 },
  tabLabel: { color: color.faint, fontSize: 11, fontWeight: '700' },
  tabActive: { color: color.text },
  tabMark: { width: 18, height: 3, borderRadius: 2, backgroundColor: color.ember, marginTop: 3 },
});
