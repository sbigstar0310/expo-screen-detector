import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, AppStateStatus, Button, StyleSheet, Text, View } from 'react-native';
import ScreenDetector from 'expo-screen-detector';

import { registerSdqaBackgroundTask, triggerSdqaBackgroundTask } from './backgroundTask';

type Vals = { off: boolean | null; locked: boolean | null; unavailable: boolean | null };

export default function App() {
  const [vals, setVals] = useState<Vals>({ off: null, locked: null, unavailable: null });
  const appStateRef = useRef<AppStateStatus>(AppState.currentState);
  const [appState, setAppState] = useState<AppStateStatus>(AppState.currentState);

  const poll = useCallback(async (source: string) => {
    try {
      const [off, locked, unavailable] = await Promise.all([
        ScreenDetector.isScreenOff(),
        ScreenDetector.isScreenLocked(),
        ScreenDetector.isScreenUnavailable(),
      ]);
      setVals({ off, locked, unavailable });
      console.log(
        '[SDQA] ' +
          JSON.stringify({ t: Date.now(), src: source, appState: appStateRef.current, off, locked, unavailable })
      );
    } catch (e: any) {
      console.log('[SDQA] ERROR ' + (e?.code ?? '') + ' ' + (e?.message ?? String(e)));
    }
  }, []);

  useEffect(() => {
    registerSdqaBackgroundTask();
  }, []);

  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      console.log('[SDQA] ' + JSON.stringify({ t: Date.now(), event: 'appState', from: appStateRef.current, to: next }));
      appStateRef.current = next;
      setAppState(next);
    });
    poll('mount');
    const id = setInterval(() => poll('interval'), 1000);
    return () => {
      sub.remove();
      clearInterval(id);
    };
  }, [poll]);

  const fmt = (v: boolean | null) => (v === null ? '...' : String(v));
  return (
    <View style={styles.container}>
      <Text style={styles.label}>appState: {appState}</Text>
      <Text style={styles.label}>isScreenOff</Text>
      <Text testID="val-off" style={styles.val}>{fmt(vals.off)}</Text>
      <Text style={styles.label}>isScreenLocked</Text>
      <Text testID="val-locked" style={styles.val}>{fmt(vals.locked)}</Text>
      <Text style={styles.label}>isScreenUnavailable</Text>
      <Text testID="val-unavailable" style={styles.val}>{fmt(vals.unavailable)}</Text>
      <Button testID="btn-refresh" title="Refresh" onPress={() => poll('refresh')} />
      <View style={styles.spacer} />
      <Button testID="btn-trigger-bg" title="Trigger background task" onPress={() => triggerSdqaBackgroundTask()} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff', alignItems: 'center', justifyContent: 'center', padding: 16 },
  label: { fontSize: 18, marginTop: 12 },
  val: { fontSize: 40, fontWeight: 'bold' },
  spacer: { height: 12 },
});
