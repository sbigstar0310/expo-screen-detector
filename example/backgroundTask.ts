// Module-scope background task definition. Must be imported from the entry
// file (index.ts) before the root component is registered, so the task is
// defined even when the OS launches the app headlessly to run it.
import * as BackgroundTask from 'expo-background-task';
import * as TaskManager from 'expo-task-manager';
import ScreenDetector from 'expo-screen-detector';

export const SDQA_BG_TASK = 'SDQA_BG';

TaskManager.defineTask(SDQA_BG_TASK, async () => {
  try {
    const [off, locked, unavailable] = await Promise.all([
      ScreenDetector.isScreenOff(),
      ScreenDetector.isScreenLocked(),
      ScreenDetector.isScreenUnavailable(),
    ]);
    console.log('[SDQA-BG] ' + JSON.stringify({ t: Date.now(), off, locked, unavailable }));
  } catch (e: any) {
    console.log('[SDQA-BG] ERROR ' + (e?.code ?? '') + ' ' + (e?.message ?? String(e)));
  }
  return BackgroundTask.BackgroundTaskResult.Success;
});

export async function registerSdqaBackgroundTask(): Promise<void> {
  try {
    // registerTaskAsync only warns and returns when background tasks are
    // restricted (e.g. on the iOS Simulator), so check the status first.
    const status = await BackgroundTask.getStatusAsync();
    if (status !== BackgroundTask.BackgroundTaskStatus.Available) {
      console.log(
        '[SDQA] bg-registration-skipped ' +
          JSON.stringify({ status: BackgroundTask.BackgroundTaskStatus[status] })
      );
      return;
    }
    await BackgroundTask.registerTaskAsync(SDQA_BG_TASK, { minimumInterval: 15 });
    console.log('[SDQA] bg-registered');
  } catch (e: any) {
    console.log('[SDQA] bg-register-error ' + (e?.code ?? '') + ' ' + (e?.message ?? String(e)));
  }
}

export async function triggerSdqaBackgroundTask(): Promise<void> {
  try {
    const result = await BackgroundTask.triggerTaskWorkerForTestingAsync();
    console.log('[SDQA] bg-trigger ' + JSON.stringify({ t: Date.now(), result }));
  } catch (e: any) {
    console.log('[SDQA] bg-trigger-error ' + (e?.code ?? '') + ' ' + (e?.message ?? String(e)));
  }
}
